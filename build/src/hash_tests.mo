/// Tests for `build/src/hash.mo`.
///
/// Every one of these is about a property a CACHE KEY needs, not about
/// SHA-256 (std/src/sha256_tests.mo already pins the FIPS vectors). The
/// interesting ones are the two negatives: a digest must not move when a
/// file's timestamp moves, and must not move when the tree does.
///
/// Fixtures are built by shelling out because `IO.write_file` is
/// package-private to `std`, and widening it for a test is the wrong
/// trade.

use io {IO}
use std::process {capture, process_id, shell_quote}
use lib::hash {probe_digest_tool, tree_digest}

/// A pid-and-tag-scoped fixture root, created empty. Pid-scoped because
/// the corpus sweep runs sharded and a fixed `/tmp` name would collide
/// across concurrent shards.
def Build.fixture_root (tag : String) : String :=
    String.concat "/tmp/monad_hash_fix_"
        (String.concat (I64.to_string process_id) (String.concat "_" tag))

def Build.fresh_fixture (tag : String) : IO String := do {
    let d : String := Build.fixture_root tag;
    let q : String := Proc.shell_quote d;
    let _r <- Proc.capture "sh" ["-c", String.concat "rm -rf " (String.concat q (String.concat " && mkdir -p " (String.concat q "/src")))];
    return d
}

def Build.put_file (dir : String) (rel : String) (content : String) : IO I64 := do {
    let path : String := String.concat dir (String.concat "/" rel);
    let script : String :=
        String.concat "printf %s "
            (String.concat (Proc.shell_quote content)
                (String.concat " > " (Proc.shell_quote path)));
    let r <- Proc.capture "sh" ["-c", script];
    match r { Pair.pair code _out => return code }
}

def Build.rm_fixture (dir : String) : IO I64 := do {
    let r <- Proc.capture "sh" ["-c", String.concat "rm -rf " (Proc.shell_quote dir)];
    match r { Pair.pair code _out => return code }
}

/// `""` for a failure, so a test can compare two digests as plain strings
/// and a separate test asserts that success happens at all.
def Build.digest_or_empty (r : Result String String) : String :=
    match r { ok h => h, err _ => "" }

// ─── Tests ───

/// The machine this runs on has a digest tool. If this fails, every test
/// below is meaningless rather than wrong.
#[test]
def test_probe_finds_a_digest_tool : IO Bool := do {
    let t <- Build.probe_digest_tool;
    match t { ok _ => return true, err _ => return false }
}

#[test]
def test_tree_digest_of_a_fixture_succeeds : IO Bool := do {
    let d <- Build.fresh_fixture "ok";
    let _w <- Build.put_file d "src/a.mo" "def a : I64 := 1\n";
    let r <- Build.tree_digest d;
    let _c <- Build.rm_fixture d;
    return (Bool.not (String.is_empty (Build.digest_or_empty r)))
}

#[test]
def test_tree_digest_is_stable_across_two_runs : IO Bool := do {
    let d <- Build.fresh_fixture "stable";
    let _w <- Build.put_file d "src/a.mo" "def a : I64 := 1\n";
    let r1 <- Build.tree_digest d;
    let r2 <- Build.tree_digest d;
    let _c <- Build.rm_fixture d;
    return (String.beq (Build.digest_or_empty r1) (Build.digest_or_empty r2))
}

#[test]
def test_tree_digest_changes_when_a_byte_changes : IO Bool := do {
    let d <- Build.fresh_fixture "byte";
    let _w1 <- Build.put_file d "src/a.mo" "def a : I64 := 1\n";
    let r1 <- Build.tree_digest d;
    let _w2 <- Build.put_file d "src/a.mo" "def a : I64 := 2\n";
    let r2 <- Build.tree_digest d;
    let _c <- Build.rm_fixture d;
    return (Bool.not (String.beq (Build.digest_or_empty r1) (Build.digest_or_empty r2)))
}

#[test]
def test_tree_digest_changes_when_a_file_is_added : IO Bool := do {
    let d <- Build.fresh_fixture "added";
    let _w1 <- Build.put_file d "src/a.mo" "def a : I64 := 1\n";
    let r1 <- Build.tree_digest d;
    let _w2 <- Build.put_file d "src/b.mo" "def b : I64 := 2\n";
    let r2 <- Build.tree_digest d;
    let _c <- Build.rm_fixture d;
    return (Bool.not (String.beq (Build.digest_or_empty r1) (Build.digest_or_empty r2)))
}

/// A manifest edit alone must move the digest: `gate_declared_deps`
/// (lang/src/module.mo) can fail a load on `mote.toml` with every source
/// byte unchanged, so a key that ignored the manifest would cache a
/// result the manifest had already invalidated.
#[test]
def test_tree_digest_covers_the_manifest : IO Bool := do {
    let d <- Build.fresh_fixture "manifest";
    let _w1 <- Build.put_file d "src/a.mo" "def a : I64 := 1\n";
    let _m1 <- Build.put_file d "mote.toml" "[mote]\nname = \"x\"\n";
    let r1 <- Build.tree_digest d;
    let _m2 <- Build.put_file d "mote.toml" "[mote]\nname = \"y\"\n";
    let r2 <- Build.tree_digest d;
    let _c <- Build.rm_fixture d;
    return (Bool.not (String.beq (Build.digest_or_empty r1) (Build.digest_or_empty r2)))
}

/// CONTENT-addressed, not timestamp-addressed. `touch` moves the mtime
/// and nothing else, and the digest must not notice -- this is the whole
/// difference between this and `scripts/build-self-hosted.sh`'s staleness
/// scan.
#[test]
def test_tree_digest_ignores_a_touch : IO Bool := do {
    let d <- Build.fresh_fixture "touch";
    let _w <- Build.put_file d "src/a.mo" "def a : I64 := 1\n";
    let r1 <- Build.tree_digest d;
    let _t <- Proc.capture "sh" ["-c", String.concat "touch " (Proc.shell_quote (String.concat d "/src/a.mo"))];
    let r2 <- Build.tree_digest d;
    let _c <- Build.rm_fixture d;
    return (String.beq (Build.digest_or_empty r1) (Build.digest_or_empty r2))
}

/// Identical content at two different paths digests identically, which is
/// what lets two worktrees at the same commit share a cache entry. This
/// is why the script does `cd` + `find .` instead of `find <dir>`.
#[test]
def test_tree_digest_is_independent_of_the_path : IO Bool := do {
    let d1 <- Build.fresh_fixture "here";
    let d2 <- Build.fresh_fixture "there";
    let _w1 <- Build.put_file d1 "src/a.mo" "def a : I64 := 1\n";
    let _w2 <- Build.put_file d2 "src/a.mo" "def a : I64 := 1\n";
    let r1 <- Build.tree_digest d1;
    let r2 <- Build.tree_digest d2;
    let _c1 <- Build.rm_fixture d1;
    let _c2 <- Build.rm_fixture d2;
    return (String.beq (Build.digest_or_empty r1) (Build.digest_or_empty r2))
}

/// An empty tree is a digest, not a hang. `find -exec ... +` runs nothing
/// when nothing matches; `xargs -0` without the non-POSIX `-r` would have
/// run the digest tool with no arguments and sat reading stdin.
#[test]
def test_tree_digest_of_an_empty_tree_succeeds : IO Bool := do {
    let d <- Build.fresh_fixture "empty";
    let r <- Build.tree_digest d;
    let _c <- Build.rm_fixture d;
    match r { ok _ => return true, err _ => return false }
}

/// A directory that does not exist is an error naming the directory, not
/// a silently-empty digest that would collide with the empty tree above.
#[test]
def test_tree_digest_of_a_missing_directory_errors : IO Bool := do {
    let r <- Build.tree_digest (Build.fixture_root "nonexistent_on_purpose");
    match r { ok _ => return false, err _ => return true }
}
