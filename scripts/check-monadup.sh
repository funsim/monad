#!/usr/bin/env bash
# Test the DISTRIBUTION half of a nightly: what the sources asset contains,
# and what `monadup` does with it.
#
# Both halves are things the release workflow cannot tell you about. The
# workflow runs once a night on a runner nobody is watching, and its failure
# mode for a wrong member list is not a red step -- it is a published tarball
# that a consumer discovers months later by `monad test` failing on a missing
# `runtime.c`. So the member list is asserted where it is produced
# (scripts/stage-mote-sources.sh does that itself, and this script re-derives
# it from the ARTIFACT), and the install path is driven end to end against a
# local fixture.
#
# The fixture is the reason `MONADUP_API_URL` exists (scripts/monadup): with
# the releases URL overridable, `curl file://` stands in for the GitHub API
# and the whole fetch-verify-unpack path runs offline, against a release this
# script builds on the spot. That covers the two cases the shipped script has
# to get right and cannot be reasoned about from reading it:
#
#   * a release WITH the sources asset -- binary, commit.txt and the three
#     motes all end up in the version directory, which is what makes it a
#     toolchain root the compiler can find on its own;
#   * a release WITHOUT one -- every nightly published before the asset
#     existed. That must install the binary, say what is missing in the terms
#     of what the user was trying to do, and still exit 0.
#
# Plus the repair path, which is the one behaviour that depends on where a
# call sits rather than on what it does: `do_install_sources` is called
# OUTSIDE the "already installed" branch, so re-running `install` on a
# binary-only version directory adds the sources instead of reporting that
# nothing needs doing.
#
# Run it directly (`scripts/check-monadup.sh`); it needs no compiler, no
# network and no dev shell beyond bash, tar, curl and a JSON parser.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# PID in the name, so two runs on one machine never share a directory, and
# `mktemp -d` on top of that so neither does a run whose PID is recycled.
work="$(mktemp -d "${TMPDIR:-/tmp}/monadup-check.$$.XXXXXX")"
trap 'rm -rf "$work"' EXIT

ok() { echo "ok   - $*"; }
die() { echo "FAIL - $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 \
  || die "neither jq nor python3 is available (monadup needs one for JSON)"

# ---------------------------------------------------------------------------
# 1. The staging step, asserted from the artifact it produced
# ---------------------------------------------------------------------------

dist="$work/dist"
"$root/scripts/stage-mote-sources.sh" "$dist" >/dev/null
asset="$dist/monad-src-x86_64-linux.tar.gz"
[ -f "$asset" ] || die "stage-mote-sources.sh wrote no $asset"

listing="$(tar -tzf "$asset")"
for want in init/mote.toml std/mote.toml runtime/mote.toml \
            init/src/lib.mo std/src/lib.mo runtime/src/runtime.c mote.toml; do
  grep -qxF "$want" <<<"$listing" || die "sources asset is missing '$want'"
done
ok "sources asset carries the three motes' manifests, sources and runtime.c"

# The generated root manifest is what makes the unpacked directory a
# WORKSPACE rather than three loose motes -- and it is generated, so it is
# asserted rather than assumed.
tar -xzOf "$asset" mote.toml | grep -qF 'members = ["init", "std", "runtime"]' \
  || die "sources asset's root mote.toml does not declare the three motes as members"
ok "sources asset's root mote.toml is a workspace naming all three motes"

# The exclusion is deliberate (they are already inside the binary): if a
# later edit drops it, the artifact doubles in size and this says why that
# was a decision and not an oversight.
if grep -qE '^(lang|cli)/' <<<"$listing"; then
  die "sources asset contains lang/ or cli/ -- the compiler itself is already in the binary"
fi
ok "sources asset contains neither lang/ nor cli/"

# ---------------------------------------------------------------------------
# 2. monadup installs a release that ships the asset
# ---------------------------------------------------------------------------

tag="nightly-FIXTURE"

# A release, as GitHub's API returns it: an array, newest first, with the
# asset URLs spelled as `file://` into this fixture directory. The asset
# layout is flat because a release's is -- monadup derives the sources URL
# from the binary's, so the two must sit side by side.
make_release() {
  local dir="$1" with_sources="$2"
  mkdir -p "$dir"
  cat > "$dir/monad-nightly-x86_64-linux" <<'SH'
#!/bin/sh
[ "${1:-}" = version ] && echo "monad fixture (not a real binary)"
exit 0
SH
  chmod +x "$dir/monad-nightly-x86_64-linux"
  printf 'deadbeef\n' > "$dir/commit.txt"
  if [ "$with_sources" = yes ]; then
    cp "$asset" "$dir/monad-src-x86_64-linux.tar.gz"
  fi
  cat > "$dir/releases" <<JSON
[
  {
    "tag_name": "${tag}",
    "assets": [
      {
        "name": "monad-nightly-x86_64-linux",
        "browser_download_url": "file://${dir}/monad-nightly-x86_64-linux"
      }
    ]
  }
]
JSON
}

fix="$work/release-with-sources"
make_release "$fix" yes
home="$work/home-with-sources"

MONAD_HOME="$home" MONADUP_API_URL="file://${fix}/releases" \
  "$root/scripts/monadup" install > "$work/install.log" 2>&1 \
  || { cat "$work/install.log" >&2; die "monadup install failed against the fixture"; }

vdir="$home/downloads/${tag}"
[ -x "$vdir/monad-nightly-x86_64-linux" ] || die "no executable binary in ${vdir}"
[ "$(cat "$vdir/commit.txt")" = deadbeef ] || die "commit.txt was not installed"
for m in init std runtime; do
  [ -d "$vdir/$m" ] || die "the sources asset was not unpacked: ${vdir}/${m} is missing"
done
[ -f "$vdir/mote.toml" ] || die "the generated root mote.toml is missing from ${vdir}"
[ -f "$vdir/std/src/map.mo" ] || die "the unpacked std is not the real std"
ok "monadup installed the binary, commit.txt and the three motes"

[ "$(cat "$home/active")" = "$tag" ] || die "the fixture was not made active"
[ -L "$home/bin/monad" ] || die "no bin/monad symlink"
ok "the fixture is active and bin/monad points at it"

# The tarball is an installation input, not part of the install: leaving it
# behind would make the version directory look like it has an extra asset,
# and `uninstall` would only reclaim it by luck.
if [ -e "$vdir/monad-src-x86_64-linux.tar.gz" ]; then
  die "the sources tarball was left in the version directory"
fi
ok "the sources tarball is not left behind in the version directory"

# ---------------------------------------------------------------------------
# 3. A release with no sources asset still installs, and explains itself
# ---------------------------------------------------------------------------

fix_old="$work/release-binary-only"
make_release "$fix_old" no
home_old="$work/home-binary-only"

MONAD_HOME="$home_old" MONADUP_API_URL="file://${fix_old}/releases" \
  "$root/scripts/monadup" install > "$work/install-old.log" 2>&1 \
  || { cat "$work/install-old.log" >&2; die "a release with no sources asset must still install"; }

vdir_old="$home_old/downloads/${tag}"
[ -x "$vdir_old/monad-nightly-x86_64-linux" ] \
  || die "the binary was not installed from a binary-only release"
if [ -e "$vdir_old/init" ]; then
  die "a binary-only release must not produce an init/ directory"
fi
grep -q "ships no monad-src-x86_64-linux.tar.gz" "$work/install-old.log" \
  || { cat "$work/install-old.log" >&2; die "no note about the missing sources asset"; }
grep -q "declare \[dependencies.runtime\]" "$work/install-old.log" \
  || { cat "$work/install-old.log" >&2; die "the note does not say what the user loses"; }
ok "a binary-only release installs the binary, exits 0 and says what is missing"

# ---------------------------------------------------------------------------
# 4. Re-running install repairs a binary-only version directory
# ---------------------------------------------------------------------------

# This is the "outside the branch" detail, and it is the one that would rot
# silently: moving the call inside the `[[ -x "$binary" ]]` branch would look
# like a tidy-up and would leave every existing user's install permanently
# source-less with no way to fix it but `uninstall`.
cp "$asset" "$fix_old/monad-src-x86_64-linux.tar.gz"
MONAD_HOME="$home_old" MONADUP_API_URL="file://${fix_old}/releases" \
  "$root/scripts/monadup" install > "$work/reinstall.log" 2>&1 \
  || { cat "$work/reinstall.log" >&2; die "re-running install failed"; }

grep -q "already installed" "$work/reinstall.log" \
  || { cat "$work/reinstall.log" >&2; die "re-running install did not take the already-installed path"; }
for m in init std runtime; do
  [ -d "$vdir_old/$m" ] || die "re-running install did not add ${m}/"
done
ok "re-running install adds the sources to an existing binary-only version directory"

# And a third run, now that both halves are present, is a no-op rather than
# an error -- the marker check is what makes that true.
MONAD_HOME="$home_old" MONADUP_API_URL="file://${fix_old}/releases" \
  "$root/scripts/monadup" install > "$work/reinstall2.log" 2>&1 \
  || { cat "$work/reinstall2.log" >&2; die "a repeat install over a complete version directory failed"; }
if grep -q "installed mote sources" "$work/reinstall2.log"; then
  die "a repeat install re-unpacked the sources instead of recognising them"
fi
ok "a repeat install over a complete version directory is a no-op"

echo "check-monadup: all checks passed"
