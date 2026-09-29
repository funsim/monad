// The build mote's library root -- bare `use build` resolves here.
//
// Only the hashing layer so far. The store, the cache and the driver land
// on top of it (plans/packaging/mote-build-deps-artifacts-targets.md
// phases 2a-2c); this file is where they get re-exported from.

pub use lib::hash {DigestTool, probe_digest_tool, tree_digest, tree_digest_with}
