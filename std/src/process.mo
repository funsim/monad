// IO is ambient (init/io.mo, always a loaded root) -- no `use` needed.

use lib::io {}
open IO {current_time_nano, file_exists_native, read_file_native}

#[native "exec_cmd"]
pub def exec_cmd (cmd : String) (args : List String) : IO I64

#[native "process_id"]
pub def process_id : I64

// ── Capturing a command's output ────────────────────────────────────────
// `exec_cmd` above hands back an exit status and nothing else:
// `monad_exec_cmd` (runtime/src/runtime.c) is fork + execvp + waitpid
// returning `WEXITSTATUS`, with no pipe and no `dup2`. Reading what a tool
// PRINTED therefore needs a detour, and `Proc.capture` is the one place
// that detour lives -- `clang -dumpmachine`, `llc --version` and
// `git rev-parse` all want it, and a second hand-rolled copy is how the
// old `link_ir` build-commit probe drifted (see llvm/src/link.mo's
// `build_commit_define` for that story).
//
// Deliberately NOT a new native. A native costs six wiring places --
// core_native.rs's dispatch arm AND its PURE_NATIVES allowlist,
// lower_core_ir.rs, natives.mo's `native_runtime_fn_name` AND its
// `runtime_declarations`, and runtime.c -- and then has to be kept in step
// across both runtimes forever. Everything below is ordinary Monad over
// primitives that already exist on both.

/// The byte `'` (0x27). Named because it is load-bearing twice below: it
/// is what `Proc.shell_quote` has to escape, and the fact that it is
/// BELOW 0x80 is what makes slicing at its index UTF-8-safe.
def Proc.quote_byte : U8 := 39u8

/// Index of the first `'` in `s`, or `none`.
///
/// Byte-exact, via `String.to_list`. That is not fussiness: `String.slice`
/// and `String.drop` are byte-oriented and silently return `""` when an
/// offset lands mid-character (see the UTF-8 note in
/// lang/src/parser/combinators.mo, which was written after exactly that
/// bug truncated everything after an em dash). Scanning the byte list
/// gives an exact index, and slicing AT that index is safe for the one
/// reason that matters: `0x27` is below `0x80`, so it can never be a
/// continuation byte, and a quote's index is therefore always a character
/// boundary.
def Proc.first_quote (s : String) : Option I64 :=
    Proc.first_quote_go (String.to_list s) 0

#[partial]
def Proc.first_quote_go (bytes : List U8) (i : I64) : Option I64 :=
    match bytes {
        List.empty => Option.none,
        List.cons b rest =>
            if U8.beq b Proc.quote_byte
            then Option.some i
            else Proc.first_quote_go rest (i + 1)
    }

/// Replace every `'` with `'\''` -- close the quote, emit an escaped
/// quote, reopen it. Splits AT each quote rather than walking byte by
/// byte, for the boundary reason in `Proc.first_quote`.
#[partial]
def Proc.escape_quotes (s : String) : String :=
    match Proc.first_quote s {
        Option.none => s,
        Option.some i =>
            // `String.slice`'s third argument is a LENGTH, not an end
            // index -- so this is "the i bytes before the quote".
            String.concat (String.slice s 0 i)
                (String.concat "'\\''" (Proc.escape_quotes (String.drop (i + 1) s)))
    }

/// Quote `s` so that a POSIX shell reads it as one literal word.
///
/// Single quotes, because they are the only POSIX quoting that is FULLY
/// literal: no parameter expansion, no command substitution, no backslash
/// escapes, no globbing. So a quoted argument cannot be reinterpreted by
/// the shell whatever it contains -- which is what makes it safe to pass a
/// path, a git URL or a ref through `sh -c` at all.
///
/// This is the control, not a convention. Every interpolated component of
/// a `sh -c` script must go through it, and
/// `test_capture_does_not_expand_a_dollar_sign` (in
/// `std/src/process_tests.mo`) is what fails if one stops doing so: it
/// asserts that `$HOME` reaches `echo` as four literal characters.
pub def Proc.shell_quote (s : String) : String :=
    String.concat "'" (String.concat (Proc.escape_quotes s) "'")

/// `cmd arg arg ...`, every word quoted.
#[partial]
def Proc.quoted_argv (cmd : String) (args : List String) : String :=
    String.concat (Proc.shell_quote cmd) (Proc.quoted_args args)

#[partial]
def Proc.quoted_args (args : List String) : String :=
    match args {
        List.empty => "",
        List.cons a rest =>
            String.concat " " (String.concat (Proc.shell_quote a) (Proc.quoted_args rest))
    }

/// Where the redirect lands. Pid AND nanosecond, because a fixed `/tmp`
/// name collides across concurrent runs and this corpus is swept sharded
/// (scripts/check-monad-tests.sh runs MONAD_SWEEP_JOBS processes at once).
///
/// Uniqueness is not GUARANTEED -- two captures in the same nanosecond on
/// the same pid would share a path. Each call does a fork and an exec, so
/// that cannot happen in practice; saying so is better than implying a
/// guarantee this cannot make.
def Proc.scratch_path : IO String := do {
    let nanos <- current_time_nano;
    return ("/tmp/monad_capture_" ++ I64.to_string process_id ++ "_" ++ I64.to_string nanos)
}

/// Read the redirect file, then remove it. Missing means `sh` never got
/// far enough to create it, which is not an error here: the caller still
/// gets the exit status, with empty output.
///
/// The existence check is not belt-and-braces -- `read_file_native` still
/// carries a `TODO Return Option and none on failure` and has no failure
/// channel at all, so reading a file that is not there is exactly the case
/// to keep it away from.
///
/// `rm` rather than a native, because there is no removal native and this
/// is already the established spelling (lang/src/codegen/test/
/// e2e_harness.mo and four slow_tests files all do `exec_cmd "rm"`).
def Proc.read_then_remove (path : String) : IO String := do {
    let exists <- file_exists_native path;
    let out <- (if exists then read_file_native path else return "");
    let _removed <- exec_cmd "rm" ["-f", path];
    return out
}

/// Run `cmd args` and return its exit status together with everything it
/// wrote, stdout and stderr MERGED.
///
/// Merged on purpose. The callers are toolchain probes and failing
/// external tools, and which stream carries the interesting text is not
/// something they should have to know: `clang -dumpmachine` prints the
/// triple on stdout, `llc --version` splits its target list across both
/// depending on version, and a failed `mlir-opt` pass pipeline puts its
/// ENTIRE signal on stderr (see plans/bootstrapping/mlir-codegen.md, which
/// records that as a hard blocker). One string, one exit code.
#[partial]
pub def Proc.capture (cmd : String) (args : List String) : IO (Pair I64 String) := do {
    let tmp <- Proc.scratch_path;
    let script : String :=
        Proc.quoted_argv cmd args ++ " > " ++ Proc.shell_quote tmp ++ " 2>&1";
    let code <- exec_cmd "sh" ["-c", script];
    let out <- Proc.read_then_remove tmp;
    return (Pair.pair code out)
}

// Tests live in `std/src/process_tests.mo`, not here, and that is forced
// rather than stylistic: this module is one of the three `std/src/lib.mo`
// re-exports (`path`, `io`, `process`), which the module loader seeds
// ambiently into every closure. A `#[test]` in one of them is never
// attributed to a TARGET module, so `monad test std/src/process.mo`
// answers "No tests found" and the `monad test std` directory sweep skips
// it silently -- verified by putting a trivial `def test_probe : Bool :=
// true` in this file and watching both ignore it. That is why
// `path_tests.mo`, `map_tests.mo` and `sha256_tests.mo` are separate files
// too.
