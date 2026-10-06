#!/usr/bin/env bash
# Build the nightly release artifact: one self-compile of the self-hosted
# compiler, staged into <root>/dist/ exactly where the release step in
# .github/workflows/nightly.yml uploads from.
#
# This used to be four inline `run:` lines in that workflow, and the first
# of them -- `file dist/monad-nightly-x86_64-linux` -- was the only command
# in the repo that ran outside `nix develop`. A bare `run:` gets the
# RUNNER HOST's PATH, not the dev shell's, so `file` was "command not
# found" on the runner while resolving fine for anyone sitting in the dev
# shell whose devenv.nix lists it. Keeping the whole pipeline here, entered
# through `nix develop` -- and locally as `devenv tasks run monad:nightly`,
# or this script directly -- is what makes every tool it uses a declared
# dependency instead of an assumption about the host.
#
# Usage: scripts/nightly-release.sh [platform]
#
# `platform` names the artifacts (`monad-nightly-<platform>`) and, absent an
# argument, comes from an ambient MONAD_PLATFORM and then from this machine's
# own label; see scripts/lib/platform-label.sh. A cross leg must pass its
# TARGET's label, since the binary it stages is named after the platform it is
# for and not after the runner that produced it -- and the `check` below, which
# is what makes the published artifact a verified one, is only meaningful where
# that binary runs. A cross leg's verification is its derivation's checkPhase.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Argument, then environment, then the lib's table. `${1:-}` alone CLOBBERS an
# ambient MONAD_PLATFORM with the empty string, which the lib reads as "unset"
# -- so a cross leg driven from the environment silently published this
# machine's native label instead.
MONAD_PLATFORM="${1:-${MONAD_PLATFORM:-}}"
# shellcheck source=scripts/lib/platform-label.sh
# shellcheck disable=SC1091  # the hook runs bare `shellcheck`; the line above names the path for -x
. "$root/scripts/lib/platform-label.sh"
bin="$root/dist/monad-nightly-${MONAD_PLATFORM}"

# A self-hosted runner's workspace is dirty across runs and the release step
# uploads whatever is in dist/ -- clear it, so a failed build can never
# publish the previous night's binary.
rm -rf "$root/dist"
mkdir -p "$root/dist"

# The revision the artifact will claim is exported by
# scripts/build-self-hosted.sh below (`git -C` that checkout, unless the
# environment already names one) -- one definition, so the nightly cannot
# disagree with the ladder's own rung-1 builds about which commit they are.
# That export is why this script no longer carries its own copy: it is read
# by the compiler at LINK time, in whichever process does the linking, and
# the host doing that here is `cargo run --release --`, whose own baked-in
# answer is the literal "unknown" (`build_commit_define`, llvm/src/link.mo).

cd "$root"

# The build itself is scripts/build-self-hosted.sh -- the same rung-1 command
# the bootstrap job runs -- rather than a second copy of the compile line, so
# the two cannot drift in their flags, their stack rlimit, or their stdlib
# handling. It writes `<out-dir>/monad`; the release step uploads a name with
# the platform in it, so the file is moved rather than rebuilt.
#
# MONAD_HOST_BIN is the knob that keeps this from being a cold build: CI's
# `nightly` job sets it from the flake (`nix build .#monadHost`), which is
# the SAME host `compiler-checks` uses and is a 2s store lookup there,
# where an unqualified `cargo run --release --` was a cold fat-LTO build
# (~10 min, since actions/checkout cleans the target directories at the start
# of every job).
# Unset -- a local `devenv tasks run monad:nightly` -- it falls back to
# cargo, which is what a developer with no flake host has.
scripts/build-self-hosted.sh "$root/dist" --verbose --release
mv "$root/dist/monad" "$bin"
test -x "$bin"
chmod +x "$bin"
file "$bin"

# What the binary says it was built from. An unidentifiable published
# artifact is a real defect, not a cosmetic one -- so an empty or "unknown"
# line fails here. This is the check that would have caught the export above
# going missing, which is what makes it worth keeping even though the export
# now sets the value deliberately.
"$bin" version > "$root/dist/commit.txt"
cat "$root/dist/commit.txt"
grep -qvE '^$|^unknown$' "$root/dist/commit.txt"

# The binary that ships has to do the job it was built for: the same ~12s
# front-end sweep `monad:bootstrap-compile` runs in ci.yml, on the exact
# artifact being published.
"$bin" check cli/src/main.mo

# The second artifact: `init`/`std`/`runtime`, which is what lets the binary
# above compile anything OUTSIDE a compiler checkout. `monadup` unpacks it
# into the same version directory as the binary, and the compiler then finds
# it as a toolchain root (`Mote.toolchain_root`, `lang/src/mote.mo`). Staged
# by its own script because that script is also what the staging test drives
# against a temp directory -- see scripts/check-monadup.sh. It takes the same
# label, so the two artifacts of a leg are always for the same platform.
"$root/scripts/stage-mote-sources.sh" "$root/dist" "$MONAD_PLATFORM"

# The workflow's `tag`/`date` step outputs, for the release step. Written
# here rather than in a second `nix develop` step of their own: they are this
# script's own output, so a second entry would buy nothing and add a second
# way for the release job to fail over something that has nothing to do with
# the release. `date` here is the dev shell's coreutils, like every other
# command in this script.
#
# Nothing is saved by avoiding a shell entry either way, and that is the one
# thing about the cost worth writing down: nightly.yml sets
# DEVENV_SKIP_TASKS=1, so entering the dev shell no longer runs the
# pre-commit sweep (the shellHook's devenv-tasks invocation is gated on
# that variable). The outputs argument above still decides the shape --
# writing them here rather than in a second `nix develop -c` avoids a second
# way for the release job to fail over something unrelated to the release.
# Unset outside Actions, which is the only place these outputs mean anything.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  date_utc="$(date -u +%Y-%m-%d)"
  # The revision is IN the tag so two pushes in one UTC day cannot share a
  # release: `softprops/action-gh-release` overwrites same-named assets and
  # never deletes, and the "every leg the same revision" check reads only the
  # `commit.txt` files that ARE present, so it cannot see a stale binary left
  # by an earlier run. `scripts/monadup` filters on the `nightly-` prefix only.
  rev_short="${GITHUB_SHA:-}"
  rev_short="${rev_short:0:8}"
  tag="nightly-${date_utc}"
  if [ -n "$rev_short" ]; then tag="${tag}-${rev_short}"; fi
  {
    printf 'tag=%s\n' "$tag"
    printf 'date=%s\n' "$date_utc"
    printf 'rev=%s\n' "$rev_short"
  } >> "$GITHUB_OUTPUT"
fi
