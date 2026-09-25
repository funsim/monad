#!/usr/bin/env bash
# usage: build-self-hosted.sh <out-dir> [compiler flags...]
# Builds <out-dir>/monad from cli/src/main.mo with the Rust host interpreter
# (rung 1). Skips the build when the binary is newer than every input.
#
# The staleness check covers everything that ends up INSIDE the binary:
# init and std are compiled into it just as lang/cli/llvm/runtime are, and
# runtime.c/.h are linked into it. Omitting any of them meant an edit to
# the omitted source left a stale binary in place, so CI tested the
# previous compiler and reported its results as this commit's.
#
# The three callers -- check-monad-tests.sh, bootstrap-compile.sh, and
# debug-oracle.sh -- each had their own copy of this check with a narrower
# or wider input set. This is the single definition, at the widest coverage
# (the sweep's): all four motes plus the C runtime.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

out="$1"; shift
mkdir -p "$out"
if [ ! -x "$out/monad" ] || [ -n "$(find init std lang cli llvm runtime \
      \( -name '*.mo' -o -name '*.c' -o -name '*.h' \) \
      -newer "$out/monad" -print -quit)" ]; then
  cargo run --release -- run cli/src/main.mo compile cli/src/main.mo -o "$out/monad" "$@"
fi
test -x "$out/monad"
