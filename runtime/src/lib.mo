// The runtime mote's library root -- bare `use runtime` resolves here.
//
// The C runtime is linked into every compiled binary, so its path is a
// build input that both the compiler's CLI and the codegen e2e harness
// need. It lives here, in the mote that owns the file, rather than being
// copied into each call site -- which is what it was before, in four
// places that all had to be found by hand when the file moved.

pub use lib::natives {runtime_native_functions}

/// Path to the C runtime source, relative to the repository root.
///
/// Repo-root-relative, and this is now the LAST tier of
/// `lang.module.mo`'s `resolve_runtime_src`, not the only spelling callers
/// have: a mote that declares `[dependencies.runtime] path` answers first,
/// then an installed toolchain root, then the workspace root above the
/// working directory, and only then this literal -- which is the right
/// answer exactly when the working directory IS the repository root. Kept
/// here, in the mote that owns the C file, rather than repeated at each
/// call site (it used to be copied into four of them, and they all had to
/// be found by hand when the file moved).
pub def Runtime.c_path : String := "runtime/src/runtime.c"
