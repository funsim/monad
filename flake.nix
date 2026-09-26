{
  description = "Monad language compiler";

  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs =
    {
      self,
      nixpkgs,
      devenv,
      ...
    }@inputs:
    let
      # The platform everything below is built and tested on. A LIST, and
      # every output is written through `mapAttrs` over `systemOutputs`, so
      # adding a second is this one line rather than a rewrite of the
      # attribute spine.
      systems = [ "x86_64-linux" ];

      lib = nixpkgs.lib;

      # What `monad version` reports, and what gets baked into every binary
      # the packaged compiler links (`build_commit_hash`, llvm/src/link.mo).
      # A nix build's source tree is a store copy with no `.git`, so the rev
      # has to come from the flake rather than from `git rev-parse`;
      # `dirtyRev` covers an uncommitted tree, and `unknown` the case where
      # the flake was evaluated from a plain directory.
      commit =
        let
          rev = self.rev or null;
          dirty = self.dirtyRev or null;
        in
        if rev != null then
          builtins.substring 0 7 rev
        else if dirty != null then
          builtins.substring 0 7 dirty
        else
          "unknown";

      # Shared by both derivations that run the ladder, because what it does
      # differs between a dev shell and a nix build and the difference is
      # worth a line of build log rather than silence.
      #
      # `ulimit -s 131072` is what the ladder does for its own deep recursion
      # (scripts/bootstrap-compile.sh), and a nix build is the one place it
      # CANNOT take effect: nix sets the builder's RLIMIT_STACK ceiling to
      # 64 MiB with soft == hard, and raising a hard limit needs a privilege
      # the builder does not have. So the ladder here runs at 64 MiB where
      # CI's runner gets 128 -- and it does run: rung 1 is the host
      # INTERPRETER, the deepest recursion in the ladder, and it completes at
      # 64 MiB (measured, 18 m 32 s). The fallback is kept rather than
      # dropped because it is not a no-op for a relaxed or non-sandboxed
      # builder, where it leaves the build at ITS ceiling instead of failing.
      raiseStack = ''
        if ulimit -s 131072 2>/dev/null; then
          echo "stack limit raised to 131072 KB"
        else
          echo "NOTE: RLIMIT_STACK left at $(ulimit -s) KB -- nix's sandbox ceiling is 64 MiB soft=hard, so the ladder runs here with half of CI's stack"
        fi
      '';

      # The Rust bootstrap host: rung 1 of the ladder, and the only thing
      # that can build `cli/src/main.mo` (rung 2 is the result). Built with
      # `-p monad-cli` rather than for the whole workspace, which keeps the
      # `wasm` member -- and therefore a wasm32 toolchain -- out of a build
      # that has no use for it. `cargoLock.lockFile` derives every crates.io
      # input's hash from the committed lock file, so there is no `cargoHash`
      # to keep in sync by hand.
      mkMonadHost =
        pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "monad-rs";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          cargoBuildFlags = [
            "-p"
            "monad-cli"
          ];
          # The workspace's own `cargo test` pulls in the wasm member, which
          # needs a target this derivation does not provide; CI runs the Rust
          # suite from the dev shell, which does.
          doCheck = false;
          # `build_commit_hash` shells out to `git`; with no `git` on PATH the
          # redirect still runs and leaves an empty file, which trims to ""
          # rather than to the "unknown" the fallback intends.
          nativeBuildInputs = [ pkgs.git ];
          meta.mainProgram = "monad-rs";
        };

      # Rung 1: the host compiles `cli/src/main.mo` into a real `monad`.
      mkMonad =
        pkgs: monadHost:
        let
          # The generated runtime includes `<gc.h>` and links `-lgc`, so both
          # the header and the library have to be reachable from a bare
          # `clang`. They are passed TWO ways on purpose: the `NIX_*`
          # variables are what nixpkgs' wrapped clang reads, and
          # `LIBRARY_PATH`/`CPATH` are what any clang reads. Which of the two
          # carries the flag depends on whether the `clang` found first is the
          # wrapped one, and there is no reason to depend on that.
          gcLib = lib.getLib pkgs.boehmgc;
          gcDev = lib.getDev pkgs.boehmgc;

          # What the packaged compiler needs at RUNTIME, as opposed to at
          # build time: every `monad compile` shells out to `llc` and `clang`
          # by bare name (llvm/src/link.mo), plus `sh`/`rm` for the
          # build-commit probe.
          runtimePath = lib.makeBinPath [
            pkgs.llvm
            pkgs.clang
            pkgs.bash
            pkgs.coreutils
          ];
        in
        pkgs.stdenv.mkDerivation {
          pname = "monad";
          version = "0.1.0";

          src = ./.;

          # `git` is here for `build_commit_hash`, which is still consulted;
          # `MONAD_BUILD_COMMIT` (exported below) is what it answers with.
          nativeBuildInputs = [
            monadHost
            pkgs.llvm
            pkgs.clang
            pkgs.lld
            pkgs.git
            pkgs.makeWrapper
            pkgs.bash
            pkgs.coreutils
          ];
          buildInputs = [ pkgs.boehmgc ];

          # Rung 1's own command, spelled exactly as
          # `scripts/build-self-hosted.sh` spells it. Duplicated rather than
          # invoked: that script also carries a staleness check and a
          # `cargo run`, neither of which a nix build wants -- the host
          # arrives as a built input instead.
          #
          # `ulimit -s` is load-bearing for the ladder's own deep recursion
          # (see scripts/bootstrap-compile.sh); `|| true` keeps a builder
          # whose HARD limit is already lower at its own ceiling rather than
          # failing the build outright.
          # The `-o` is ABSOLUTE, and that is load-bearing: the compiler joins
          # a RELATIVE output name with its own default output directory
          # (`/tmp/monad_out_<pid>`, cli/src/main.mo), so `-o monad1` builds
          # successfully and leaves the binary -- and its `.ll`, which is
          # written beside the target -- somewhere the install phase cannot
          # see. `$PWD` is the unpacked source root, which is what
          # `scripts/build-self-hosted.sh` passes as its `$out` too.
          buildPhase = ''
            runHook preBuild
            ${raiseStack}
            export MONAD_BUILD_COMMIT=${commit}
            monad-rs run cli/src/main.mo compile cli/src/main.mo -o "$PWD/monad1" --release
            runHook postBuild
          '';

          # Only the binary is installed. `monad1.ll` -- the IR of
          # cli/src/main.mo as the HOST INTERPRETER emitted it, 5.4 MB beside
          # a 2.6 MB binary (measured) -- stays in the build directory. It has
          # exactly one consumer, the interpreted-vs-compiled `cmp`, and that
          # comparison is made where BOTH of its turns are built: CI's
          # `scripts/bootstrap-compile.sh`, on every push and in both build
          # modes. A store copy would grow every consumer's closure by 5.4 MB
          # of IR to restate a property the packaged compiler already asserts
          # against itself (see `checks.bootstrap`).
          installPhase = ''
            runHook preInstall
            install -Dm755 "$PWD/monad1" $out/share/monad/monad
            makeWrapper $out/share/monad/monad $out/bin/monad \
              --prefix PATH : ${runtimePath} \
              --set NIX_LDFLAGS "-L${gcLib}/lib" \
              --set NIX_CFLAGS_COMPILE "-isystem ${gcDev}/include" \
              --set LIBRARY_PATH "${gcLib}/lib" \
              --set CPATH "${gcDev}/include" \
              --set MONAD_BUILD_COMMIT ${commit}
            runHook postInstall
          '';

          meta = {
            description = "The self-hosted Monad compiler";
            homepage = "https://monad-lang.org";
            license = lib.licenses.asl20;
            mainProgram = "monad";
          };
        };

      systemOutputs = lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          monadHost = mkMonadHost pkgs;
          monad = mkMonad pkgs monadHost;

          # The fixpoint, asserted rather than remembered. A compiler that
          # builds and checks but emits different IR for its own source once
          # it is itself compiled is a miscompile the front-end tests cannot
          # see, and it is exactly the property that would regress silently.
          #
          #   monad2.ll -- what the PACKAGED compiler emits for
          #                cli/src/main.mo
          #   monad3.ll -- what the binary built FROM that IR emits, for the
          #                same source
          #
          # so the `cmp` says the compiler the flake ships is at a fixpoint:
          # one more turn of self-compilation changes nothing.
          #
          # The ladder's FIRST comparison -- rung 1, the IR the host
          # INTERPRETER emits for this same source (`monad-rs run`, the
          # buildPhase above; the host never compiles it), against rung 2 --
          # needs a file this derivation is not given and deliberately does
          # not ship. `scripts/bootstrap-compile.sh` builds both turns in one
          # directory and asserts it on every push, in both build modes;
          # saying so here rather than approximating it is the point, and the
          # `mkMonad` installPhase comment says why the IR is not installed.
          bootstrap = pkgs.stdenv.mkDerivation {
            pname = "monad-bootstrap-check";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [
              monad
              pkgs.llvm
              pkgs.clang
              pkgs.lld
              pkgs.bash
              pkgs.coreutils
            ];
            buildInputs = [ pkgs.boehmgc ];
            dontConfigure = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild
              ${raiseStack}

              # The packaged compiler is identifiable, which is the whole
              # reason `MONAD_BUILD_COMMIT` exists: a store copy has no
              # `.git`, so without the override `build_commit_hash`'s probe
              # answers with the literal "unknown" and an artifact that
              # cannot say what it was built from ships. Only asserted when
              # the flake HAS a revision -- evaluated from a plain directory
              # it legitimately has none, and "unknown" is then the honest
              # answer rather than a defect.
              version="$(monad version)"
              echo "monad version: $version"
              if [ "${commit}" != "unknown" ]; then
                case "$version" in
                  *"${commit}"*) ;;
                  *) echo "FAIL: version '$version' does not carry ${commit}"; exit 1 ;;
                esac
              fi

              # `check` exercises the whole front end -- parser, scope,
              # elaboration, typechecker -- on the largest input in the tree,
              # for ~12s. It is the cheap gate the fixpoint does not subsume.
              monad check cli/src/main.mo

              # rung 2, then rung 3, then the fixpoint between them.
              # Absolute `-o` throughout, for the reason spelled out in the
              # monad derivation's buildPhase: a relative one lands in
              # `/tmp/monad_out_<pid>` and takes its `.ll` with it.
              #
              # Exported for `./monad2` and `./monad3`, which are the raw
              # binaries rather than the wrapper: without it each one probes
              # for a `.git` that is not there. Nothing in the emitted IR
              # depends on this -- it is a define for the C runtime -- so it
              # cannot disturb the `cmp` below.
              export MONAD_BUILD_COMMIT=${commit}

              monad compile cli/src/main.mo -o "$PWD/monad2" --release
              test -x "$PWD/monad2"

              ./monad2 compile cli/src/main.mo -o "$PWD/monad3" --release
              test -x "$PWD/monad3"
              cmp "$PWD/monad2.ll" "$PWD/monad3.ll"

              runHook postBuild
            '';

            installPhase = "touch $out";
          };
        in
        {
          inherit monadHost monad bootstrap;
        }
      );

      appFor =
        system:
        let
          program = "${systemOutputs.${system}.monad}/bin/monad";
        in
        {
          type = "app";
          inherit program;
        };
    in
    {
      devShells = lib.mapAttrs (system: _: {
        default = devenv.lib.mkShell {
          inherit inputs;
          pkgs = nixpkgs.legacyPackages.${system};
          modules = [
            {
              packages = [ inputs.devenv.packages.${system}.devenv ];
            }
            ./devenv.nix
          ];
        };
      }) systemOutputs;

      packages = lib.mapAttrs (system: o: {
        inherit (o) monadHost monad;
        default = o.monad;
      }) systemOutputs;

      apps = lib.mapAttrs (system: _: {
        monad = appFor system;
        default = appFor system;
      }) systemOutputs;

      checks = lib.mapAttrs (system: o: {
        inherit (o) bootstrap;
      }) systemOutputs;
    };
}
