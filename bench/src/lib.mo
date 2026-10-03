// The bench mote's library root -- bare `use bench` resolves here.
//
// Deliberately EMPTY, following proofs/src/lib.mo. Every module here is a
// benchmark rather than a library: each one declares its measurement as
// `#[test]` defs so `monad test bench` runs it, and the tree has no `pub`
// declaration at all. `scope_lookup.mo`, `parser_take_while.mo` and
// `hashmap_bucket_dispatch.mo` are experiments whose RESULT is a number
// recorded in a plan document, not a function anyone calls.
//
// `monad test bench` reaches them through `expand_check_paths`
// (lang/src/module.mo), which walks for `.mo` and never consults a library
// root, so a re-export list here would serve nothing.
//
// What the file buys is that the mote has a target: `use bench` resolves.
