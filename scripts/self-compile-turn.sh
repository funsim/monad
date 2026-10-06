#!/usr/bin/env bash
# usage: self-compile-turn.sh <compiler> <out-dir> <name> [compiler flags...]
# ONE turn of the bootstrap ladder: <compiler> compiles cli/src/main.mo into
# <out-dir>/<name>, and the IR it emits lands beside it as
# <out-dir>/<name>.ll -- which is what the ladder's `cmp`s compare.
#
# That contract holds on a build-cache HIT as well as a miss: a hit copies
# the cached IR out of the store beside the binary (`replay_ir_beside`,
# cli/src/main.mo). It has to. `build` is cached, so without that a second
# local ladder run took a hit on a rung, wrote no `.ll`, and the caller's
# `cmp` failed on a missing file -- while the rung itself stopped compiling
# anything, which is the quieter half of the same bug.
#
# Two callers perform this same turn: scripts/bootstrap-compile.sh (once per
# build mode, on a binary it just built) and the flake's `checks.bootstrap`
# (on the packaged compiler, and then on the binary that falls out of it).
# The turn is small, but two of its details are load-bearing and were
# re-derived by hand at each call site before:
#
#   * `-o` is ABSOLUTE. The compiler joins a RELATIVE output name with its
#     own default output directory (`/tmp/monad_out_<pid>`, cli/src/main.mo),
#     so a relative `-o` builds successfully and leaves the binary -- and the
#     `.ll` written beside it -- somewhere the caller cannot see.
#   * the result is asserted executable here, so a turn that compiled but did
#     not link fails with the turn's own name rather than at a `cmp` of two
#     files that exist for the wrong reason.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Same raise as scripts/build-self-hosted.sh, and for its reason: a turn is a
# compiler compiling itself, so the stack it needs is not the default. One
# definition, shared -- see scripts/lib/raise-stack.sh.
# shellcheck source=scripts/lib/raise-stack.sh
# shellcheck disable=SC1091  # the hook runs bare `shellcheck`; the line above names the path for -x
. "$root/scripts/lib/raise-stack.sh"

compiler="$1"; out="$2"; name="$3"; shift 3

mkdir -p "$out"
"$compiler" build cli/src/main.mo -o "$out/$name" "$@"
test -x "$out/$name"
