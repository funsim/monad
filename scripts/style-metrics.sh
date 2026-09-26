#!/usr/bin/env bash
# Style/design metrics over the `.mo` corpus -- the burndown instrument for
# plans/implementations/code-style-and-lint-enforcement.md.
#
# READ-ONLY: this script never writes a `.mo` file. It emits `key<TAB>value`
# lines on stdout and a human summary on stderr, so it is safe to run anywhere.
#
# It is NOT wired into CI yet -- no workflow or hook calls it, so `--baseline`
# only gates a run you invoke yourself. Wiring the ratchet is Phase 1 of
# plans/implementations/code-style-and-lint-enforcement.md.
#
#   scripts/style-metrics.sh                          # the counters + summary
#   scripts/style-metrics.sh --detail                 # + per-dir/file breakdowns
#   scripts/style-metrics.sh --write-baseline scripts/style-baseline.txt
#   scripts/style-metrics.sh --baseline scripts/style-baseline.txt   # exit 1 if a
#                                                     # ratcheted counter rose
#
# Run it from the worktree root (it resolves the root itself, so any cwd works).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$root/scripts/style_metrics.py" --root "$root" "$@"
