#!/usr/bin/env bash
# Does this change touch anything that defines the flake's packaged compiler?
# Prints `true` or `false` on stdout and ALWAYS exits 0, for the same reason
# scripts/ci-compiler-relevant.sh does -- the caller puts the answer straight
# into `$GITHUB_OUTPUT` without a failing status turning the step red. Usage:
#
#   scripts/ci-flake-relevant.sh <base-revision> [head-revision]
#
# It exists because `packages.monad` left the per-PR path. The sweep no longer
# grades the flake's artifact -- it grades the ladder's own release rung-1
# (`scripts/ci-compiler-checks.sh`), which is the same binary built by the same
# script, so what the flake package still adds is its PACKAGING: the sandboxed
# build, the link step that stamps the revision, and the wrapper that puts
# llc/clang/boehmgc on PATH. `nix/**`, `flake.nix`, `flake.lock` and any
# `mote.toml` can break that, so those ask for this job.
#
# ALLOW-LIST, where the compiler classifier is a deny-list, and the difference
# is the cost of being wrong in each direction. That one must not miss a
# compiler input, so it fails open and only ignores paths it can name as
# inert. This one must not buy a 26-minute cold build for a change that cannot
# reach the package, and the set of files that CAN is small enough to write
# down -- so everything not named here answers `false`.
#
# A `flake.lock` bump is the one change here that is legitimately cold: it
# moves the toolchain, so `rung1` is a miss. A `nix/*.nix` edit usually is not
# -- `compilerSrc` (nix/monad.nix) is built from the SOURCE TREES, not from the
# nix expressions, so the interpretation is a store hit and only the link and
# the wrapper are rebuilt.
#
# That same sentence is why the allow-list cannot be `nix/**` alone, which it
# was until a source-side change broke the package and this job skipped: if
# `compilerSrc` is built from the source trees, then what the package CONTAINS
# is decided outside `nix/`. Specifically by the manifests -- see the
# `mote.toml` arm below.
#
# THE DECISION STILL FAILS OPEN, in the direction that costs time: no base, an
# all-zeros base (`github.event.before` on a new branch), an unreachable one,
# or any git error answers `true`. A skipped job reports a verdict and a
# skipped WORKFLOW leaves its required checks pending, which is why this is a
# job-level gate and never a `paths-ignore`.
set -euo pipefail

base="${1:-}"
head="${2:-HEAD}"

files=""
if [ -n "$base" ] && ! printf '%s' "$base" | grep -qE '^0+$' \
  && git rev-parse --verify --quiet "${base}^{commit}" > /dev/null 2>&1; then
  files="$(git diff --name-only "$base" "$head" 2> /dev/null)" || files=""
fi

if [ -z "$files" ]; then
  echo true
  exit 0
fi

# Every path the package is DEFINED by. `nix/*` covers everything UNDER the
# flake's own nix/ directory, at any depth, and nothing else: a case pattern's
# `*` matches `/`, so a new nix/lib/new.nix is covered without this list
# changing, while the pattern is anchored at the repository root, so a `nix/`
# directory somewhere else in the tree (`sub/nix/x.nix`) is not. Both halves of
# that were measured on a scratch repository rather than assumed -- `nix/a.nix`
# and `nix/deep/er/new.nix` answer `true`, `sub/nix/b.nix` answers `false` --
# and the anchor is right because `flake.nix`'s paths are relative to this
# repository's root, which is the only `nix/` the package has.
#
# Deliberately NOT here: devenv.nix and devenv.lock. They describe the dev
# shell every job enters, not the package, and a broken one already fails at
# the top of `compiler-checks` (which is where `nix/**` also belongs, and stays:
# a broken `nix/` breaks `nix develop` before it breaks the package).
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    nix/* | flake.nix | flake.lock) echo true; exit 0 ;;
    # A MANIFEST, because it can change what the package has to CONTAIN. The
    # rest of a source tree cannot: `compilerSrc` already covers those trees,
    # so an edit inside one is a different hash of the same file list and the
    # build either hits the store or re-interprets -- correct either way. A
    # `mote.toml` is the exception, because it is where a new dependency is
    # declared: `cli/mote.toml` gained `[dependencies.lsp]` and the fileset did
    # not gain `motes/lsp`, so `nix build .#monad` broke with `module not
    # found: lsp.server` while this classifier answered `false` and the job
    # that would have caught it never ran. Manifest edits are rare, so paying
    # a cold build for one is the cheap side of that trade.
    mote.toml | */mote.toml) echo true; exit 0 ;;
  esac
done <<< "$files"

echo false
