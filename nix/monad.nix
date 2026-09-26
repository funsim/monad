# Rung 1: the host compiles `cli/src/main.mo` into a real `monad`, wrapped so
# that everything it shells out to at RUNTIME is reachable from a store path.
#
# `packages.default` and `apps.monad` both point here, so this is what
# `nix build .#monad` and `nix run .#monad` produce. It is a build-and-check
# artifact rather than a distributable one: the compiler resolves
# `runtime/src/runtime.c` against its WORKING DIRECTORY (the same constraint
# the nightly artifact has), so a packaged `monad compile` has to run from a
# checkout, exactly as CI runs it.
#
# The step that builds it is `scripts/build-self-hosted.sh`, not a shell
# command spelled out here: CI builds rung 1 through that same script in
# check-monad-tests.sh, bootstrap-compile.sh and debug-oracle.sh, and the two
# drifted apart once already (the absolute `-o`, commit b8af914). The host
# arrives as a built input rather than as the script's default `cargo run`,
# which is what MONAD_HOST_BIN is for. The stack raise, and the note that says
# what the limit actually came out as, are the script's too -- a nix sandbox
# cannot raise RLIMIT_STACK (soft == hard), so rung 1 runs here with less
# stack than CI gives it, and it completes anyway.
{ commit, monadVersion }:
{
  perSystem =
    { pkgs, config, lib, ... }:
    let
      monadHost = config.packages.monadHost;

      # The generated runtime includes `<gc.h>` and links `-lgc`, so both the
      # header and the library have to be reachable from a bare `clang`. They
      # are passed TWO ways on purpose: the `NIX_*` variables are what nixpkgs'
      # wrapped clang reads, and `LIBRARY_PATH`/`CPATH` are what any clang
      # reads. Which of the two carries the flag depends on whether the `clang`
      # found first is the wrapped one, and there is no reason to depend on
      # that.
      gcLib = lib.getLib pkgs.boehmgc;
      gcDev = lib.getDev pkgs.boehmgc;

      # What the packaged compiler needs at RUNTIME, as opposed to at build
      # time: every `monad compile` shells out to `llc` and `clang` by bare
      # name (llvm/src/link.mo), plus `sh`/`rm` for the build-commit probe.
      runtimePath = lib.makeBinPath [
        pkgs.llvm
        pkgs.clang
        pkgs.bash
        pkgs.coreutils
      ];

      monad = pkgs.stdenv.mkDerivation {
        pname = "monad";
        version = monadVersion;

        src = ../.;

        # No `git` here either (see nix/host.nix): MONAD_BUILD_COMMIT below is
        # what `build_commit_hash` answers with, so its `git rev-parse` probe
        # is never reached -- which is the point, because the source tree a nix
        # build gets is a store copy with no `.git` and the probe would answer
        # with the literal "unknown".
        nativeBuildInputs = [
          monadHost
          pkgs.llvm
          pkgs.clang
          pkgs.lld
          pkgs.makeWrapper
          pkgs.bash
          pkgs.coreutils
        ];
        buildInputs = [ pkgs.boehmgc ];

        # The script below is entered by its shebang, exactly as CI enters it,
        # and a nix build has no `/usr/bin/env` to resolve that shebang with.
        # nixpkgs patches shebangs from `fixupOutputHooks` -- on the OUTPUT, at
        # the end -- so the unpacked source arrives at buildPhase still saying
        # `#!/usr/bin/env bash` and the build dies with "bad interpreter". This
        # one line patches the tree instead; `pkgs.bash` above is the
        # interpreter it rewrites to.
        postPatch = "patchShebangs scripts";

        buildPhase = ''
          runHook preBuild

          # The revision reaches the compiler AND every binary it links, since
          # the define goes into the emitted C runtime. `$PWD` is the unpacked
          # source root, which is what the script is given as its output
          # directory -- the script writes `$PWD/monad` beside the `.ll` it
          # emits for the same reason this is spelled absolutely.
          export MONAD_BUILD_COMMIT=${commit}
          MONAD_HOST_BIN=${lib.getExe monadHost} scripts/build-self-hosted.sh "$PWD" --release

          runHook postBuild
        '';

        # Only the binary is installed. `monad.ll` -- the IR of cli/src/main.mo
        # as the HOST INTERPRETER emitted it, 5.4 MB beside a 2.6 MB binary
        # (measured) -- stays in the build directory. It has exactly one
        # consumer, the interpreted-vs-compiled `cmp`, and that comparison is
        # made where BOTH of its turns are built: CI's
        # `scripts/bootstrap-compile.sh`, on every push and in both build
        # modes. A store copy would grow every consumer's closure by 5.4 MB of
        # IR to restate a property the packaged compiler already asserts
        # against itself (see nix/bootstrap.nix).
        installPhase = ''
          runHook preInstall
          install -Dm755 "$PWD/monad" $out/share/monad/monad
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

      # `nix run .#monad`; the same program under two names, because
      # `apps.default` is what a bare `nix run` resolves and the named one is
      # what the flake's own documentation and CI use.
      app = {
        type = "app";
        program = "${monad}/bin/monad";
      };
    in
    {
      packages.monad = monad;
      packages.default = monad;

      apps.monad = app;
      apps.default = app;
    };
}
