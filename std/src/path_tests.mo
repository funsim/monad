// Regression tests for std/path.mo -- most directly
// test_path_join_absolute_rhs_discards_lhs, exercising the exact bug
// this type was introduced to prevent (a naive `++`-joined output path
// silently doubling up when one half was already absolute).

#[test]
def test_path_join_absolute_rhs_discards_lhs : Bool :=
    match Path.of "/tmp" {
        err _ => false,
        ok a => match Path.of "/tmp/monad_v2" {
            err _ => false,
            ok b => String.beq (Path.to_string (Path.join a b)) "/tmp/monad_v2",
        },
    }

#[test]
def test_path_join_relative_rhs_concatenates : Bool :=
    match Path.of "/tmp" {
        err _ => false,
        ok a => match Path.of "monad_v2" {
            err _ => false,
            ok b => String.beq (Path.to_string (Path.join a b)) "/tmp/monad_v2",
        },
    }

#[test]
def test_path_is_absolute : Bool :=
    match Path.of "/tmp" {
        err _ => false,
        ok a => match Path.of "tmp" {
            err _ => false,
            ok b => Path.is_absolute a && not (Path.is_absolute b),
        },
    }

// `raw_path_join` at the `String` level. The absolute-rhs rule used to
// live only in `Path.join`, so every direct caller of the raw join kept
// the bug the `Path` type exists to prevent -- most visibly
// `Mote.dep_dir_entries_go`, which joins a manifest `[dependencies.X]
// path` onto the mote's own directory. With a bare invocation that
// directory is ".", so an absolute path dep came out as "./<abs>" and
// the dependency silently did not resolve.

/// The exact shape the bare-invocation bug produced.
#[test]
def test_raw_path_join_absolute_rhs_discards_lhs : Bool :=
    String.beq (raw_path_join "." "/home/x/init") "/home/x/init"

#[test]
def test_raw_path_join_absolute_rhs_with_empty_lhs : Bool :=
    String.beq (raw_path_join "" "/home/x/init") "/home/x/init"

/// A relative rhs must still concatenate -- the fix must not make every
/// join absolute-ish.
#[test]
def test_raw_path_join_relative_rhs_concatenates : Bool :=
    String.beq (raw_path_join "." "init") "./init"

#[test]
def test_raw_path_join_relative_rhs_under_absolute_lhs : Bool :=
    String.beq (raw_path_join "/tmp" "monad_v2") "/tmp/monad_v2"

#[test]
def test_raw_path_join_empty_components_are_noop : Bool :=
    String.beq (raw_path_join "" "init") "init"
    && String.beq (raw_path_join "/tmp" "") "/tmp"
    && String.beq (raw_path_join "" "") ""

#[test]
def test_raw_path_join_trailing_slash_lhs : Bool :=
    String.beq (raw_path_join "a/" "b") "a/b"

#[test]
def test_path_of_rejects_empty : Bool :=
    match Path.of "" { err _ => true, ok _ => false }

#[test]
def test_path_with_suffix : Bool :=
    match Path.of "/tmp/monad_v2" {
        err _ => false,
        ok p => String.beq (Path.to_string (Path.with_suffix p ".ll")) "/tmp/monad_v2.ll",
    }

#[test]
def test_path_beq : Bool :=
    match Path.of "/tmp" {
        err _ => false,
        ok a => match Path.of "/tmp" {
            err _ => false,
            ok b => a == b,
        },
    }

// `Path.parent` -- the directory half, with "" meaning "no directory"
// (which callers must NOT pass to `mkdir -p`).

#[test]
def test_path_parent_of_nested_path : Bool :=
    String.beq (Path.parent (Path.path "/tmp/out/monad")) "/tmp/out"

#[test]
def test_path_parent_of_bare_filename_is_empty : Bool :=
    String.beq (Path.parent (Path.path "hello.mo")) ""

#[test]
def test_path_parent_of_root_child : Bool :=
    String.beq (Path.parent (Path.path "/monad")) ""

#[test]
def test_path_parent_keeps_relative_prefix : Bool :=
    String.beq (Path.parent (Path.path "out/bin/monad")) "out/bin"
