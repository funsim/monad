// The toml mote's library root -- bare `use toml` resolves here.
//
// One module, so this hub is thin by construction: the `Toml.Value` a
// parsed document is, the reader that produces it, and the two lookups a
// caller walks the result with. `lang/src/mote.mo` is the load-bearing
// consumer -- every `mote.toml` in this repo is read through it -- and
// these five names are the whole of what it imports.
//
// Small rather than a mirror, as `lang/src/lib.mo` argues: `Toml.to_string`
// and the `Toml.insert_at_steps` assembler are reached by naming the
// module, which is what `motes/toml/src/toml.mo`'s own tests and
// `examples/toml.mo` already do.
//
// No `{*}` globs.

pub use lib::toml {Toml.Value, Toml.ParseError, Toml.parse, Toml.table_get, Toml.array_at}
