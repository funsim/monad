// Which triple a build is for, and what the LLVM tools must be told about
// it.
//
// Three fields rather than one, because the tools do not agree and the ABI
// is not derivable from the triple. Measured 2026-10-06 against llc 21.1.8:
//
//   * `llc` REJECTS `riscv64gc-unknown-linux-gnu` -- the spelling both
//     `clang --print-target-triple` and nixpkgs' sysroot use -- with
//     "unable to get target for ..."; llc wants `riscv64-unknown-linux-gnu`.
//     Hence `llc_triple`.
//   * llc's default for that triple is soft-float, which does not match the
//     rv64gc/lp64d sysroot `pkgsCross.riscv64` builds against, and no triple
//     spelling selects the hard-float ABI. Hence `llc_flags`.
//
// An EMPTY `llc_triple` means "pass no `-mtriple`": llc then takes the triple
// from the module header, which is `triple`. So for every target whose
// spelling llc already accepts the header is the whole answer, and the
// native argv is unchanged from what it was before this file existed.
//
// The C compiler is deliberately NOT told a triple here. `runtime.c` is
// compiled and the objects are linked by whatever `clang` is on PATH, and
// each cross leg puts that target's own cc there (a two-line
// `writeShellScriptBin "clang"` shim exec'ing `pkgsCross.<x>.stdenv.cc`).
// Handing such a wrapper `--target=` fights it: nixpkgs' own cc-wrapper
// refuses outright on riscv64 with "unsupported option
// '-fzero-call-used-regs=used-gpr' for target 'riscv64-unknown-linux-gnu'".

use std::process {Proc.capture}
open IO {println}

/// One target: the spelling the toolchain is addressed by, the spelling llc
/// needs if it differs, and the ABI flags no spelling can carry.
pub struct TargetSpec {
    triple : String,
    llc_triple : String,
    llc_flags : List String,
}

/// The targets this compiler has a measured spelling for. A name that is not
/// here is still accepted -- see `TargetSpec.resolve` -- and gets the same
/// string for both tools and no flags, which is right for everything but
/// riscv64, which is why riscv64 is here.
pub def TargetSpec.known_targets : List TargetSpec := [
    TargetSpec.mk "x86_64-unknown-linux-gnu" "" List.empty,
    TargetSpec.mk "aarch64-unknown-linux-gnu" "" List.empty,
    TargetSpec.mk "aarch64-apple-darwin" "" List.empty,
    TargetSpec.mk "riscv64gc-unknown-linux-gnu" "riscv64-unknown-linux-gnu" [
        "-mattr=+m,+a,+f,+d,+c", "-target-abi=lp64d",
    ],
    TargetSpec.mk "wasm32-unknown-wasip1" "" List.empty,
]

/// The `-mtriple` and ABI flags `llc` gets for this target. Empty for a
/// native target, which is what keeps this change out of the native argv.
def TargetSpec.llc_argv (t : TargetSpec) : List String :=
    if String.is_empty t.llc_triple
    then t.llc_flags
    else List.cons (String.concat "-mtriple=" t.llc_triple) t.llc_flags

/// `--target`'s accepted shorthands. Only `wasm32-wasip1` needs one, and it
/// needs it because `clang --print-target-triple --target=wasm32-wasip1`
/// answers `wasm32-unknown-wasip1`: a resolver keyed on what the user typed
/// would miss the spelling the toolchain itself canonicalises to.
def TargetSpec.normalize (name : String) : String :=
    if String.beq name "wasm32-wasip1" then "wasm32-unknown-wasip1" else name

/// `--target`'s value -> the spec to build with.
///
/// An empty name is the machine this compiler is running on. A name in
/// `known_targets` is taken verbatim. Anything else becomes a spec whose two
/// spellings are the same string, which is the right default for a target
/// nobody tabulated; `--print-targets` is where the question "can this
/// toolchain even build that?" is answered.
#[partial]
pub def TargetSpec.resolve (name : String) : IO (Result String TargetSpec) := do {
    if String.is_empty name then do {
        let native <- TargetSpec.native;
        return (Result.ok native)
    } else do {
        let want := TargetSpec.normalize name;
        match TargetSpec.lookup TargetSpec.known_targets want {
            Option.some t => return (Result.ok t),
            Option.none => return (Result.ok (TargetSpec.mk want "" List.empty))
        }
    }
}

/// Whether `t` answers to `triple`: either spelling, because `--target` accepts
/// the one `print-targets` prints in the parens as well as the table's. An
/// empty `llc_triple` names nothing -- without that guard every flagless entry
/// would answer to "".
def TargetSpec.names (t : TargetSpec) (triple : String) : Bool :=
    String.beq t.triple triple
        || (not (String.is_empty t.llc_triple) && String.beq t.llc_triple triple)

/// The first entry of `specs` that `names` accepts for `triple`.
#[partial]
def TargetSpec.lookup (specs : List TargetSpec) (triple : String) : Option TargetSpec :=
    match specs {
        List.empty => Option.none,
        List.cons hd tl =>
            if TargetSpec.names hd triple then Option.some hd else TargetSpec.lookup tl triple,
    }

/// The table's entry for `triple`, or a bare spec that is told no `-mtriple`.
///
/// Pure, so `native` consults the table without a second probe: a host the
/// table measured -- riscv64 is the one that matters -- gets its ABI and PIC
/// flags, where a host it did not (darwin's version-suffixed
/// `arm64-apple-darwin24.x`) gets today's flagless spec. x86_64-unknown-linux-gnu
/// is a table hit whose entry is already flagless, so its native argv is
/// byte-identical to what it was before targets existed.
#[partial]
def TargetSpec.table_or (triple : String) : TargetSpec :=
    match TargetSpec.lookup TargetSpec.known_targets triple {
        Option.some t => t,
        Option.none => TargetSpec.mk triple "" List.empty,
    }

/// The triples a store may hold artifacts under, for `gc` to spare.
///
/// A build keys with the RESOLVED spec's `triple`, so the table's own fields
/// cover every `--target` -- `resolve` answers a table hit with the entry
/// verbatim, either spelling of it. `native_triple` is appended because a host
/// the table does not know (darwin's version-suffixed `arm64-apple-darwin24.x`)
/// keys under its probe verbatim. A `--target` accepted by `unvalidated` keys
/// under a name no list here holds, so `gc` still collects it.
#[partial]
pub def TargetSpec.keep_triples (native_triple : String) : List String :=
    List.append (TargetSpec.triples_of TargetSpec.known_targets) [native_triple]

/// The `triple` field of each spec, in order.
#[partial]
def TargetSpec.triples_of (specs : List TargetSpec) : List String :=
    match specs {
        List.empty => List.empty,
        List.cons hd tl => List.cons hd.triple (TargetSpec.triples_of tl),
    }

/// The target this compiler is running on.
///
/// `clang -dumpmachine` rather than `llc --version`'s "Default target": the
/// C compiler is the one that has to agree with the objects llc emits, and
/// it is the one the link step will call. The probe is then answered from
/// `known_targets`, so a host the table measured gets its flags (see
/// `table_or`). A toolchain that cannot answer
/// leaves the historical x86_64 default in place, loudly -- a silent
/// fallback here would compile for the wrong machine and fail at ld, which
/// is a worse diagnostic than the one printed.
#[partial]
pub def TargetSpec.native : IO TargetSpec := do {
    let cap <- Proc.capture "clang" ["-dumpmachine"];
    match cap {
        Pair.pair _ out => do {
            let probed := TargetSpec.first_line out;
            if String.is_empty probed then do {
                println "note: `clang -dumpmachine` named no triple; assuming x86_64-unknown-linux-gnu";
                return (TargetSpec.table_or "x86_64-unknown-linux-gnu")
            } else return (TargetSpec.table_or probed)
        }
    }
}

/// `text`'s first line, trimmed.
///
/// `Proc.capture` merges stderr, and a wrapper that warns puts the warning
/// on line 1 -- but `clang -dumpmachine` puts its answer on its FIRST line,
/// so this is the end of the stream the answer is at for that tool. Its
/// opposite number, for a tool that appends to stderr rather than
/// prepending, takes the LAST non-empty line instead.
#[partial]
def TargetSpec.first_line (text : String) : String :=
    let len := String.length text in
    let at := TargetSpec.newline_at text len 0 in
    String.trim (if I64.lt at 0 then text else String.slice text 0 at)

/// Byte index of the first newline in `text` at or after `from`, or -1.
///
/// `#[terminating]`: `from` counts UP, which the structural termination
/// checker cannot see is bounded by `len`.
#[terminating]
def TargetSpec.newline_at (text : String) (len : I64) (from : I64) : I64 :=
    if I64.lt from len
    then if String.beq (String.slice text from 1) "\n" then from
         else TargetSpec.newline_at text len (from + 1)
    else -1

/// The llc spelling reaches the same entry as the measured one, so
/// `--target riscv64-unknown-linux-gnu` gets lp64d and PIC instead of the
/// empty argv a table miss would hand it.
#[test]
def test_lookup_answers_the_llc_spelling_too : Bool :=
    String.beq (TargetSpec.describe (TargetSpec.table_or "riscv64-unknown-linux-gnu"))
        (TargetSpec.describe (TargetSpec.table_or "riscv64gc-unknown-linux-gnu"))

/// The x86_64 entry is a table hit and is already flagless, which is what keeps
/// the native argv byte-identical to what it was before targets existed.
#[test]
def test_x86_64_stays_flagfree : Bool :=
    List.is_empty (TargetSpec.llc_argv (TargetSpec.table_or "x86_64-unknown-linux-gnu"))

/// A triple the table does not know passes no `-mtriple` and no flags, exactly
/// as `unvalidated` builds it: a miss, not a wrong hit.
#[test]
def test_unknown_triple_is_untouched : Bool :=
    String.beq (TargetSpec.describe (TargetSpec.table_or "bogus-target-xyz")) "bogus-target-xyz"

/// An empty name is not a spelling of anything. Every entry but riscv64 has an
/// empty `llc_triple`, so without the guard in `names` the first of them would
/// answer it.
#[test]
def test_empty_name_matches_no_entry : Bool :=
    match TargetSpec.lookup TargetSpec.known_targets "" {
        Option.some _ => false,
        Option.none => true,
    }
