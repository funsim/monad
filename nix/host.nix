# The Rust bootstrap host: rung 1 of the ladder, and the only thing that can
# build `cli/src/main.mo` (rung 2 is the result). `nix build .#monadHost`.
#
# It is a package of its own rather than a step inside `monad`'s build, which
# is what makes `nix build .#monadHost` a ~3 minute answer to "does the Rust
# side still build" rather than a ~20 minute one: rung 1 sits DOWNSTREAM of the
# host, not upstream of it, so asking about the host never drags the self-hosted
# build in. It is NOT separately CACHEABLE in practice -- `src = ../.` below
# covers the whole tree, so editing any file in the repository invalidates this
# derivation too (measured: touching flake.nix rebuilt it, "Compiling
# hashbrown"). Narrowing the source to the cargo inputs is a real improvement
# and a separate change.
#
# See nix/monad.nix for what consumes it, and nix/bootstrap.nix for the check
# that asserts the ladder is at a fixpoint.
{ monadVersion }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.monadHost = pkgs.rustPlatform.buildRustPackage {
        pname = "monad-rs";
        version = monadVersion;

        # Path literals are relative to THIS file, so `./.` would be `nix/`;
        # the flake root is one level up. `cargoLock.lockFile` derives every
        # crates.io input's hash from the committed lock file, so there is no
        # `cargoHash` to keep in sync by hand.
        src = ../.;
        cargoLock.lockFile = ../Cargo.lock;

        # `-p monad-cli` rather than the whole workspace, which keeps the
        # `wasm` member -- and therefore a wasm32 toolchain -- out of a build
        # that has no use for it.
        cargoBuildFlags = [
          "-p"
          "monad-cli"
        ];

        # The workspace's own `cargo test` pulls in the wasm member, which
        # needs a target this derivation does not provide; CI runs the Rust
        # suite from the dev shell, which does.
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
