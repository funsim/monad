// The example mote's library root -- bare `use example` resolves here.
//
// Deliberately EMPTY: this mote is one module (`greet.mo`) holding one def
// (`greet`) that nothing declares `pub` and nothing imports. It exists as
// the smallest thing that is a mote -- a manifest, a `src/` tree, a
// dependency edge -- which is what `docs/src/getting-started.md` points a
// new reader at.
//
// A re-export of `greet` would be the only line this file could carry, and
// it would be re-exporting a name whose definition is a single
// `String.concat`. The hub is what makes `use example` resolve; a real
// surface is for a mote that has one.
