// The http mote's library root -- bare `use http` resolves here.
//
// Deliberately EMPTY for now, following proofs/src/lib.mo, and the reason
// is a decision this file is not the place to make: none of the five
// modules -- `types` (`Request`/`Response`/`Uri`), `uri`, `strings`,
// `body`, `wire` -- declares anything `pub`. They work from other motes
// only because package-private still crosses mote boundaries today, which
// is a warning (`core/src/term/module.rs`) and is documented to become an
// error.
//
// A re-export list here would therefore have to name package-private
// defs, which warns, and would freeze the question "which of these are
// this mote's API?" without anyone having answered it. The honest state is
// that `http` is a working implementation with an unmade API decision, and
// the win available today is the one this file delivers: `use http`
// resolves, so a consumer can declare the dependency.
//
// The surface gets written when the `pub` markers do.
