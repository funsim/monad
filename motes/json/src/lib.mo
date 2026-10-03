// The json mote's library root -- bare `use json` resolves here.
//
// One module, so this is thin by construction: the `Json` a parsed document
// is, its error, and the reader/writer pair. Every consumer in this repo
// imports `Json` and nothing else -- `motes/toolkit` and `motes/lsp` build
// JSON with `Json.make_*` and read it with `Json.get_*`, which they reach
// by naming the module (`use json::json {...}`), exactly as they always
// have.
//
// No `{*}` globs.

pub use lib::json {Json, Json.ParseError, Json.parse, Json.to_string}
