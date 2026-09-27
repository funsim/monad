#!/usr/bin/env bash
# Decide how many ways the corpus sweep shards, and put the answer in
# MONAD_SWEEP_JOBS.
#
# It is a script, and CI runs it INSIDE the dev shell, because of a red
# pipeline: a bare `run:` step in these jobs uses the RUNNER HOST's PATH, not
# the dev shell's, and that PATH carries only the nix store entries the runner
# itself needs. It has no `awk` and no `lscpu`. Run 36313431973's `test` job
# died 8 s in on
#
#   line 4: lscpu: command not found
#   line 7: awk: command not found
#   Process completed with exit code 127
#
# before it had measured anything at all. `nproc` and `uname` DO exist there
# (the same log printed "nproc (affinity-aware): 8" before dying), so the
# workflow step still prints the host reading for contrast -- but everything
# that needs a real tool runs here, in the dev shell, where the sweep itself
# runs.
#
# DECLARING THE TOOLS IS THE OTHER HALF, and both halves are needed. Moving
# the measurement into a script fixed `awk` -- which the dev shell does supply
# -- and left `lscpu`, which it does not: `lscpu` was resolving to
# /run/current-system/sw/bin/lscpu, the AMBIENT system PATH that `nix develop`
# leaves in place rather than replacing, so every CI run after that printed
#
#   /run/github-runner/.../scripts/ci-cpu-budget.sh: line 55: lscpu: command not found
#
# (run 36322856497). It did not fail the step -- the `|| true` held, and the
# step went `completed/success` -- but a green step that prints "command not
# found" is how a real failure gets skimmed past, and `type -p` inside the dev
# shell on the dev box is precisely what made it look fine: it answers a path
# from the system profile, not from the shell, and the runner has no such
# path. So the tools this script calls are now DECLARED in devenv.nix (gawk,
# coreutils, gnugrep, util-linux) instead of being ambient luck, and the
# `lscpu` call stays `command -v`-guarded so that dropping util-linux again
# costs a diagnostic line rather than the step. The model name and logical
# count come from /proc/cpuinfo, which needs no tool at all; `lscpu` adds its
# own view (the scaling-MHz line is the part /proc/cpuinfo does not give).
#
# The two the DECISION needs -- `nproc` and `awk` -- are checked for rather
# than assumed, because a budget computed from a missing tool is worse than a
# loud failure.
#
# The numbers, and why each is printed rather than asserted:
#
#   * three records disagreed about this runner. This repository's ci.yml
#     asserted the sweep's `min(nproc - 1, 8)` default was "= 7 here";
#     monad-nixos-modules' runner module comments 8 vCPU as "matches the CI
#     host's cores"; and run 36301331844 shipped 3 shards. A measurement in
#     the log is what settles that; a fourth assertion would not.
#   * `nproc` respects this process's CPU affinity and the cgroup CPU quota
#     caps the CPU time it may actually burn, so the smaller of the two is the
#     budget. `cpu.max` is absent on this runner (printed as such), which
#     makes the quota the affinity here -- but the reading is printed either
#     way, so a runner that does constrain it says so instead of silently
#     changing the answer.
#   * a shard is a whole compiler plus its GC heap, so the cap is 8 rather
#     than the whole budget: this corpus has OOM'd a box before, and 8 is the
#     cap the script's own `min(nproc - 1, 8)` default already carried.
#   * the reading that chose 3 shards came from `nproc` INSIDE the dev shell,
#     so this script -- which runs there -- prints its own `nproc`, and the
#     step prints the host's beside it. If the two differ, the difference is
#     the whole explanation, and it is in the log rather than in memory.
#
# It is runnable by hand, which is how the dependencies above were checked:
#
#   DEVENV_SKIP_TASKS=1 nix develop --no-pure-eval --accept-flake-config \
#     -c scripts/ci-cpu-budget.sh
#
# With GITHUB_ENV unset it prints the line instead of exporting it, so a local
# run says what it WOULD have set rather than writing to a file that is not
# there.
set -euo pipefail

# The two the decision needs. Checked, not assumed: `nproc` with no core count
# and `awk` with no parser would silently produce a wrong budget, and a wrong
# budget is a shard count nobody can explain from the log.
for tool in nproc awk; do
  if ! command -v "$tool" > /dev/null; then
    echo "ci-cpu-budget: $tool is required and is not on this PATH" >&2
    exit 2
  fi
done

echo "runner: $(uname -n)"
echo "nproc (this environment's affinity): $(nproc)"
echo "nproc --all: $(nproc --all)"
model="$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo || true)"
logical="$(awk '/^processor/ { n++ } END { print n + 0 }' /proc/cpuinfo || true)"
echo "cpu: ${model:-unknown} x ${logical:-?} logical (from /proc/cpuinfo, which needs no tool)"
# Declared in devenv.nix, so this resolves on the runner as well; the guard is
# what keeps a future removal to a missing line rather than a failed step.
if command -v lscpu > /dev/null; then
  lscpu | grep -E '^CPU\(s\)|^Model name' || true
fi
echo "cpu.max: $(cat /sys/fs/cgroup/cpu.max 2> /dev/null || echo absent)"
echo "memory.max: $(cat /sys/fs/cgroup/memory.max 2> /dev/null || echo absent)"
awk '/^MemTotal/ { print "MemTotal: " $2 " kB" }' /proc/meminfo

affinity="$(nproc)"
quota="$(awk '{ if ($1 != "max" && $2 > 0) { q = int($1 / $2); if (q > 0) print q } }' \
  /sys/fs/cgroup/cpu.max 2> /dev/null || true)"
budget="$affinity"
if [ -n "$quota" ] && [ "$quota" -lt "$budget" ]; then
  budget="$quota"
fi
jobs=$((budget - 1))
if [ "$jobs" -lt 1 ]; then jobs=1; fi
if [ "$jobs" -gt 8 ]; then jobs=8; fi
echo "budget: affinity=$affinity quota=${quota:-unlimited} -> $jobs sweep shard(s)"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "MONAD_SWEEP_JOBS=$jobs" >> "$GITHUB_ENV"
else
  echo "MONAD_SWEEP_JOBS=$jobs (GITHUB_ENV is unset: printed, not exported)"
fi
