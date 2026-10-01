/// Input hashing: the content digest a cache key is built from.
///
/// The split here is the whole design. Bulk digesting -- megabytes of
/// `.mo` source -- is delegated to the platform's digest tool in ONE fork
/// per mote, because `std/src/sha256.mo` is pure Monad at several nested
/// calls per byte: correct, and fine for the few hundred bytes of LISTING
/// this module hashes itself, hopeless over a source tree. The tool's
/// output is already the sorted `(path, content hash)` pairs an input hash
/// wants, so nothing is re-sorted in Monad, and the final combining hash
/// IS Monad code, so it is unit-testable and identical on both runtimes.

use std::process {exec_cmd}
use std::sha256 {Sha256.hash}

/// The digest tool this machine has.
///
/// Two, both testable here. `certutil -hashfile` is the Windows
/// equivalent and is deliberately NOT a constructor: an untested code
/// path claiming Windows support is worse than an error message that says
/// it is missing, which is what `Build.no_digest_tool_error` does.
pub type DigestTool {
    sha256sum,
    shasum_256,
}

open DigestTool {sha256sum, shasum_256}

/// What to hand `find -exec`.
def Build.tool_exec (t : DigestTool) : String :=
    match t {
        sha256sum => "sha256sum",
        shasum_256 => "shasum -a 256",
    }

/// Named, because this is a refusal and not a fallback.
///
/// Falling back to file timestamps would make a stale artifact look
/// fresh, which is the one failure a build cache must never have -- so a
/// missing tool stops the cache rather than weakening it. That is the
/// "only cache safe and expensive work" rule applied to its own
/// prerequisite.
def Build.no_digest_tool_error : String :=
    "no content-digest tool on PATH: tried `sha256sum` (GNU coreutils) and `shasum` (Darwin). A build cache cannot be keyed without one, and falling back to file timestamps would let a stale artifact look fresh -- so this is an error, not a warning. On Windows the equivalent is `certutil -hashfile`, which is not wired up yet."

def Build.digest_failed_error (dir : String) (out : String) : String :=
    String.concat "could not digest " (String.concat dir (String.concat ": " out))

/// Which digest tool is available.
///
/// `exec_cmd` rather than `Proc.capture`: only the exit status matters,
/// and capturing would cost a temp file and two more forks per probe.
/// Probe ONCE and pass the result down -- there is nowhere to cache it,
/// and a probe per mote is a fork per mote for nothing.
#[partial]
pub def Build.probe_digest_tool : IO (Result String DigestTool) := do {
    let has_sha256sum <- exec_cmd "sh" ["-c", "command -v sha256sum >/dev/null 2>&1"];
    if has_sha256sum == 0
    then return (ok sha256sum)
    else do {
        let has_shasum <- exec_cmd "sh" ["-c", "command -v shasum >/dev/null 2>&1"];
        if has_shasum == 0
        then return (ok shasum_256)
        else return (err Build.no_digest_tool_error)
    }
}

/// The directory the digest walks, as a shell word.
///
/// An empty root means the working directory -- the convention
/// `Build.default_target_dir` and `MoteManifest.src_root` both spell out --
/// and it arrives here for the most ordinary layout there is: a mote whose
/// `mote.toml` sits in the working directory, built as
/// `cd mymote && monad build src/main.mo`. `Mote.discover` reports that
/// manifest's directory as `""` (the same tree spelled `./src/main.mo`
/// gives `"."`), and the shell cannot take the empty one: `cd ''` fails
/// with "no such file or directory", so `tree_digest_with` is an error, so
/// `Build.input_hash` is an error, so `build_cached` falls back to
/// `compile_file` with the cache OFF -- silently, apart from one line
/// under `--verbose`. Measured, one file and one directory, two spellings:
/// `src/main.mo` wrote no store entry at all, `./src/main.mo` wrote one.
///
/// So the one consumer that forgot the convention spells it out. `.` is the
/// same directory under a name the shell accepts, and the digest does not
/// depend on which spelling it got (`find` prints `./src/main.mo` either
/// way) -- which is what makes the two spellings of one build share an
/// entry rather than each compiling.
def Build.digest_dir (dir : String) : String :=
    if String.is_empty dir then "." else dir

/// The shell pipeline. Three choices in it are load-bearing for a cache
/// key, and none of them is incidental:
///
/// `cd` first and `find .`, so the listing carries RELATIVE paths: a
/// mote's digest must not move when the checkout does, or two worktrees
/// at the same commit would never share an entry.
///
/// `LC_ALL=C sort`, so the order is byte order and not the machine's
/// locale -- otherwise the same tree hashes differently on two machines.
///
/// `-exec ... +` rather than `xargs -0`, because `find` with no matches
/// runs no command at all, whereas `xargs` without the non-POSIX `-r`
/// would run the digest tool with no arguments and it would sit reading
/// stdin. An empty tree has to produce a digest, not a hang.
///
/// The input set -- `.mo`, `.c`, `.h`, `mote.toml` -- is exactly what
/// `scripts/build-self-hosted.sh`'s staleness scan already treats as the
/// compiler's inputs, and `mote.toml` is in it because
/// `gate_declared_deps` (lang/src/module.mo) can fail a load on a
/// manifest edit alone.
///
/// Its directory arrives through `Build.digest_dir` rather than directly,
/// because the empty root names the working directory and the shell cannot
/// take it -- the two spellings of one build then share an entry instead of
/// each compiling.
def Build.digest_script (tool : DigestTool) (dir : String) : String :=
    String.concat "cd "
        (String.concat (Proc.shell_quote (Build.digest_dir dir))
            (String.concat " && find . -type f \\( -name '*.mo' -o -name '*.c' -o -name '*.h' -o -name mote.toml \\) -exec "
                (String.concat (Build.tool_exec tool) " {} + | LC_ALL=C sort")))

/// Digest everything under `dir` that the compiler reads.
#[partial]
pub def Build.tree_digest_with (tool : DigestTool) (dir : String) : IO (Result String String) := do {
    let r <- Proc.capture "sh" ["-c", Build.digest_script tool dir];
    match r {
        Pair.pair code out =>
            if code == 0
            then return (ok (Sha256.hash out))
            else return (err (Build.digest_failed_error dir out))
    }
}

/// The digest of ONE file's contents, with no path in it.
///
/// The tool reads STDIN rather than being handed a filename, so its
/// output is `<hex>  -` and carries no trace of where the file lives.
/// That is the point: this is used for the compiler binary's own
/// identity, and a key that moved when the binary moved would miss on
/// every worktree.
#[partial]
pub def Build.file_digest_with (tool : DigestTool) (path : String) : IO (Result String String) := do {
    let script : String :=
        String.concat (Build.tool_exec tool) (String.concat " < " (Proc.shell_quote path));
    let r <- Proc.capture "sh" ["-c", script];
    match r {
        Pair.pair code out =>
            if code == 0
            then return (ok (Sha256.hash out))
            else return (err (Build.digest_failed_error path out))
    }
}

/// Probe, then digest. For one mote; callers digesting a whole closure
/// should probe once themselves and use `Build.tree_digest_with`.
#[partial]
pub def Build.tree_digest (dir : String) : IO (Result String String) := do {
    let t <- Build.probe_digest_tool;
    match t {
        err m => return (err m),
        ok tool => Build.tree_digest_with tool dir
    }
}
