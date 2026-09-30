/// Where build output goes, and what an entry in it is called.
///
/// Paths only -- this module decides names and answers "where", and does
/// not read or write anything. The I/O sits above it (phase 2a of
/// plans/packaging/mote-build-deps-artifacts-targets.md), which keeps
/// every naming rule here testable without touching a filesystem.

use io {IO}
use std::io {get_env}
use std::process {capture, shell_quote}
use lang::module {extract_directory}
use lang::mote {discover_build_dir}

/// The three kinds of thing the store holds. One store rather than three
/// so that `clean`, `gc` and `verify` are written once; the kind is a
/// subdirectory, not a separate root.
pub type Entry {
    /// A compiled object or a linked binary.
    artifact,
    /// A `check` result: the rendered diagnostics, replayed verbatim on a
    /// hit. Cheap to store because `FileCheckResult.diagnostics` is
    /// already a list of fully-rendered strings (lang/src/module.mo) that
    /// `print_diagnostics` (cli/src/main.mo) just prints -- no spans are
    /// re-derived at print time, so a replay is byte-exact.
    check,
    /// A `test` result: the `<failed>/<total>` pair AND the driver's
    /// stdout. The stdout is not optional -- the per-test PASS/FAIL lines
    /// are printed by the driver BINARY
    /// (lang/src/codegen/test_driver.mo), and the CLI only ever sees the
    /// aggregate count from the `__MONAD_TEST__` marker file. Without the
    /// stdout a cached hit could report "11/11 passed" and not name one
    /// of them, which would make hits strictly less informative than
    /// misses.
    test,
}

open Entry {artifact, check, test}

def Build.entry_dir (e : Entry) : String :=
    match e {
        artifact => "store",
        check => "check",
        test => "test",
    }

/// Where artifacts go. Highest precedence first:
///
///   1. `--target-dir <dir>`      an explicit request wins outright
///   2. `MONAD_TARGET_DIR`        the environment
///   3. `[build] target-dir`      the manifest
///   4. `<root>/target`           the default
///
/// Four tiers rather than a bare default because **cargo already owns
/// `target/debug` and `target/release` in this very repository**. Without
/// an opt-out, `cargo clean` would delete monad's store and `monad clean`
/// would delete cargo's artifacts. The manifest tier is what lets this
/// repo say `target/monad` in its own root `mote.toml` while a user with
/// no Cargo.toml still gets the obvious plain `target/`.
///
/// Pure, and takes the env and manifest values as arguments rather than
/// reading them, so every tier is testable without a process environment
/// or a manifest on disk.
pub def Build.resolve_target_dir (flag : String) (env : Option String) (manifest : Option String) (root : String) : String :=
    if Bool.not (String.is_empty flag) then flag
    else match env {
        Option.some e => if String.is_empty e then Build.target_dir_from_manifest manifest root else e,
        Option.none => Build.target_dir_from_manifest manifest root
    }

def Build.target_dir_from_manifest (manifest : Option String) (root : String) : String :=
    match manifest {
        Option.some m => if String.is_empty m then Build.default_target_dir root else m,
        Option.none => Build.default_target_dir root
    }

/// `<root>/target`, or plain `target` when the root is the working
/// directory. `raw_path_join`'s empty-component rule, spelled out here
/// because `root ++ "/target"` would produce the ABSOLUTE `/target` for
/// an empty root -- the same bug `MoteManifest.src_root`
/// (lang/src/mote.mo) documents for the mote whose manifest sits in the
/// working directory.
def Build.default_target_dir (root : String) : String :=
    if String.is_empty root then "target"
    else if String.beq root "." then "target"
    else String.concat root "/target"

/// The env tier, read once by a caller and passed into
/// `Build.resolve_target_dir`.
#[partial]
pub def Build.target_dir_of (flag : String) (manifest : Option String) (root : String) : IO String := do {
    let e <- IO.get_env "MONAD_TARGET_DIR";
    return (Build.resolve_target_dir flag e manifest root)
}

/// `<dir>`'s target directory: all four tiers of `resolve_target_dir`,
/// resolved from where `dir` sits in the tree.
///
/// `Mote.discover_build_dir`, not `Mote.discover`: the latter stops at a
/// virtual workspace root -- a root declares no `[mote]`, so a walk-up
/// finds nothing there -- so a script-mode file under one (anything in
/// `examples/`) would never see the workspace's `[build] target-dir` and
/// would write to plain `target/`, straight into cargo's directory. That
/// is the exact collision the setting exists to prevent.
#[partial]
pub def Build.target_dir_at (dir : String) : IO String := do {
    let d <- Mote.discover_build_dir dir;
    Build.target_dir_of "" d ""
}

/// The target directory for a SOURCE FILE, resolved from its directory.
#[partial]
pub def Build.target_dir_for (src : String) : IO String :=
    Build.target_dir_at (extract_directory src)

/// `<target-dir>/<kind>` -- the directory every entry of one kind lives
/// in, before the hash is appended. Shared by `ensure_entry_dir` and by
/// callers that make a directory PER ENTRY rather than per kind (the
/// `check` and `test` caches, whose entries are two files each).
pub def Build.entry_root_dir (target_dir : String) (e : Entry) : String :=
    String.concat target_dir (String.concat "/" (Build.entry_dir e))

/// The name of one store entry: `<kind>/<hash>-<slug>`.
///
/// The hash comes first so the directory sorts by key rather than by
/// name, and the slug exists only so a human reading `ls` can tell what an
/// entry is. Nothing parses it back out -- the hash is the identity, and
/// the slug is allowed to be ambiguous.
///
/// **The artifact cache passes `""`.** It used to pass the output's bare
/// name, which quietly made the name an INPUT: a build under `-o a` could
/// not share with the same build under `-o b`, so one unchanged source
/// compiled twice. The name reached the artifact through the intermediate
/// `.ll` file, whose path `llc` records in the object it emits -- see
/// `artifact_ir_path` below, which is where that is fixed. With the IR
/// keyed, the artifact is a function of the key again and the entry name
/// can say so. The human-readable half belongs in `db/<hash>.json`, the
/// metadata kind the plan's layout reserves for exactly this.
pub def Build.store_path (target_dir : String) (e : Entry) (hash : String) (slug : String) : String :=
    String.concat target_dir
        (String.concat "/"
            (String.concat (Build.entry_dir e)
                (String.concat "/" (String.concat hash (Build.slug_suffix slug)))))

def Build.slug_suffix (slug : String) : String :=
    if String.is_empty slug then "" else String.concat "-" slug

/// `<target-dir>/store/<hash>.ll` -- the LLVM IR one artifact key compiles
/// from, and the file `llc` is actually pointed at.
///
/// The IR lives in the store under the KEY, and that is a correctness
/// requirement rather than tidiness. `llc` records the INPUT file's name
/// in the object it emits (an `STT_FILE` symbol, visible in the linked
/// binary's string table), so naming the IR after the user's `-o` puts the
/// output name inside the artifact -- which makes the artifact a function
/// of something that is not an input. Two builds of one source under two
/// `-o` names then differ by exactly one byte, and the whole point of a
/// cache -- hit as long as nothing important has changed -- fails for a
/// reason that has nothing to do with the source, the compiler, or the
/// profile.
///
/// Keying it fixes that by construction: the same key gives the same IR
/// path, so the same object, the same binary, and an entry that can be
/// named by the key alone. It also makes the IR safe to leave behind --
/// content-addressed, so the file a `cached:` line names is still the one
/// that build compiled, and an IR-reading gate can go and read it instead
/// of arranging an `-o` that spells its own path.
///
/// The `.ll` the caller's `-o` implies is still written beside the binary
/// (`link_ir`), as a convenience copy for exactly those readers. That copy
/// is an OUTPUT; it is never what `llc` compiles, or the leak returns.
pub def Build.artifact_ir_path (target_dir : String) (hash : String) : String :=
    String.concat (Build.entry_root_dir target_dir Entry.artifact)
        (String.concat "/" (String.concat hash ".ll"))

/// `mkdir -p` a directory. Shelled out because there is no mkdir native,
/// which is already how `llvm/src/link.mo` creates its own output
/// directory.
#[partial]
pub def Build.ensure_dir (d : String) : IO I64 := do {
    let r <- Proc.capture "sh" ["-c", String.concat "mkdir -p " (Proc.shell_quote d)];
    match r { Pair.pair code _out => return code }
}

/// `mkdir -p` the directory one KIND of entry lives in.
#[partial]
pub def Build.ensure_entry_dir (target_dir : String) (e : Entry) : IO I64 :=
    Build.ensure_dir (Build.entry_root_dir target_dir e)
