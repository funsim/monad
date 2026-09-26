# The fixpoint, asserted rather than remembered. A compiler that builds and
# checks but emits different IR for its own source once it is itself compiled
# is a miscompile the front-end tests cannot see, and it is exactly the
# property that would regress silently.
#
#   monad2.ll -- what the PACKAGED compiler emits for cli/src/main.mo
#   monad3.ll -- what the binary built FROM that IR emits, for the same source
#
# so the `cmp` says the compiler the flake ships is at a fixpoint: one more turn
# of self-compilation changes nothing. Both turns are
# `scripts/self-compile-turn.sh` -- the same step, with the same absolute `-o`,
# that CI's bootstrap-compile.sh performs on a binary it has just built.
#
# The ladder's FIRST comparison -- rung 1, the IR the host INTERPRETER emits for
# this same source (`monad-rs run`, the buildPhase in nix/monad.nix; the host
# never compiles it), against rung 2 -- needs a file this derivation is not
# given and deliberately does not ship: nix/monad.nix's installPhase says why
# the `.ll` is not installed. `scripts/bootstrap-compile.sh` builds both of its
# turns in one directory and asserts that comparison on every push, in both
# build modes. Saying so here rather than approximating it is the point.
#
# Cost, and why it is not a CI job: rung 1 here is `packages.monad`, so this
# check only pays that ~20 minute build when it is not already in the store --
# but the check itself is a `check` plus two self-compiles. The 20 minutes are
# what CI's `test` job already pays for rung 1, so gating a pipeline on this
# would work against the PR this check arrived with.
{ commit, monadVersion }:
{
  perSystem =
    { pkgs, config, ... }:
    let
      monad = config.packages.monad;
    in
    {
      checks.bootstrap = pkgs.stdenv.mkDerivation {
        pname = "monad-bootstrap-check";
        version = monadVersion;
        src = ../.;

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

        # Same reason as nix/monad.nix's: the ladder script is entered by its
        # shebang, and a nix build's source tree has not had its shebangs
        # patched yet (nixpkgs does that at fixup, on the output). `dontFixup`
        # above makes this the only place it can happen.
        postPatch = "patchShebangs scripts";

        buildPhase = ''
          runHook preBuild

          # The packaged compiler is identifiable, which is the whole reason
          # `MONAD_BUILD_COMMIT` exists: a store copy has no `.git`, so without
          # the override `build_commit_hash`'s probe answers with the literal
          # "unknown" and an artifact that cannot say what it was built from
          # ships. Only asserted when the flake HAS a revision -- evaluated from
          # a plain directory it legitimately has none, and "unknown" is then
          # the honest answer rather than a defect.
          version="$(monad version)"
          echo "monad version: $version"
          if [ "${commit}" != "unknown" ]; then
            case "$version" in
              *"${commit}"*) ;;
              *) echo "FAIL: version '$version' does not carry ${commit}"; exit 1 ;;
            esac
          fi

          # `check` exercises the whole front end -- parser, scope, elaboration,
          # typechecker -- on the largest input in the tree, for ~12s. It is the
          # cheap gate the fixpoint does not subsume.
          monad check cli/src/main.mo

          # Turn 1 takes the PACKAGED compiler as rung 1 -- that is what makes
          # this check affordable, since rung 1 exists as a package and nothing
          # here has to build it. Turn 2 takes the binary that turn 1 produced.
          #
          # Exported for `monad2` and `monad3`, which are the raw binaries rather
          # than the wrapper: without it each one probes for a `.git` that is not
          # there. Nothing in the emitted IR depends on this -- it is a define
          # for the C runtime -- so it cannot disturb the `cmp` below.
          export MONAD_BUILD_COMMIT=${commit}

          scripts/self-compile-turn.sh monad "$PWD" monad2 --release
          scripts/self-compile-turn.sh "$PWD/monad2" "$PWD" monad3 --release
          cmp "$PWD/monad2.ll" "$PWD/monad3.ll"

          runHook postBuild
        '';

        installPhase = "touch $out";

        meta = {
          description = "The packaged Monad compiler is at a self-compilation fixpoint";
          homepage = "https://monad-lang.org";
          license = pkgs.lib.licenses.asl20;
        };
      };
    };
}
