// The build mote's library root -- bare `use build` resolves here.
//
// Only the hashing layer so far. The store, the cache and the driver land
// on top of it (plans/packaging/mote-build-deps-artifacts-targets.md
// phases 2a-2c); this file is where they get re-exported from.

pub use lib::hash {DigestTool, file_digest_with, probe_digest_tool, tree_digest, tree_digest_with}
pub use lib::identity {compiler_digest, compiler_digest_with, compiler_exe_path}
pub use lib::closure {closure_digest_with, input_hash, input_hash_with}
pub use lib::store {Entry, artifact_ir_path, ensure_dir, ensure_entry_dir, entry_root_dir, resolve_target_dir, store_path, target_dir_at, target_dir_for, target_dir_of}
pub use lib::check {CheckPlan, check_block, check_entry_read, check_entry_dir, check_maybe_write, check_plan, check_plan_active, check_plan_key, check_plan_reason, check_plan_root, check_worth_caching, mote_root_of}
