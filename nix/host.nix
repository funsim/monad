# The Rust bootstrap host: rung 1 of the ladder, and the only thing that can
# build `cli/src/main.mo` (rung 2 is the result). `nix build .#monadHost`.
#
# It is a package of its own rather than a step inside `monad`'s build, which
# is what makes `nix build .#monadHost` a ~3 minute answer to "does the Rust
# side still build" rather than a ~20 minute one: rung 1 sits DOWNSTREAM of the
# host, not upstream of it, so asking about the host never drags the self-hosted
# build in. Its `src` is filtered to the cargo inputs (see below), so a commit
# touching only `.mo` sources, docs or workflows is a STORE HIT here. It used to
# be `src = ../.`, which put the whole tree in the derivation's hash -- editing
# any file in the repository invalidated it too (measured at the time by
# touching flake.nix and rebuilding: "Compiling hashbrown"). That mattered
# because `.#monad` takes this package as a native input, so a cold host was
# paid inside rung 1's own build, and because a whole-tree hash is unshareable
# between the two CI runners by construction.
#
# See nix/monad.nix for what consumes it, and nix/bootstrap.nix for the check
# that asserts the ladder is at a fixpoint.
{ monadVersion }:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      packages.monadHost = pkgs.rustPlatform.buildRustPackage {
        pname = "monad-rs";
        version = monadVersion;

        # Path literals are relative to THIS file, so `./.` would be `nix/`;
        # the flake root is one level up. `cargoLock.lockFile` derives every
        # crates.io input's hash from the committed lock file, so there is no
        # `cargoHash` to keep in sync by hand.
        #
        # Only the cargo inputs are in the source, which is what makes this
        # derivation shareable across commits that do not touch them. The
        # filter keeps what the build actually reads, no more:
        #
        #   * EVERY workspace member. Cargo parses the root `members` list
        #     before it does anything else, so omitting `wasm/` -- which
        #     `-p monad-cli` below never builds -- fails the build with
        #     "failed to load manifest for workspace member" rather than
        #     being harmless.
        #   * `.cargo/config.toml`, which is a cargo input even though it
        #     reaches no source file: it sets `RUST_MIN_STACK = 16 MiB` for
        #     the processes cargo runs. Leaving it out would change the
        #     build's environment silently.
        #   * NOT the monad sources. The `include_str!` calls that reach
        #     `init/`, `std/` and `examples/` (core/src/core_check_module.rs
        #     :3921+) are inside `#[cfg(test)] mod test`, and `doCheck =
        #     false` below means no test build ever expands them; with
        #     `embed-stdlib` off (the default -- only the `wasm` member turns
        #     it on) the stdlib is a RUNTIME path, which is why the CI job
        #     exports MONAD_STDLIB.
        src = lib.fileset.toSource {
          root = ../.;
          fileset = lib.fileset.unions [
            ../.cargo
            ../Cargo.lock
            ../Cargo.toml
            ../core
            ../rust-cli
            ../wasm
          ];
        };
        cargoLock.lockFile = ../Cargo.lock;

        # `-p monad-cli` rather than the whole workspace, which keeps the
        # `wasm` member -- and therefore a wasm32 toolchain -- out of a build
        # that has no use for it.
        cargoBuildFlags = [
          "-p"
          "monad-cli"
        ];

        # Cargo writes to `target-rust/` (see ./.cargo/config.toml, which IS in
        # the fileset above), but nixpkgs' cargo-install-hook looks in a literal
        # `target/@targetSubdirectory@/$cargoBuildType` and never reads
        # CARGO_TARGET_DIR -- so without this the build would succeed and the
        # install would find nothing. The env var overrides the config file, and
        # nothing here clobbers it: the build hook's own CARGO_TARGET_DIR
        # assignment is inside its `buildAndTestSubdir` branch, which this
        # package does not set.
        CARGO_TARGET_DIR = "target";

        # The workspace's own `cargo test` pulls in the wasm member, which
        # needs a target this derivation does not provide; CI runs the suite
        # from the dev shell, which does -- the "Rust test suite" step of
        # ci.yml's `pre-commit-checks`, guarded on the compiler classifier.
        doCheck = false;

        # Deliberately no `git`. No input in Cargo.lock is a git dependency, so
        # the only thing it could have served here was the build-commit probe
        # `llvm/src/link.mo` used to run -- and there is no probe any more: a
        # linked binary is stamped with the LINKING compiler's own revision
        # (`build_commit_define`), which for the packaged `monad` means the
        # `MONAD_BUILD_COMMIT` the flake exports in nix/monad.nix. A host built
        # with `git` on PATH does not need it, and a store copy has no `.git`
        # for it to read anyway.
        meta.mainProgram = "monad-rs";
      };
    };
}
