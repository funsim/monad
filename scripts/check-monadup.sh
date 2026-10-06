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
#   * a release WITH the sources asset -- binary, commit.txt and the four
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
# Every one of those is exercised for EVERY platform the release names, because
# the asset a night's install wants is chosen from the machine's `uname -sm`
# and the choice is invisible on the machine running this script. The probe's
# answer is overridden rather than its result, so the platform TABLE is what
# gets driven, plus two cases that have no platform of their own: a release
# published before a platform existed, and a machine no nightly is built for.
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

# A PATH holding every tool `monadup` runs, except `$1` -- which is how the two
# JSON parsers get driven one at a time (section 6). Built from absolute
# symlinks into the real PATH, so what is missing is missing and everything else
# still resolves. `gzip` is `tar -xzf`'s own child, not something the script
# names; a tool left out of this list fails loudly at the point it is needed,
# which is how it was found.
path_without() {
  local what="$1" p
  local dir="$work/path-without-${1}"
  local t
  mkdir -p "$dir"
  for t in env bash uname curl tar gzip mkdir chmod rm ln cat basename jq python3; do
    if [ "$t" = "$what" ]; then
      continue
    fi
    p="$(command -v "$t" 2>/dev/null || true)"
    if [ -n "$p" ]; then
      ln -sf "$p" "$dir/$t"
    fi
  done
  echo "$dir"
}

# ---------------------------------------------------------------------------
# 1. The staging step, asserted from the artifact it produced
# ---------------------------------------------------------------------------

dist="$work/dist"
"$root/scripts/stage-mote-sources.sh" "$dist" x86_64-linux >/dev/null
asset="$dist/monad-src-x86_64-linux.tar.gz"
[ -f "$asset" ] || die "stage-mote-sources.sh wrote no $asset"

listing="$(tar -tzf "$asset")"
for want in init/mote.toml std/mote.toml llvm/mote.toml runtime/mote.toml \
            init/src/lib.mo std/src/lib.mo llvm/src/ir.mo runtime/src/runtime.c \
            mote.toml; do
  grep -qxF "$want" <<<"$listing" || die "sources asset is missing '$want'"
done
ok "sources asset carries the four motes' manifests, sources and runtime.c"

# The generated root manifest is what makes the unpacked directory a
# WORKSPACE rather than four loose motes -- and it is generated, so it is
# asserted rather than assumed.
tar -xzOf "$asset" mote.toml | grep -qF 'members = ["init", "std", "llvm", "runtime"]' \
  || die "sources asset's root mote.toml does not declare the four motes as members"
ok "sources asset's root mote.toml is a workspace naming all four motes"

# The exclusion is deliberate (they are already inside the binary): if a
# later edit drops it, the artifact doubles in size and this says why that
# was a decision and not an oversight.
if grep -qE '^(lang|cli)/' <<<"$listing"; then
  die "sources asset contains lang/ or cli/ -- the compiler itself is already in the binary"
fi
ok "sources asset contains neither lang/ nor cli/"

# The second name for the same tree. Asserted by listing rather than by a
# checksum, which also proves the ARCHIVE is the same one and not a re-tar of
# the same inputs -- and needs no tool beyond tar.
[ "$(tar -tzf "$dist/monad-src.tar.gz")" = "$listing" ] \
  || die "the platform-neutral monad-src.tar.gz is not the same archive as $asset"
ok "the platform-neutral monad-src.tar.gz is the same archive"

# ---------------------------------------------------------------------------
# 2. monadup installs the assets a release ships, for every platform
# ---------------------------------------------------------------------------

tag="nightly-FIXTURE"

# What `uname -sm` prints on a machine of that platform. `monadup` derives its
# label from that pair, so the loop below is what tests the mapping -- a label
# set directly would skip it.
platform_uname() {
  case "$1" in
    x86_64-linux) echo "Linux x86_64" ;;
    aarch64-linux) echo "Linux aarch64" ;;
    riscv64-linux) echo "Linux riscv64" ;;
    aarch64-darwin) echo "Darwin arm64" ;;
    *) die "no uname pair for platform '$1'" ;;
  esac
}

# A release, as GitHub's API returns it: an array, newest first, with the
# asset URLs spelled as `file://` into this fixture directory. The asset
# layout is flat because a release's is -- monadup derives the sources URL
# from the binary's, so the two must sit side by side, and it looks the sources
# up under the same platform as the binary it took.
make_release() {
  local dir="$1" platform="$2" with_sources="${3:-no}"
  mkdir -p "$dir"
  cat > "$dir/monad-nightly-${platform}" <<'SH'
#!/bin/sh
[ "${1:-}" = version ] && echo "monad fixture (not a real binary)"
exit 0
SH
  chmod +x "$dir/monad-nightly-${platform}"
  printf 'deadbeef\n' > "$dir/commit.txt"
  if [ "$with_sources" = yes ]; then
    "$root/scripts/stage-mote-sources.sh" "$dir" "$platform" >/dev/null
  fi
  cat > "$dir/releases" <<JSON
[
  {
    "tag_name": "${tag}",
    "assets": [
      {
        "name": "monad-nightly-${platform}",
        "browser_download_url": "file://${dir}/monad-nightly-${platform}"
      }
    ]
  }
]
JSON
}

for platform in x86_64-linux aarch64-linux riscv64-linux aarch64-darwin; do
  fix="$work/release-${platform}"
  home="$work/home-${platform}"
  make_release "$fix" "$platform" yes

  MONAD_HOME="$home" \
  MONADUP_API_URL="file://${fix}/releases" \
  MONADUP_UNAME="$(platform_uname "$platform")" \
    "$root/scripts/monadup" install > "$work/install-${platform}.log" 2>&1 \
    || { cat "$work/install-${platform}.log" >&2; die "monadup install failed for ${platform}"; }

  vdir="$home/downloads/${tag}"
  [ -x "$vdir/monad-nightly-${platform}" ] || die "no executable ${platform} binary in ${vdir}"
  [ "$(cat "$vdir/commit.txt")" = deadbeef ] || die "commit.txt was not installed for ${platform}"
  for m in init std llvm runtime; do
    [ -d "$vdir/$m" ] || die "the sources asset was not unpacked for ${platform}: ${vdir}/${m} is missing"
  done
  [ -f "$vdir/mote.toml" ] || die "the generated root mote.toml is missing from ${vdir}"
  [ -f "$vdir/std/src/map.mo" ] || die "the unpacked std is not the real std (${platform})"
  [ -f "$vdir/llvm/src/ir.mo" ] || die "the unpacked llvm is not the real llvm (${platform})"

  [ "$(cat "$home/active")" = "$tag" ] || die "the ${platform} fixture was not made active"
  # The symlink is made by PATTERN, so this is where a version directory
  # installed by an older monadup would stop being usable if the pattern were
  # narrowed wrongly.
  [ "$(readlink "$home/bin/monad")" = "../downloads/${tag}/monad-nightly-${platform}" ] \
    || die "bin/monad does not point at the ${platform} binary"

  # The tarball is an installation input, not part of the install: leaving it
  # behind would make the version directory look like it has an extra asset,
  # and `uninstall` would only reclaim it by luck.
  if [ -e "$vdir/monad-src-${platform}.tar.gz" ] || [ -e "$vdir/monad-src.tar.gz" ]; then
    die "the sources tarball was left in the ${platform} version directory"
  fi
done
ok "monadup installs the binary, commit.txt and the four motes, for all four platforms"

# ---------------------------------------------------------------------------
# 3. A release with no sources asset still installs, and explains itself
# ---------------------------------------------------------------------------

fix_old="$work/release-binary-only"
make_release "$fix_old" x86_64-linux no
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
grep -q "ships no monad-src-x86_64-linux.tar.gz and no monad-src.tar.gz" "$work/install-old.log" \
  || { cat "$work/install-old.log" >&2; die "no note about the missing sources asset"; }
grep -q "declare \[dependencies.runtime\]" "$work/install-old.log" \
  || { cat "$work/install-old.log" >&2; die "the note does not say what the user loses"; }
ok "a binary-only release installs the binary, exits 0 and says what is missing"

# ---------------------------------------------------------------------------
# 4. The fallback chain: a release that predates a platform, and a machine no
#    nightly is built for
# ---------------------------------------------------------------------------

# This is the case that makes every tag published before the other platforms
# exist installable on them. The binary's NAME carries the platform, and a
# release that has only the x86_64-linux one must be taken rather than refused:
# it runs, under emulation, where an error over a release that is perfectly fine
# would leave the machine with nothing. The note is asserted because silently
# installing another platform's binary is worse than either.
fix_only="$work/release-x86_64-only"
home_fallback="$work/home-fallback"
make_release "$fix_only" x86_64-linux yes

MONAD_HOME="$home_fallback" \
MONADUP_API_URL="file://${fix_only}/releases" \
MONADUP_UNAME="Linux aarch64" \
  "$root/scripts/monadup" install > "$work/install-fallback.log" 2>&1 \
  || { cat "$work/install-fallback.log" >&2; die "an aarch64 machine must be able to install an x86_64-only release"; }

vdir_fallback="$home_fallback/downloads/${tag}"
[ -x "$vdir_fallback/monad-nightly-x86_64-linux" ] \
  || die "the fallback did not install the x86_64-linux binary"
[ -d "$vdir_fallback/init" ] || die "the fallback did not install the x86_64-linux sources"
grep -q "ships no monad-nightly-aarch64-linux binary" "$work/install-fallback.log" \
  || { cat "$work/install-fallback.log" >&2; die "the fallback does not say which platform it looked for"; }
ok "a release with only the x86_64-linux assets installs on aarch64, and says so"

# And a machine that matches no platform at all: the fallback is the only thing
# between it and an error, so it is asserted on its own -- and so is the note
# naming the pair that was unrecognised, which is the whole diagnostic.
fix_odd="$work/release-odd-machine"
home_odd="$work/home-odd-machine"
make_release "$fix_odd" x86_64-linux yes

MONAD_HOME="$home_odd" \
MONADUP_API_URL="file://${fix_odd}/releases" \
MONADUP_UNAME="SunOS sun4u" \
  "$root/scripts/monadup" install > "$work/install-odd.log" 2>&1 \
  || { cat "$work/install-odd.log" >&2; die "an unrecognised machine must still install"; }

grep -q "no nightly is published for 'SunOS sun4u'" "$work/install-odd.log" \
  || { cat "$work/install-odd.log" >&2; die "no note naming the machine with no platform"; }
[ -x "$home_odd/downloads/${tag}/monad-nightly-x86_64-linux" ] \
  || die "an unrecognised machine did not install the x86_64-linux binary"
ok "an unrecognised machine installs the x86_64-linux artifacts and names itself in the note"

# The one case that IS an error: a release with neither this machine's binary
# nor the fallback's. It has to name what was looked for AND the machine asking,
# because "no asset" reads as a broken release rather than as one that does not
# cover this machine.
fix_none="$work/release-no-assets"
home_none="$work/home-no-assets"
make_release "$fix_none" x86_64-linux yes
sed 's/monad-nightly-x86_64-linux/monad-nightly-sparc-solaris/g' "$fix_none/releases" \
  > "$fix_none/releases.tmp"
mv "$fix_none/releases.tmp" "$fix_none/releases"

if MONAD_HOME="$home_none" \
   MONADUP_API_URL="file://${fix_none}/releases" \
   MONADUP_UNAME="Linux riscv64" \
     "$root/scripts/monadup" install > "$work/install-none.log" 2>&1; then
  die "a release shipping no asset for this machine must fail"
fi
grep -q "monad-nightly-riscv64-linux" "$work/install-none.log" \
  || { cat "$work/install-none.log" >&2; die "the error does not name the platform that was looked for"; }
grep -q "monad-nightly-x86_64-linux" "$work/install-none.log" \
  || { cat "$work/install-none.log" >&2; die "the error does not name the fallback that was tried"; }
ok "a release with neither asset fails, naming both names and the platform asking"

# ---------------------------------------------------------------------------
# 5. Re-running install repairs a binary-only version directory
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
for m in init std llvm runtime; do
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

# ---------------------------------------------------------------------------
# 6. Both JSON parsers carry an install
# ---------------------------------------------------------------------------

# `monadup` ships a jq path and a python3 path because it runs on machines
# nobody here controls, and the machine running THIS script only ever exercises
# whichever one it has -- so the other is a branch that ships green and
# unexercised. Each is driven here with the other hidden from PATH.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for parser in jq python3; do
    fix_p="$work/release-parser-${parser}"
    home_p="$work/home-parser-${parser}"
    make_release "$fix_p" x86_64-linux yes

    MONAD_HOME="$home_p" \
    MONADUP_API_URL="file://${fix_p}/releases" \
    MONADUP_UNAME="Linux x86_64" \
    PATH="$(path_without "$parser")" \
      "$root/scripts/monadup" install > "$work/install-parser-${parser}.log" 2>&1 \
      || { cat "$work/install-parser-${parser}.log" >&2; die "install failed with ${parser} hidden from PATH"; }

    [ -x "$home_p/downloads/${tag}/monad-nightly-x86_64-linux" ] \
      || die "the install with ${parser} hidden produced no binary"
    [ -d "$home_p/downloads/${tag}/init" ] \
      || die "the install with ${parser} hidden produced no sources"
  done
  ok "an install works with jq hidden from PATH and with python3 hidden"
else
  ok "only one JSON parser is present; the other's branch is untested on this machine"
fi

echo "check-monadup: all checks passed"
