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

/// `--target`'s value -> the spec to build with.
///
/// An empty name is the machine this compiler is running on. A name in
/// `known_targets` is taken verbatim. Anything else is resolved from the
/// spelling the toolchain itself canonicalises to -- `wasm32-wasip1` answers
/// `wasm32-unknown-wasip1`, so a resolver keyed on what the user TYPED would
/// miss the entry the emitter and llc need -- and then accepted only if llc
/// registers its architecture. `--print-targets` answers the same question at
/// length.
///
/// The two lookups are deliberate: the measured five spellings resolve with no
/// fork at all, and only a name that is already unrecognised pays for the
/// probe.
#[partial]
pub def TargetSpec.resolve (name : String) : IO (Result String TargetSpec) := do {
    if String.is_empty name then do {
        let native <- TargetSpec.native;
        return (Result.ok native)
    } else do {
        match TargetSpec.lookup TargetSpec.known_targets name {
            Option.some t => return (Result.ok t),
            Option.none => TargetSpec.resolve_unrecognised name,
        }
    }
}

/// `--target`'s value when it is not one of the measured spellings.
///
/// Split out of `resolve` only so that the `canonical` probe -- a dotted bind
/// -- does not sit immediately before a `match`; see `run_test_loop_codegen`
/// in `cli/src/main.mo` for what that costs.
#[partial]
def TargetSpec.resolve_unrecognised (name : String) : IO (Result String TargetSpec) := do {
    let want <- TargetSpec.canonical name;
    match TargetSpec.lookup TargetSpec.known_targets want {
        Option.some t => return (Result.ok t),
        Option.none => TargetSpec.unvalidated want,
    }
}

/// `want` (canonical, and not in `known_targets`) -> a spec, or a rejection.
///
/// Validation is by ARCHITECTURE, never by triple: llc lists architectures
/// (`x86-64`, not `x86_64-unknown-linux-gnu`), and it is llc that has to accept
/// what comes out of here. An llc that lists nothing at all is an absent
/// oracle, not a target set of zero -- validating against it would reject every
/// name -- so the target is accepted with a note, the same loud fallback
/// `TargetSpec.native` makes.
#[partial]
def TargetSpec.unvalidated (want : String) : IO (Result String TargetSpec) := do {
    let archs <- TargetSpec.registered_archs;
    if List.is_empty archs then do {
        println (String.concat "note: `llc --version` listed no registered targets; accepting " want);
        return (Result.ok (TargetSpec.mk want "" List.empty))
    } else if TargetSpec.arch_registered archs want then
        return (Result.ok (TargetSpec.mk want "" List.empty))
    else
        return (Result.err (TargetSpec.unknown_message want))
}

/// The spelling the toolchain canonicalises `name` to.
///
/// `clang --print-target-triple` echoes an unknown target VERBATIM, so this
/// canonicalises and does not validate -- `--target wasm32-wasip1` is how it
/// earns its keep. The nix wrapper PREPENDS its multi-target warning, so the
/// answer is the LAST non-empty line, unlike `-dumpmachine`'s first (see
/// `last_line`). A cc that cannot answer at all -- the cross legs put a
/// two-line `clang` shim on PATH that execs a gcc wrapper, which has no such
/// flag -- gets a note and the name stands as typed.
#[partial]
def TargetSpec.canonical (name : String) : IO String := do {
    let cap <- Proc.capture "clang" ["--print-target-triple", String.concat "--target=" name];
    match cap {
        Pair.pair code out => do {
            if code == 0 then do {
                let probed := TargetSpec.last_line out;
                if String.is_empty probed then do {
                    println (String.concat "note: `clang --print-target-triple` named no triple for " name);
                    return name
                } else return probed
            } else do {
                println (String.concat "note: `clang` cannot spell a triple for " name);
                return name
            }
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

/// The architectures llc on PATH was built with, from `llc --version`.
#[partial]
pub def TargetSpec.registered_archs : IO (List String) := do {
    let cap <- Proc.capture "llc" ["--version"];
    match cap {
        Pair.pair _code out => return (TargetSpec.archs_of out),
    }
}

/// The `Registered Targets:` block's arch words -- the first token of every
/// line after that header. An output with no header (a failed `llc`) is empty,
/// which callers must read as "no oracle", not "no targets".
#[partial]
def TargetSpec.archs_of (text : String) : List String :=
    TargetSpec.archs_after text false

/// `rest` shrinks by one line per call and the empty `rest` is the
/// terminator. Without that case the blank-line skip below cannot stop --
/// `line_rest ""` is `""` too, so it recurs forever and the compiled driver
/// dies on the stack (the self-hosted checker sees nothing wrong).
#[partial]
def TargetSpec.archs_after (rest : String) (seen : Bool) : List String :=
    if String.is_empty rest
    then List.empty
    else let line := String.trim (TargetSpec.up_to "\n" rest) in
    if String.is_empty line then TargetSpec.archs_after (TargetSpec.line_rest rest) seen
    else if seen then List.cons (TargetSpec.up_to " " line) (TargetSpec.archs_after (TargetSpec.line_rest rest) seen)
    else if String.beq line "Registered Targets:" then TargetSpec.archs_after (TargetSpec.line_rest rest) true
    else TargetSpec.archs_after (TargetSpec.line_rest rest) seen

/// Whether llc's registered `archs` covers the architecture `triple` names.
///
/// Prefix, with `_` and `-` dropped from both sides: llc registers `x86-64`
/// where triples say `x86_64`, `riscv64` where they say `riscv64gc` (llc
/// rejects that spelling itself), and `thumb` where they say `thumbv7em`. A
/// false accept is the safe direction -- llc fails loudly on its own -- where a
/// false reject would refuse a target that works.
#[partial]
pub def TargetSpec.arch_registered (archs : List String) (triple : String) : Bool :=
    TargetSpec.any_arch archs (TargetSpec.letters (TargetSpec.first_component triple))

#[partial]
def TargetSpec.any_arch (archs : List String) (want : String) : Bool :=
    match archs {
        List.empty => false,
        List.cons hd tl =>
            if String.starts_with (TargetSpec.letters hd) want then true
            else TargetSpec.any_arch tl want,
    }

/// `s` with `_` and `-` dropped, so the two spellings of one arch compare equal.
#[partial]
def TargetSpec.letters (s : String) : String :=
    TargetSpec.letters_from s (String.length s) 0

#[terminating]
def TargetSpec.letters_from (s : String) (len : I64) (i : I64) : String :=
    if I64.lt i len then
        let c := String.slice s i 1 in
        let rest := TargetSpec.letters_from s len (i + 1) in
        if String.beq c "_" then rest
        else if String.beq c "-" then rest
        else String.concat c rest
    else ""

/// `triple`'s architecture word: everything before its first `-`.
def TargetSpec.first_component (triple : String) : String :=
    TargetSpec.up_to "-" triple

/// One `--print-targets` line: the triple, and llc's argv when it says more
/// than the triple does.
pub def TargetSpec.describe (t : TargetSpec) : String :=
    let argv := TargetSpec.joined " " (TargetSpec.llc_argv t) in
    if String.is_empty argv then t.triple
    else String.concat t.triple (String.concat "  (llc " (String.concat argv ")"))

/// A `--print-targets` line per spec, newline-separated.
#[partial]
pub def TargetSpec.describe_all (archs : List String) (specs : List TargetSpec) : String :=
    match specs {
        List.empty => "",
        List.cons hd tl =>
            let rest := TargetSpec.describe_all archs tl in
            let line := TargetSpec.marked archs hd in
            if String.is_empty rest then line else String.concat line (String.concat "\n" rest),
    }

/// `t`'s line, marked when this llc cannot build for it.
#[partial]
def TargetSpec.marked (archs : List String) (t : TargetSpec) : String :=
    if TargetSpec.arch_registered archs t.triple then TargetSpec.describe t
    else String.concat (TargetSpec.describe t)
        (String.concat "  (llc registers no " (String.concat (TargetSpec.first_component t.triple) ")"))

/// `xs` joined by `sep`; empty for an empty list.
#[partial]
pub def TargetSpec.joined (sep : String) (xs : List String) : String :=
    match xs {
        List.empty => "",
        List.cons hd tl =>
            let rest := TargetSpec.joined sep tl in
            if String.is_empty rest then hd else String.concat hd (String.concat sep rest),
    }

/// The `--print-targets` architecture list, or the note that there is none --
/// an llc that could not answer must not print as an empty list of targets.
pub def TargetSpec.arch_line (archs : List String) : String :=
    if List.is_empty archs
    then "(llc --version listed none; `--target` accepts any name unvalidated)"
    else TargetSpec.joined ", " archs

/// `triple` -> what `--target` fails with.
#[partial]
def TargetSpec.unknown_message (triple : String) : String :=
    String.concat "unknown target `"
        (String.concat triple
            (String.concat "`: llc registers no `"
                (String.concat (TargetSpec.first_component triple)
                    "` architecture -- `monad print-targets` lists what this compiler knows")))

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
/// `Proc.capture` merges stderr, and a wrapper that warns puts the warning on
/// line 1 -- but `clang -dumpmachine` puts its answer on its FIRST line, so
/// this is the end of the stream the answer is at for that tool. A tool that
/// appends to stderr rather than prepending needs `last_line` instead.
#[partial]
def TargetSpec.first_line (text : String) : String :=
    String.trim (TargetSpec.up_to "\n" text)

/// `text`'s last non-empty line, trimmed -- for a tool that appends rather
/// than prepends, which is `clang --print-target-triple` behind the nix
/// wrapper's warning.
#[partial]
def TargetSpec.last_line (text : String) : String :=
    TargetSpec.last_line_go text ""

#[partial]
def TargetSpec.last_line_go (rest : String) (acc : String) : String :=
    if String.is_empty (String.trim rest) then acc
    else TargetSpec.last_line_go (TargetSpec.line_rest rest) (TargetSpec.first_line rest)

/// `text` after its first line (empty when it has no newline left).
#[partial]
def TargetSpec.line_rest (text : String) : String :=
    let at := TargetSpec.char_at text (String.length text) 0 "\n" in
    if I64.lt at 0 then "" else String.drop (at + 1) text

/// `s` up to its first `ch`, or the whole of `s` when `ch` does not occur.
def TargetSpec.up_to (ch : String) (s : String) : String :=
    let at := TargetSpec.char_at s (String.length s) 0 ch in
    if I64.lt at 0 then s else String.slice s 0 at

/// Byte index of the first `ch` in `text` at or after `from`, or -1.
///
/// `#[terminating]`: `from` counts UP, which the structural termination
/// checker cannot see is bounded by `len`.
#[terminating]
def TargetSpec.char_at (text : String) (len : I64) (from : I64) (ch : String) : I64 :=
    if I64.lt from len
    then if String.beq (String.slice text from 1) ch then from
         else TargetSpec.char_at text len (from + 1) ch
    else -1

/// The header line and the indented `arch - description` lines llc prints, with
/// the versions and build flags before them, which must not become arch words.
#[test]
def test_archs_of_reads_the_registered_block : Bool :=
    let text := "LLVM (http://llvm.org/):\n  LLVM version 21.1.8\n  Optimized build.\n\n  Registered Targets:\n    aarch64     - AArch64 (little endian)\n    riscv64     - 64-bit RISC-V\n    x86-64      - 64-bit X86: EM64T and AMD64\n" in
    String.beq (TargetSpec.joined "," (TargetSpec.archs_of text)) "aarch64,riscv64,x86-64"

/// An llc that failed prints no header, which is no oracle -- callers accept
/// the target rather than reject it -- so this must be empty, not garbage.
#[test]
def test_archs_of_without_the_header_is_empty : Bool :=
    List.is_empty (TargetSpec.archs_of "LLVM (http://llvm.org/):\n  LLVM version 21.1.8\n")

/// The three measured spellings llc's arch words disagree with triples about.
#[test]
def test_arch_registered_normalises_the_spellings : Bool :=
    let archs := ["aarch64", "riscv64", "thumb", "wasm32", "x86-64"] in
    TargetSpec.arch_registered archs "x86_64-unknown-linux-gnu"
        && TargetSpec.arch_registered archs "riscv64gc-unknown-linux-gnu"
        && TargetSpec.arch_registered archs "aarch64-apple-darwin"
        && TargetSpec.arch_registered archs "thumbv7em-none-eabi"
        && TargetSpec.arch_registered archs "wasm32-unknown-wasip1"

#[test]
def test_arch_registered_rejects_an_unknown_architecture : Bool :=
    TargetSpec.arch_registered ["aarch64", "x86-64"] "bogus-target-xyz" == false

/// The llc argv is printed only when it says more than the triple already does,
/// so the four targets that need no extra spelling stay one token long.
#[test]
def test_describe_names_the_llc_spelling_only_when_it_differs : Bool :=
    let riscv := TargetSpec.mk "riscv64gc-unknown-linux-gnu" "riscv64-unknown-linux-gnu" ["-mattr=+m,+a,+f,+d,+c", "-target-abi=lp64d"] in
    let linux := TargetSpec.mk "x86_64-unknown-linux-gnu" "" List.empty in
    String.beq (TargetSpec.describe linux) "x86_64-unknown-linux-gnu"
        && String.beq (TargetSpec.describe riscv)
            "riscv64gc-unknown-linux-gnu  (llc -mtriple=riscv64-unknown-linux-gnu -mattr=+m,+a,+f,+d,+c -target-abi=lp64d)"

#[test]
def test_describe_all_marks_what_this_llc_cannot_build : Bool :=
    String.beq (TargetSpec.describe_all ["aarch64"] [
        TargetSpec.mk "aarch64-unknown-linux-gnu" "" List.empty,
        TargetSpec.mk "wasm32-unknown-wasip1" "" List.empty,
    ]) "aarch64-unknown-linux-gnu\nwasm32-unknown-wasip1  (llc registers no wasm32)"

#[test]
def test_unknown_message_names_the_architecture : Bool :=
    String.beq (TargetSpec.unknown_message "bogus-target-xyz")
        "unknown target `bogus-target-xyz`: llc registers no `bogus` architecture -- `monad print-targets` lists what this compiler knows"

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
