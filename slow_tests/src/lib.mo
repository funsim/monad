// The slow_tests mote's library root -- bare `use slow_tests` resolves
// here.
//
// Deliberately EMPTY, following proofs/src/lib.mo, and the reason is
// measurable rather than a placeholder: none of this mote's 27 modules has
// a public surface to re-export. There are 170 `#[test]` defs and two
// `pub` lines in the whole tree, and the two are accessors the tests
// themselves use. These are tests -- `parser_file_tests.mo`,
// `scope_all_tests.mo`, `typecheck_lang_tests.mo` and the codegen suites
// are the self-hosted pipeline's regression net -- and a test file's
// surface is not an API.
//
// Nor would a list here be reachable. `monad test <dir>` finds these files
// through `expand_check_paths` (lang/src/module.mo), which walks the
// directory for `.mo` and never consults a library root; a re-export list
// could only go stale without anything reading it.
//
// What the file buys is what the gate and the consumer both want: the mote
// has a target, so `use slow_tests` resolves and the mote is not the one
// non-compliant tree in the workspace.
