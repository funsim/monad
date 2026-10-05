// The ffi_example mote's library root -- bare `use ffi_example` resolves
// here.
//
// Deliberately EMPTY: three of this mote's four modules are the end-to-end
// test itself (`ffi_test.mo` plus the `ffi_link_test.mo`/
// `ffi_codegen_e2e_test.mo` pair that compile and RUN the emitted binary),
// and the fourth
// (`libc.mo`) is declarative `#[extern "c"]` bindings -- a set of symbols
// for the tests to call, not a library anyone imports. No consumer in the
// repo depends on this mote, and nothing in it is marked `pub`.
//
// What the file buys is that the mote has a target: `use ffi_example`
// resolves. A fixture whose whole point is to be linked and executed needs
// a library root for the same reason a real mote does.
