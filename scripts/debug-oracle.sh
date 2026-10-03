#!/usr/bin/env bash
# The `Term.ctx` transparency oracle (tools/debug_transparency_oracle.sh).
#
# Source positions ride the AST as `Term.ctx` wrappers on every path, and
# ~180 sites match on term SHAPE. A wrapper interposed where one of those
# looks does not crash -- it silently stops matching, and a call quietly
# fails to resolve. This asserts the property that makes wrappers safe:
# `--debug` may add `!dbg` annotations and nothing else, so stripping them
# must reproduce the `--release` build byte for byte.
#
# It existed, unwired, while the bug it describes was live. Cheap: two
# compiles per example file, against the SELF-HOSTED BINARY rather than
# the Rust host interpreting cli/src/main.mo -- the binary is what ships,
# and it is ~40x faster per file besides.
#
# This is called by .github/workflows/ci.yml and .tangled/workflows/bootstrap.yml
# directly, inside one `nix develop -c`, rather than through
# `devenv tasks run monad:debug-oracle` (which is the local equivalent):
# devenv-tasks captures a task's stdout and shows it only when the task FAILS,
# which would swallow the oracle's per-file verdicts -- the evidence that says
# which file broke transparency. The task in devenv.nix runs this same script
# in this same dev shell, just quieter on success.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# The scratch directory, private to this checkout. One definition, shared with
# check-monad-tests.sh, bootstrap-compile.sh and tools/debug_transparency_oracle.sh
# -- see scripts/lib/bootstrap-dir.sh, including why TMPDIR is no longer
# consulted for this path.
# shellcheck disable=SC2034  # read by the sourced helper, not here
MONAD_REPO_ROOT="$root"
# shellcheck source=scripts/lib/bootstrap-dir.sh
# shellcheck disable=SC1091  # the hook runs bare `shellcheck`; the line above names the path for -x
. "$root/scripts/lib/bootstrap-dir.sh"
out="$MONAD_BOOTSTRAP_DIR"
# Reuse the binary `bootstrap-compile.sh` just built -- in CI that is the step
# immediately before this one, in the same job. The staleness check and build
# command live in scripts/build-self-hosted.sh, shared with the other two CI
# scripts. Its coverage -- every tree the compiler is built from, which is
# more than the six this comment used to name (that script's header carries
# the live list; it has grown twice, so it is not restated here) -- is wider
# than this script's own check used to be (lang cli llvm runtime, *.mo): a
# stale binary reports failures that are really its own age, and init/std are
# compiled into the binary just as lang/cli are.
scripts/build-self-hosted.sh "$out" --release
MONAD_BIN="$out/monad" "$root"/tools/debug_transparency_oracle.sh "$root"/examples/*.mo
