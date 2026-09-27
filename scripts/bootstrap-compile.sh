#!/usr/bin/env bash
# The self-hosted compiler compiles ITSELF, and then the binary that falls
# out has to do the job it was built for.
#
# The second step is the one with teeth. `compile` succeeding only says
# llc and clang were happy with the emitted IR; it says nothing about
# whether the binary works, and a compiler that builds but miscompiles
# is worse than one that fails to build. Running `check cli/src/main.mo`
# through it costs ~12s and exercises the whole front end -- parser,
# scope, elaboration, typechecker -- on the largest input in the tree.
#
# What this deliberately does NOT check is the fixpoint: that the `.ll`
# this binary produces from the same source is byte-identical to the one
# the host produced (it is, and all three stages agree bit-for-bit), and
# that the same holds one more turn out. That is the stronger property
# and the one that would regress silently, but it costs another full
# self-compile per turn. It got cheap enough (2026-09-19): the self-hosted
# compile is ~40s interpreted against ~320s when this was written, so both
# modes below now cmp their second turn. The `ulimit -s` is load-bearing for
# exactly the turn this adds -- the second turn is the binary interpreting
# ITSELF, which is where the ladder's own rung-2 first hit the default 8MB
# stack (`|| true` keeps a runner whose HARD limit is lower at its own
# ceiling rather than failing the job).
#
# This is called by .github/workflows/ci.yml and .tangled/workflows/bootstrap.yml
# directly, inside one `nix develop -c`, rather than through
# `devenv tasks run monad:bootstrap-compile` (which is the local equivalent):
# devenv-tasks captures a task's stdout and shows it only when the task FAILS,
# which would swallow the --verbose per-module and per-stage trace below -- the
# evidence that says where a wedged or miscompiling run actually stalled. The
# task in devenv.nix runs this same script in this same dev shell, just quieter
# on success.
#
# Commands run bare in a `run:` get the RUNNER HOST's PATH, not the dev shell's,
# so a tool is only a declared dependency when it comes through `nix develop`.
# That is why the whole pipeline lives here rather than in the workflow YAML.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

ulimit -s 131072 || true

out="${TMPDIR:-/tmp}/monad-bootstrap-ci"
# No timeout, by design: the interpreted self-compile measured ~320s
# (2026-09-09) but stretches 2-4x when the runner's other jobs and local
# sessions share this machine. A fixed `timeout` here was killing healthy
# runs; the job-level `timeout-minutes` is the hang guard. Progress is
# visible instead: --verbose streams a per-module and per-stage trace
# (std/src/log.mo), so a genuinely wedged run shows exactly which stage
# stalled.
#
# The interpreter the two builds below run is the job's `MONAD_HOST_BIN`,
# which CI's `bootstrap` job sets to the flake's packaged host
# (`nix build .#monadHost`); unset, scripts/build-self-hosted.sh falls back to
# `cargo run --release --`, whose cold fat-LTO build was ~10 minutes here
# (actions/checkout runs git clean -ffdx at the start of every job, wiping
# target/, .devenv/ and the config, so it was cold every time). What is
# deliberately NOT taken from the flake is the compiler: both rung-1 builds
# below assert the interpreted-vs-compiled comparison, which needs the `.ll`
# the interpreter writes beside its output, and a store compiler has none
# beside it (nix/monad.nix does not install one). The ladder stays a
# from-source build here, in both modes; only its host is packaged. CI's
# `test` job has no such comparison to make, so it does sweep the packaged
# compiler -- see its step.
#
# --release: debug info is on by default; DWARF emission costs ~30s on this
# workload and the binary this job tests does not need it. So the release
# ladder is the fast one and the default-mode ladder is the one that gates
# DWARF emission -- and, because both are asserted, the mode flag is threaded
# through every command below rather than set on one of them.
#
# One ladder, both modes: build rung 1, check the largest input in the tree
# through it, then assert the FIXPOINT -- the binary just built compiles the
# same source itself, and the `.ll` it emits (written beside its own `-o`
# output) must be byte-identical to the host's. Rung 1 == rung 2, asserted
# rather than remembered. A binary that builds and checks but emits different
# IR for its own source is a miscompile the front-end tests cannot see.
#
# The turn itself is scripts/self-compile-turn.sh -- the same command, with
# the same absolute `-o` and the same post-condition, that the flake's
# `checks.bootstrap` runs against the packaged compiler. One definition, so
# the two ladders cannot drift.
#
# The only difference between the two callers is `--release` (see each one's
# note below), and it is threaded through to BOTH commands: `--release` on the
# compile is what decides whether DWARF is emitted, and `--release` on the turn
# is what keeps the emitted IR comparable to it. `rm -rf` forces a
# from-scratch build rather than trusting a stale binary; the staleness check
# and the build command live in scripts/build-self-hosted.sh.
ladder() {
  local dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"
  scripts/build-self-hosted.sh "$dir" --verbose "$@"
  "$dir/monad" check cli/src/main.mo
  scripts/self-compile-turn.sh "$dir/monad" "$dir" monad2 "$@"
  cmp "$dir/monad.ll" "$dir/monad2.ll"
}

# The two ladders are INDEPENDENT -- separate output directories, separate
# builds, nothing shared but the read-only sources -- so they run at once
# rather than one after the other. Measured: 38m53s together in the
# `bootstrap` job (run 36243944155), the second-longest step in the pipeline.
# Each ladder is single-threaded -- one `llc`, one `clang` at a time -- so
# overlapping them uses a second core of the runner's eight rather than
# contending for the first, and the step's wall clock becomes the slower
# ladder instead of their sum.
#
# Memory is the thing this trades away, so it is stated with its measurement
# rather than assumed: each rung-1 build is the Rust host interpreting
# cli/src/main.mo, sampled at 1.34 GB RSS on this workload, so both at once is
# ~2.7 GB plus the dev shell -- not the 29.7 GB shape that OOM'd a machine
# once (that was a compiled binary with no release calls; see
# runtime/src/runtime.c).
#
# Each ladder's `--verbose` trace is prefixed rather than interleaved: the
# trace is the evidence that says where a wedged or miscompiling run stalled,
# and two unprefixed streams on one terminal are no longer evidence of which
# ladder stalled -- which is also why they stream rather than being captured
# to a file and printed only on failure.
#
# `exit "${PIPESTATUS[0]}"` is explicit because `set -e` does NOT reliably
# propagate a failure out of a pipeline's left-hand element: without it a dead
# ladder would exit its own subshell 0 and this script would wait out the
# other one and then report success.
( ladder "$out" --release 2>&1 | sed -u 's/^/[release] /'; exit "${PIPESTATUS[0]}" ) &
release_pid=$!
# And again WITHOUT --release, which is the DEFAULT invocation and was broken
# for an unknown length of time precisely because nothing ran it: `monad
# compile cli/src/main.mo` died at `no instance found for `Append.append``,
# and the only signal was a self-compile nobody waited for (it took 7h48m
# before the located-parse fix).
#
# Both modes share one term tree -- every term carries its source position on
# every path (`parse_all_decls`, lang/module.mo) -- so this run differs from
# the one above only in whether DWARF is EMITTED. That is exactly why it is
# worth running: it is the only gate for the carrier-inference shape probes in
# lang/scope.mo, which no small-file test can reach (see
# examples/located_terms.mo's own header for why, verified rather than
# assumed).
dbg="${TMPDIR:-/tmp}/monad-bootstrap-ci-debug"
( ladder "$dbg" 2>&1 | sed -u 's/^/[debug]   /'; exit "${PIPESTATUS[0]}" ) &
debug_pid=$!

release_rc=0; wait "$release_pid" || release_rc=$?
debug_rc=0;   wait "$debug_pid"   || debug_rc=$?
if [ "$release_rc" -ne 0 ] || [ "$debug_rc" -ne 0 ]; then
  echo "bootstrap-compile.sh: the release ladder exited ${release_rc}, the debug ladder ${debug_rc}" >&2
  exit 1
fi
