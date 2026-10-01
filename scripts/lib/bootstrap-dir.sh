#!/bin/sh
# ONE definition of where the bootstrap ladder builds its scratch compiler.
#
# Sourced, never executed -- the shebang is there so shellcheck lints this as
# POSIX sh, which it has to be: one of the five callers is a `#!/bin/sh` tool.
# Defines, for the caller:
#
#   MONAD_BOOTSTRAP_DIR   the scratch directory (absolute)
#   MONAD_BOOTSTRAP_BIN   "$MONAD_BOOTSTRAP_DIR/monad", the rung-1 compiler
#
# The caller names the checkout root, because this is sourced by scripts with
# different notions of `$0`:
#
#   MONAD_REPO_ROOT="$root"
#   . "$root/scripts/lib/bootstrap-dir.sh"
#
# (Every caller already computes that root at its top -- `cd -- "$(dirname --
# ...)/.." && pwd`. It is passed in rather than derived here so nothing has to
# guess which file is being sourced from where.)
# ---------------------------------------------------------------------------
# Why this file exists
#
# The path was spelled `${TMPDIR:-/tmp}/monad-bootstrap-ci` at four sites
# (check-monad-tests.sh, bootstrap-compile.sh twice, debug-oracle.sh) plus a
# fifth copy of the binary's path in tools/debug_transparency_oracle.sh. /tmp
# is shared by the whole machine, so every worktree and every concurrent
# session on it built into the SAME directory -- a sibling session's compiler
# silently became this run's baseline, and nothing ever cleaned it. The
# symptom is a gate that grades an artifact this commit did not produce;
# check-monad-tests.sh's own header documented the hazard for months.
#
# The default is now private to the checkout. Two consequences, both
# deliberate:
#
#   * TMPDIR is no longer consulted for this path. A builder that relied on
#     TMPDIR to keep scratch off a small / (or to isolate per job) must set
#     MONAD_BOOTSTRAP_DIR instead -- which still works, and is the only knob
#     for it now.
#
#   * The directory lives under <target-dir>, so `monad clean --all` deletes
#     it along with the rest of target-monad/. That is right for scratch, but
#     it means a `clean` between two steps of the ladder costs a full rebuild
#     of the rung-1 compiler. In CI the cost is zero: the job's
#     `git clean -ffdx` wiped /tmp's copy at job start anyway, so a job was
#     cold either way. What is bought here is privacy, not reuse.
#
# The callers must agree on the path: bootstrap-compile.sh and debug-oracle.sh
# are consecutive CI steps, and the oracle deliberately reuses the binary the
# compile just built -- whose mtime scripts/build-self-hosted.sh's staleness
# scan compares against the sources. One definition, sourced, is what keeps
# them from drifting.
# ---------------------------------------------------------------------------

: "${MONAD_REPO_ROOT:?set MONAD_REPO_ROOT to the checkout root before sourcing bootstrap-dir.sh}"

MONAD_BOOTSTRAP_DIR="${MONAD_BOOTSTRAP_DIR:-$MONAD_REPO_ROOT/target-monad/bootstrap-ci}"

# An override may be relative; make it absolute here rather than leaving it to
# the caller's cwd. `-o` in this toolchain only wins outright when it is
# absolute (see scripts/build-self-hosted.sh), and a relative scratch dir under
# a target dir nests a second copy of itself.
case "$MONAD_BOOTSTRAP_DIR" in
  /*) ;;
  *) MONAD_BOOTSTRAP_DIR="$PWD/$MONAD_BOOTSTRAP_DIR" ;;
esac

# shellcheck disable=SC2034  # set for the caller, not read in this file
MONAD_BOOTSTRAP_BIN="$MONAD_BOOTSTRAP_DIR/monad"
