// The build mote's library root -- bare `use build` resolves here.
//
// Only the hashing layer so far. The store, the cache and the driver land
// on top of it (plans/packaging/mote-build-deps-artifacts-targets.md
// phases 2a-2c); this file is where they get re-exported from.

pub use lib::hash {DigestTool, file_digest_with, probe_digest_tool, tree_digest, tree_digest_with}
pub use lib::identity {compiler_digest, compiler_digest_with, compiler_exe_path}
pub use lib::closure {closure_digest_with, input_hash, input_hash_with}
pub use lib::store {Entry, ensure_entry_dir, resolve_target_dir, store_path, target_dir_of}
