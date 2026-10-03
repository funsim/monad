#!/usr/bin/env bash
# usage: build-self-hosted.sh <out-dir> [compiler flags...]
# Builds <out-dir>/monad from cli/src/main.mo with the Rust host interpreter
# (rung 1). Skips the build when the binary is newer than every input.
#
# The host is `cargo run --release --`, or whatever MONAD_HOST_BIN names --
# for a builder that has a built host rather than a cargo tree:
#   MONAD_HOST_BIN=/nix/store/.../bin/monad-rs scripts/build-self-hosted.sh ...
# A packaged host needs its stdlib pointed at this checkout as well -- its
# compiled-in default is a path that exists only in the build that made it; see
# the MONAD_STDLIB note at the definition below.
# Deliberately NOT spelled MONAD_BIN: that name already means "the
# self-hosted compiler to run" here (tools/debug_transparency_oracle.sh,
# check-docs.sh), and an exported value quietly swapping rung 1 is the same
# class of substitution this script's staleness check exists to stop.
#
# The stack is raised for the build below rather than left to each caller:
# it is the ladder's deepest recursion (the host INTERPRETING
# cli/src/main.mo), so every caller needs it, and the one that cannot have it
# -- a nix sandbox, where soft == hard -- says which limit it got instead of
# finding out as a crash. 131072 is what CI uses; the ladder completes at
# 64 MB; the 8 MB default is not enough.
#
# The staleness check covers everything that ends up INSIDE the binary:
# init and std are compiled into it just as lang/cli/llvm/runtime are, and
# runtime.c/.h are linked into it. Omitting any of them meant an edit to
# the omitted source left a stale binary in place, so CI tested the
# previous compiler and reported its results as this commit's.
#
# The three callers -- check-monad-tests.sh, bootstrap-compile.sh, and
# debug-oracle.sh -- each had their own copy of this check with a narrower
# or wider input set. This is the single definition, at the widest coverage:
# every tree the compiler is built FROM (init, std, lang, cli, llvm, runtime,
# build, and the motes cli imports -- motes/lsp and motes/toolkit, which reach
# the binary through cli/mote.toml's [dependencies.lsp]), their .mo/.c/.h
# sources, and each one's mote.toml -- a manifest that carries `[link] libs`,
# so it decides how the mote is compiled.
#
# This list must match nix/monad.nix's `compilerSrc` fileset, which cites this
# scan as authoritative. A mote missing HERE is the quiet half of the failure:
# the build silently reuses a binary that predates the edit, where a mote
# missing THERE at least fails the nix build loudly.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# The ceiling the header describes, raised here so it covers the build below
# and every child it spawns. `||` rather than a hard failure: a builder whose
# HARD limit is already lower keeps its own ceiling, loudly.
ulimit -s 131072 2>/dev/null ||
  echo "NOTE: RLIMIT_STACK left at $(ulimit -s) KB -- the ceiling is the builder's own, not this script's"

MONAD_HOST_BIN=${MONAD_HOST_BIN:-"cargo run --release --"}

# ... and that host finds its stdlib at a path compiled INTO it: `init/src`
# next to cargo's CARGO_MANIFEST_DIR (core/src/term/module.rs's `stdlib_dir()`,
# which honours MONAD_STDLIB). A `cargo run` host baked this checkout and
# resolves correctly; a host built by nix baked `/build/<src>-source/init/src`,
# which is true only for the duration of that build. Every flake-side build
# worked anyway -- their working directory IS that path -- and CI's bootstrap
# job, the first place a packaged host ran in a checkout, died on
# `failed to read .../init/src/prelude.mo` (run 36236800752).
# Pointing the host at THIS checkout is also what the rung is supposed to mean:
# the interpreter must read the same tree the self-compile below compiles.
# An explicit MONAD_STDLIB still wins.
MONAD_STDLIB=${MONAD_STDLIB:-"$root/init/src"}
export MONAD_STDLIB

out="$1"; shift
mkdir -p "$out"
# ABSOLUTE, because `-o` is a NAME and only an absolute value wins outright:
# a relative out dir nests the binary under the target dir, so `-o
# target-monad/selfhosted/monad` lands at `target-monad/debug/target-monad/
# selfhosted/monad` -- and then this script's own closing `test -x "$out/monad"` fails
# with no message at all, which reads as a build that did nothing. Measured
# 2026-09-30 on exactly that invocation. Every CI caller already passes an
# absolute path ($TMPDIR-rooted, or `$root/dist`), so this only makes the
# manual invocation mean the same thing they do.
out="$(cd -- "$out" && pwd)"

# A missing binary short-circuits, so the scan runs only when there is
# something to compare against. `find` exiting non-zero must NOT read as
# "nothing is newer": a moved or unreadable input directory would then
# leave the stale binary this check exists to catch in place, silently --
# which is the bug the coverage above was widened for. So the scan is its
# own step and its failure is loud.
if [ ! -x "$out/monad" ]; then
  needs_build=1
else
  newer="$(find init std lang cli llvm runtime build motes/lsp motes/toolkit \
    \( -name '*.mo' -o -name '*.c' -o -name '*.h' -o -name mote.toml \) \
    -newer "$out/monad" -print -quit)" || {
    echo "build-self-hosted.sh: cannot scan the ladder's inputs from $PWD" >&2
    exit 1
  }
  needs_build=
  if [ -n "$newer" ]; then needs_build=1; fi
fi

if [ -n "$needs_build" ]; then
  # The revision the rung-1 binary will report (`monad version`) and stamp
  # into everything it links. It comes from THIS repository -- `git -C
  # "$root"`, the tree the self-compile below reads -- and only when nothing
  # more specific is already set, so the flake's own `MONAD_BUILD_COMMIT`
  # (nix/monad.nix) and nightly-release.sh's keep winning. That is the whole
  # contract `link_ir` reads: the environment names the revision when a
  # builder can name it, and the compiler's own baked-in one answers
  # otherwise.
  #
  # Without this, every locally built rung-1 says "unknown": the Rust host
  # doing the linking has no revision of its own (`core/src/core_native.rs`'s
  # `build_commit`, `option_env!` at monad-rs's own build time), and the
  # compiler used to recover the number with a `git rev-parse` in the WORKING
  # DIRECTORY -- the wrong repository, which is why that probe is gone.
  #
  # `|| true` and the empty check are for a builder with no `.git` at all (a
  # store copy, an unpacked tarball): it is not an error to be unable to name
  # a revision, and an empty string is not a name -- `build_commit_define`
  # reads it as "no answer" and says `unknown`, which is the truth there.
  if [ -z "${MONAD_BUILD_COMMIT:-}" ]; then
    MONAD_BUILD_COMMIT="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
    export MONAD_BUILD_COMMIT
  fi
  $MONAD_HOST_BIN run cli/src/main.mo build cli/src/main.mo -o "$out/monad" "$@"
fi
test -x "$out/monad"
