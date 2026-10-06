#!/usr/bin/env bash
# ONE definition of the platform label a nightly's assets are named after.
#
# Sourced, never executed -- the shebang is there so shellcheck lints this file
# rather than each caller. Defines, for the caller:
#
#   MONAD_PLATFORM   `<arch>-<os>`: x86_64-linux, aarch64-linux, riscv64-linux,
#                    aarch64-darwin
#
# The label is not the same thing as the machine's: it names what the artifact
# was BUILT FOR, and the two differ exactly on a cross leg -- which is why the
# environment can set it outright (`MONAD_PLATFORM=aarch64-linux`). An artifact
# named after its builder would be uninstallable by the platform it is for, and
# the name is the only thing a consumer has to go on.
#
# An unrecognised machine is a hard error rather than a guess: a label no
# release publishes is a broken asset, and borrowing another platform's name
# would publish a binary for the wrong CPU under a plausible one. `monadup`
# keeps its own copy of this table (scripts/monadup) because it is published
# standalone, into a user's ~/.monad/bin, with no checkout to source from --
# and it FALLS BACK to x86_64-linux there instead of erroring, because an
# install has to work on a machine nobody built a nightly for.
# ---------------------------------------------------------------------------

if [ -z "${MONAD_PLATFORM:-}" ]; then
  case "$(uname -sm)" in
    "Darwin arm64" | "Darwin aarch64") MONAD_PLATFORM="aarch64-darwin" ;;
    "Linux aarch64" | "Linux arm64") MONAD_PLATFORM="aarch64-linux" ;;
    "Linux riscv64") MONAD_PLATFORM="riscv64-linux" ;;
    "Linux x86_64" | "Linux amd64") MONAD_PLATFORM="x86_64-linux" ;;
    *)
      echo "no nightly platform label for '$(uname -sm)': set MONAD_PLATFORM to one of" >&2
      echo "  x86_64-linux  aarch64-linux  riscv64-linux  aarch64-darwin" >&2
      exit 1
      ;;
  esac
fi

# Read here only so shellcheck sees a use: the value is for the caller.
: "$MONAD_PLATFORM"
