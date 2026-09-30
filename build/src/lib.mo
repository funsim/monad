// The build mote's library root -- bare `use build` resolves here.
//
// The layers, bottom up: `hash` (the content digest a key is built from),
// `identity` (which compiler is running), `closure` (the key itself),
// `store` (where output goes and what an entry is called), `check` (the
// check cache), `manage` (the verbs that inspect and reclaim all of it).
// This file is where they get re-exported from, so a consumer -- today
// only `cli/src/main.mo` -- sees one mote rather than six modules.

pub use lib::hash {DigestTool, file_digest_with, probe_digest_tool, tree_digest, tree_digest_with}
pub use lib::identity {compiler_digest, compiler_digest_with, compiler_exe_path}
pub use lib::closure {artifact_key, closure_digest_with, input_hash, input_hash_with}
pub use lib::store {Entry, artifact_ir_path, ensure_dir, ensure_entry_dir, entry_root_dir, resolve_target_dir, store_path, target_dir_at, target_dir_for, target_dir_of}
pub use lib::check {CheckPlan, check_block, check_entry_dir, check_entry_leaf, check_entry_read, check_maybe_write, check_plan, check_plan_active, check_plan_all, check_plan_key, check_plan_reason, check_plan_root, check_worth_caching, mote_root_of}
pub use lib::manage {clean_run, gc_run, store_ls, store_verify}
