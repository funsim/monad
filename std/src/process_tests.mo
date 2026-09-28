/// Tests for `std/src/process.mo`.
///
/// A separate file because `process.mo` is re-exported by `std/src/lib.mo`
/// and therefore seeded ambiently into every module closure, which makes
/// a `#[test]` inside it undiscoverable -- see that file's note. Same
/// reason `path_tests.mo` and `sha256_tests.mo` are separate.
///
/// Same mote, so `Proc.first_quote` stays package-private and is still
/// reachable here -- no API had to be widened to test it.

use lib::process {capture, first_quote, shell_quote}

// ─── Tests: shell_quote ───

#[test]
def test_shell_quote_wraps_in_single_quotes : Bool :=
    String.beq (Proc.shell_quote "abc") "'abc'"

#[test]
def test_shell_quote_keeps_a_space_in_one_word : Bool :=
    String.beq (Proc.shell_quote "a b") "'a b'"

#[test]
def test_shell_quote_empty_is_an_empty_word : Bool :=
    String.beq (Proc.shell_quote "") "''"

/// The whole point: an embedded quote closes, escapes, and reopens.
#[test]
def test_shell_quote_escapes_an_embedded_quote : Bool :=
    String.beq (Proc.shell_quote "it's") "'it'\\''s'"

#[test]
def test_shell_quote_escapes_every_quote : Bool :=
    String.beq (Proc.shell_quote "'a'") "''\\''a'\\'''"

#[test]
def test_shell_quote_leaves_a_dollar_sign_alone : Bool :=
    String.beq (Proc.shell_quote "$HOME") "'$HOME'"

#[test]
def test_first_quote_finds_nothing_in_a_plain_word : Bool :=
    match Proc.first_quote "abc" {
        Option.none => true,
        Option.some _ => false
    }

#[test]
def test_first_quote_finds_the_first_of_two : Bool :=
    match Proc.first_quote "ab'c'd" {
        Option.some i => i == 2,
        Option.none => false
    }

// ─── Tests: capture ───

#[test]
def test_capture_returns_status_and_stdout : IO Bool := do {
    let r <- Proc.capture "echo" ["hi"];
    match r { Pair.pair code out => return (code == 0 && String.beq out "hi\n") }
}

/// Exit status and stderr in one assertion, because both are things
/// `exec_cmd` alone cannot give a caller.
#[test]
def test_capture_merges_stderr_and_keeps_the_exit_status : IO Bool := do {
    let r <- Proc.capture "sh" ["-c", "echo e >&2; exit 3"];
    match r { Pair.pair code out => return (code == 3 && String.beq out "e\n") }
}

/// The injection test. `$HOME` must arrive at `echo` as four literal
/// characters; if `Proc.shell_quote` is ever dropped from the argv
/// construction, the shell expands it here and this fails.
#[test]
def test_capture_does_not_expand_a_dollar_sign : IO Bool := do {
    let r <- Proc.capture "echo" ["$HOME"];
    match r { Pair.pair _code out => return (String.beq out "$HOME\n") }
}

/// A word with a quote in it survives the round trip through `sh -c`.
#[test]
def test_capture_passes_an_embedded_quote_through : IO Bool := do {
    let r <- Proc.capture "echo" ["it's"];
    match r { Pair.pair _code out => return (String.beq out "it's\n") }
}

/// A command that does not exist is a nonzero status and a message, not a
/// crash and not an empty string.
#[test]
def test_capture_of_a_missing_command_is_nonzero : IO Bool := do {
    let r <- Proc.capture "monad_no_such_command_exists" [];
    match r { Pair.pair code _out => return (Bool.not (code == 0)) }
}
