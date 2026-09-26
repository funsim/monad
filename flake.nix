{
  description = "Monad language compiler";

  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
    # The module system the three `nix/` files below are written against, and
    # what this file is reduced to assembling. Already locked transitively
    # (devenv uses it), and its nixpkgs input is pinned to this flake's so no
    # second nixpkgs enters the lock.
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  # A thin assembler over three independent modules. Each `nix/*.nix` file owns
  # one rung of the ladder and reads the rung below it as a PACKAGE
  # (`config.packages.monadHost`) rather than as a function applied to it, so
  # the modules can be read, built and cached one at a time:
  #
  #   nix/host.nix     packages.monadHost  the Rust interpreter (rung 0)
  #   nix/monad.nix    packages.monad      rung 1, built by scripts/
  #   nix/bootstrap.nix checks.bootstrap   the fixpoint rung 1 asserts
  #
  # The facts the three of them share are passed as explicit import arguments
  # rather than through `_module.args`: they are not module-system state, they
  # are what this flake knows about itself, and `import`-arguments cannot be
  # silently shadowed by a module that happens to declare the same option.
  outputs =
    inputs:
    let
      # What `monad version` reports, and what gets baked into every binary the
      # packaged compiler links (`build_commit_define`, llvm/src/link.mo). A nix
      # build's source tree is a store copy with no `.git`, so the revision has
      # to reach it from the flake rather than from the tree it is building --
      # which is why the derivation exports this as `MONAD_BUILD_COMMIT`.
      #
      # The DIRTY revision is preferred when there is one: `shortRev` on a tree
      # with uncommitted changes is still the last commit, which would label a
      # binary built from modified sources with a revision it does not
      # correspond to. `self.dirtyShortRev` is `"<shortRev>-dirty"`, so the
      # version carries the distinction instead of dropping it.
      commit =
        let
          dirty = inputs.self.dirtyShortRev or null;
          rev = inputs.self.shortRev or null;
        in
        if dirty != null then
          dirty
        else if rev != null then
          rev
        else
          "unknown";

      # One place for the version string, so the three derivations below cannot
      # disagree about it.
      monadVersion = "0.1.0";
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [
        (import ./nix/host.nix { inherit monadVersion; })
        (import ./nix/monad.nix { inherit commit monadVersion; })
        (import ./nix/bootstrap.nix { inherit commit monadVersion; })
      ];

      perSystem =
        { pkgs, ... }:
        {
          devShells.default = inputs.devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              {
                packages = [ inputs.devenv.packages.${pkgs.system}.devenv ];
              }
              ./devenv.nix
            ];
          };
        };
    };
}
