#!/usr/bin/env bash
# Does a mote in its OWN repository build with the compiler alone?
#
# Every other check in this repo runs from the repository root, where the
# stdlib is `init/src` and `std/src` beside the working directory and the C
# runtime is at `runtime/src/runtime.c` -- all three resolved by CWD-relative
# literals. That is exactly the environment an external mote does not have,
# and it is why this whole class of bug survived: nothing in the repo ever
# ran the CLI from a directory that was not the checkout. The Forge game
# engine, built as a sibling repository, found five such gaps at once.
#
# So this script builds a mote in a temporary directory *outside* the
# checkout and runs the compiled self-hosted binary from inside it, in the
# three configurations an external user can be in:
#
#   1. declared path dependencies, explicit path -- `monad check src/lib.mo`.
#      The filed repro: everything resolves except `runtime.c`, which had no
#      manifest fallback at all, so `test`/`compile` died at the link stage.
#   2. the same repository, invoked bare -- `cd repo && monad check`, which
#      sets the mote's own directory to `"."` and turns every absolute
#      `[dependencies.X] path` into `"./<abs>"` through a naive join.
#   3. NO path dependencies, an installed toolchain -- `MONAD_ROOT=<root>`,
#      where the root holds `init/`, `std/` and `runtime/` copied from this
#      checkout. Nothing is declared and nothing is relative: this is the
#      acceptance test for "a mote in its own repo compiles with a
#      monadup-installed toolchain".
#
# Configuration 3 also compiles and RUNS a binary, which is the only
# assertion that covers the C runtime end to end: the program prints through
# `println`, so a build that never found `runtime.c` cannot produce it.
#
# Takes the compiled binary as its first argument (or `MONAD_BIN`). It must
# be the self-hosted compiler, not the Rust host: `monad-rs` resolves its own
# modules relative to the checkout and cannot be pointed at a foreign CWD.
#
# Run it directly (`scripts/check-external-mote.sh <binary>`); it needs
# `llc`, `clang` and the Boehm GC headers, i.e. the dev shell.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
monad="${1:-${MONAD_BIN:-}}"
[ -n "$monad" ] || { echo "usage: scripts/check-external-mote.sh <path-to-compiled-monad>" >&2; exit 2; }
monad="$(cd -- "$(dirname -- "$monad")" && pwd)/$(basename -- "$monad")"
[ -x "$monad" ] || { echo "check-external-mote: '${monad}' is not executable" >&2; exit 2; }

# PID in the name (plus `mktemp -d`), so parallel runs on one machine never
# share a directory.
work="$(mktemp -d "${TMPDIR:-/tmp}/monad-external-mote.$$.XXXXXX")"
trap 'rm -rf "$work"' EXIT

ok() { echo "ok   - $*"; }
die() { echo "FAIL - $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The fixture: a mote with a library, a binary and one test
# ---------------------------------------------------------------------------
#
# The library goes through `std::path` on purpose. `Path` is std's own code,
# so a build that silently resolved std from somewhere stale -- or failed to
# resolve it and carried on -- does not reproduce the answer below. `main`
# prints, which forces the C runtime into the link.

mkdir -p "$work/src"

cat > "$work/src/lib.mo" <<'MONAD'
// The library half of the external-mote fixture. `std::path` is reached by
// name (no path dependency in configuration 3), and the answer is a
// two-segment join, so a std that resolved from anywhere plausible still has
// to produce the right string.

use std::path {Path}

def join2 (a : String) (b : String) : String :=
    match Path.of a {
        err _ => a,
        ok p => match Path.of b {
            err _ => b,
            ok q => Path.to_string (Path.join p q),
        },
    }

def data_dir (root : String) : String := join2 root "data"

#[test]
def test_data_dir : Bool := String.beq (data_dir "/var/lib/game") "/var/lib/game/data"
MONAD

cat > "$work/src/main.mo" <<'MONAD'
// The binary half. It prints, so the C runtime is in the link, and it calls
// into the library, so the mote's own `lib::` self-resolution is exercised
// too.

use io {IO}
open IO {println}
use lib::lib {data_dir}

def main (args : List String) : IO Unit := println (data_dir "/var/lib/game")
MONAD

write_manifest() {
  local dir="$1" deps="$2"
  mkdir -p "$dir/src"
  cp "$work/src/lib.mo" "$work/src/main.mo" "$dir/src/"
  {
    cat <<'TOML'
# The external-mote fixture. Its own repository, its own manifest, no
# compiler checkout anywhere above it.

[mote]
name = "game"
version = "0.1.0"
edition = "2026"

[lib]
path = "src/lib.mo"

[bin]
name = "game"
path = "src/main.mo"
TOML
    # Configuration 3 declares nothing: the toolchain root is what supplies
    # init/std/runtime, and a dependency entry would hide the fact that it
    # did not have to.
    [ "$deps" = no ] || cat <<TOML

[dependencies.init]
path = "${root}/init"

[dependencies.std]
path = "${root}/std"

[dependencies.runtime]
path = "${root}/runtime"
TOML
  } > "$dir/mote.toml"
}

# `nested/` rather than the top of the temp dir: `find_workspace_root` walks
# UP from the working directory looking for a `[workspace]` manifest, so the
# fixture's own directory tree must not contain one by accident.
withdeps="$work/nested/withdeps"
nodeps="$work/nested/nodeps"
write_manifest "$withdeps" yes
write_manifest "$nodeps" no

# The installed toolchain, laid out exactly as `monadup` leaves it: the three
# motes plus the generated workspace manifest.
toolchain="$work/nested/toolchain"
mkdir -p "$toolchain"
for m in init std runtime; do
  cp -R "$root/$m" "$toolchain/$m"
done
cat > "$toolchain/mote.toml" <<'TOML'
[workspace]
members = ["init", "std", "runtime"]
TOML

# ---------------------------------------------------------------------------
# 1. Declared path dependencies, explicit path
# ---------------------------------------------------------------------------

cd "$withdeps"

check_log="$work/check1.log"
"$monad" check src/lib.mo > "$check_log" 2>&1 \
  || { cat "$check_log" >&2; die "config 1: 'monad check src/lib.mo' failed outside a checkout"; }
if grep -qE '^FAIL' "$check_log"; then
  die "config 1: check reported a FAIL line"
fi
ok "config 1: check resolves declared path deps from a foreign directory"

test_log="$work/test1.log"
"$monad" test src/lib.mo > "$test_log" 2>&1 \
  || { cat "$test_log" >&2; die "config 1: 'monad test src/lib.mo' failed outside a checkout"; }
grep -q "1/1 total tests passed" "$test_log" \
  || { cat "$test_log" >&2; die "config 1: the test did not run and pass"; }
ok "config 1: test compiles, links against the declared runtime and runs the test"

# The same in the strongest form: a real binary, linked against the C
# runtime found through `[dependencies.runtime]`, executed.
"$monad" compile src/main.mo -o "$work/out1" > "$work/compile1.log" 2>&1 \
  || { cat "$work/compile1.log" >&2; die "config 1: compile failed on the C runtime"; }
[ "$("$work/out1")" = "/var/lib/game/data" ] \
  || die "config 1: the compiled binary printed the wrong thing"
ok "config 1: compile produces a working binary"

# ---------------------------------------------------------------------------
# 2. The same repository, invoked bare
# ---------------------------------------------------------------------------

# Bare, the mote's own directory is `"."`, so every declared absolute path
# dep is joined onto it -- which is where a naive `raw_path_join` produced
# `".//home/.../init"` and every dependency silently vanished.
bare_check="$work/check2.log"
"$monad" check > "$bare_check" 2>&1 \
  || { cat "$bare_check" >&2; die "config 2: bare 'monad check' failed on absolute path deps"; }
if grep -qE '^FAIL' "$bare_check"; then
  die "config 2: bare check reported a FAIL line"
fi
ok "config 2: bare check resolves absolute path deps"

bare_test="$work/test2.log"
"$monad" test > "$bare_test" 2>&1 \
  || { cat "$bare_test" >&2; die "config 2: bare 'monad test' failed on absolute path deps"; }
grep -q "1/1 total tests passed" "$bare_test" \
  || { cat "$bare_test" >&2; die "config 2: the bare test run did not run and pass"; }
ok "config 2: bare test runs the mote's tests"

# ---------------------------------------------------------------------------
# 3. No path dependencies, an installed toolchain
# ---------------------------------------------------------------------------

cd "$nodeps"

# The manifest really is empty of deps -- otherwise this configuration would
# be passing for the wrong reason.
if grep -q 'dependencies' mote.toml; then
  die "config 3: the fixture declares dependencies after all"
fi

root_check="$work/check3.log"
MONAD_ROOT="$toolchain" "$monad" check > "$root_check" 2>&1 \
  || { cat "$root_check" >&2; die "config 3: 'monad check' did not resolve init/std from the toolchain root"; }
if grep -qE '^FAIL' "$root_check"; then
  die "config 3: check reported a FAIL line"
fi
ok "config 3: check resolves init/std from \$MONAD_ROOT with no declared deps"

root_test="$work/test3.log"
MONAD_ROOT="$toolchain" "$monad" test > "$root_test" 2>&1 \
  || { cat "$root_test" >&2; die "config 3: 'monad test' did not resolve the toolchain root"; }
grep -q "1/1 total tests passed" "$root_test" \
  || { cat "$root_test" >&2; die "config 3: the test did not run and pass"; }
ok "config 3: test resolves init/std/runtime from \$MONAD_ROOT"

# The acceptance test for the whole feature: nothing declared, nothing
# relative, and a program that runs.
MONAD_ROOT="$toolchain" "$monad" compile src/main.mo -o "$work/out3" > "$work/compile3.log" 2>&1 \
  || { cat "$work/compile3.log" >&2; die "config 3: compile did not find runtime.c in the toolchain root"; }
[ "$("$work/out3")" = "/var/lib/game/data" ] \
  || die "config 3: the compiled binary printed the wrong thing"
ok "config 3: compile links the toolchain's runtime and the binary runs"

echo "check-external-mote: an external mote loads, checks, tests and compiles in all three configurations"
