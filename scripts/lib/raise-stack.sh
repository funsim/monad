#!/usr/bin/env bash
# ONE definition of the stack raise the bootstrap ladder needs before it runs.
#
# Sourced, never executed -- the shebang is there so shellcheck lints this file
# rather than each caller. Bash, not POSIX sh: `ulimit -s` IS the raise and
# POSIX has no spelling for it, and all three callers are bash. Defines, for
# the caller:
#
#   MONAD_STACK_KB   the RLIMIT_STACK actually obtained, in KB
#
# The caller passes nothing, because nothing here depends on the checkout:
# sourcing needs only a `. <path>`, and the raise covers the shell and every
# child it later spawns.
# ---------------------------------------------------------------------------
# Why this file exists
#
# scripts/build-self-hosted.sh, scripts/self-compile-turn.sh and
# scripts/bootstrap-compile.sh all raise the stack, for the same reason and to
# the same value, and the three copies had drifted in both value and wording.
# The ladder's deepest recursion is the host INTERPRETING cli/src/main.mo --
# and, for bootstrap-compile.sh's second turn, rung 2 interpreting itself --
# so every caller needs the raise; it completes at 64 MB, and the 8 MB default
# is not enough.
#
# It DESCENDS rather than asking for one value, because the ceiling is the
# builder's to set: a builder with a lower one should get the highest rung it
# allows rather than silently keeping whatever it started with. macOS is the
# case that makes the obtained number worth printing -- its main thread's stack
# is fixed at exec, so no later setrlimit grows it, and the raise quietly not
# working there is indistinguishable from the raise never being asked for. An
# unraised stack surfaces as a bare SIGSEGV deep into the build, which reads as
# the script's bug rather than the builder's ceiling.
#
# Not a hard failure anywhere: a builder whose HARD limit is below every rung
# keeps its own ceiling, loudly.
# ---------------------------------------------------------------------------

for rung in 131072 65536 32768 16384 8192; do
  ulimit -s "$rung" 2>/dev/null || continue
  break
done

# Read back rather than trusting the loop: `ulimit -s` is the only thing that
# knows what the builder actually granted, and it is also the value a caller
# would want to assert on.
# shellcheck disable=SC2034  # set for the caller, not read in this file
MONAD_STACK_KB="$(ulimit -s)"

if [ "$MONAD_STACK_KB" -lt 65536 ]; then
  echo "NOTE: RLIMIT_STACK is $MONAD_STACK_KB KB, below the 64 MB the ladder needs -- the"
  echo "      builder's ceiling, not this script's. On macOS no setrlimit raises the main"
  echo "      thread's stack after exec; see plans/packaging/mote-build-deps-artifacts-targets.md."
fi
