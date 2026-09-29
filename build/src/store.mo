/// Where build output goes, and what an entry in it is called.
///
/// Paths only -- this module decides names and answers "where", and does
/// not read or write anything. The I/O sits above it (phase 2a of
/// plans/packaging/mote-build-deps-artifacts-targets.md), which keeps
/// every naming rule here testable without touching a filesystem.

use io {IO}
use std::io {get_env}
use std::process {capture, shell_quote}

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

/// The name of one store entry: `<kind>/<hash>-<slug>`.
///
/// The hash comes first so the directory sorts by key rather than by
/// name, and the slug is there only so a human reading `ls` can tell what
/// an entry is. Nothing parses it back out -- the hash is the identity,
/// and the slug is allowed to be ambiguous.
///
/// The slug carries the mote NAME and VERSION even though nothing reads
/// them, because the per-mote compilation model
/// (monad-build.md's B1) will add one entry per mote and this way that
/// addition needs no store migration: the names it wants already fit.
pub def Build.store_path (target_dir : String) (e : Entry) (hash : String) (slug : String) : String :=
    String.concat target_dir
        (String.concat "/"
            (String.concat (Build.entry_dir e)
                (String.concat "/" (String.concat hash (Build.slug_suffix slug)))))

def Build.slug_suffix (slug : String) : String :=
    if String.is_empty slug then "" else String.concat "-" slug

/// `mkdir -p` the directory an entry lives in. Shelled out because there
/// is no mkdir native, which is already how `llvm/src/link.mo` creates
/// its own output directory.
#[partial]
pub def Build.ensure_entry_dir (target_dir : String) (e : Entry) : IO I64 := do {
    let d : String := String.concat target_dir (String.concat "/" (Build.entry_dir e));
    let r <- Proc.capture "sh" ["-c", String.concat "mkdir -p " (Proc.shell_quote d)];
    match r { Pair.pair code _out => return code }
}
