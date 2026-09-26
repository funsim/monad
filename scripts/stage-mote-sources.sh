#!/usr/bin/env bash
# Stage the SECOND nightly artifact: the mote sources a consumer needs.
#
# The binary alone cannot compile anything outside a compiler checkout. It
# resolves `init`/`std` from CWD-relative literals (`init/src/`, `std/src/`)
# and the C runtime from a workspace-root walk that falls back to
# `runtime/src/runtime.c` (`runtime/src/lib.mo`'s `Runtime.c_path`) -- so
# `use std::map` and every `compile`/`run`/`test` need a checked-out tree,
# which is exactly what an external mote workspace does not have. This
# tarball is the other half: unpacked into the version directory by
# `monadup`, it makes that directory a toolchain root the compiler can find
# (`Mote.toolchain_root`, `lang/src/mote.mo`).
#
# Only the three motes a CONSUMER needs are in it. `lang`/`cli` are the
# compiler itself and are already in the binary; shipping them would double
# the artifact for nothing. `src/` goes in wholesale, including the
# `*_tests.mo` modules: that is one rule instead of a filter, and it makes
# the bundle self-testable, because `init`'s `[dev-dependencies.std]`
# resolves inside it.
#
# Sizes that make this cheap: init 148K, std 236K, runtime 128K.
#
# The generated root manifest is what makes the unpacked directory a
# WORKSPACE rather than three loose motes, so a human can `monad check -w`
# in it and `monadup`'s directory is directly usable as `MONAD_ROOT`.
#
# Usage: scripts/stage-mote-sources.sh [out_dir]   (default: <root>/dist)
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${1:-$root/dist}"
asset="$out_dir/monad-src-x86_64-linux.tar.gz"

member_manifests=(init/mote.toml std/mote.toml runtime/mote.toml)
members=(init std runtime)

for m in "${members[@]}"; do
  [ -f "$root/$m/mote.toml" ] || { echo "stage-mote-sources: $m/mote.toml is missing" >&2; exit 1; }
  [ -d "$root/$m/src" ] || { echo "stage-mote-sources: $m/src is missing" >&2; exit 1; }
done

mkdir -p "$out_dir"

# Staged in a private temp dir, then tarred with an explicit member list so
# the archive holds `init/...`, not `./init/...`. `mktemp -d` rather than a
# fixed path under /tmp: two runs on one machine must not share it.
staging="$(mktemp -d "${TMPDIR:-/tmp}/monad-src-stage.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

for m in "${members[@]}"; do
  mkdir -p "$staging/$m"
  cp "$root/$m/mote.toml" "$staging/$m/mote.toml"
  cp -R "$root/$m/src" "$staging/$m/src"
done

cat > "$staging/mote.toml" <<'TOML'
# The unpacked toolchain root: what `monadup` leaves in the version
# directory beside the binary. See scripts/stage-mote-sources.sh.
#
# Written with a `[workspace]` header rather than an inline table because
# the self-hosted reader (lang/src/toml.mo) supports headers only.

[workspace]
members = ["init", "std", "runtime"]
TOML

rm -f "$asset"
tar -czf "$asset" -C "$staging" "${members[@]}" mote.toml

# The archive is the artifact; assert its shape here rather than in the
# release step, so a wrong member list fails the build that produced it.
listing="$(tar -tzf "$asset")"
for want in "${member_manifests[@]}" runtime/src/runtime.c mote.toml; do
  grep -qxF "$want" <<<"$listing" \
    || { echo "stage-mote-sources: '$want' is not in $asset" >&2; exit 1; }
done

echo "stage-mote-sources: wrote $asset"
wc -c < "$asset" | sed 's/^/stage-mote-sources: /;s/$/ bytes/'
