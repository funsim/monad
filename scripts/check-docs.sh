#!/usr/bin/env bash
# Type-check every Monad code block in the mdBook under docs/.
#
# `mdbook build` only renders markdown -- it never compiles the code inside
# the chapters, which is how the book drifted far enough from the compiler
# that most of its samples stopped parsing. This script closes that gap.
#
# A fenced block tagged ```monad is extracted to its own .mo file and run
# through `check`. A block tagged ```monad,ignore is skipped: that tag is
# for samples that are deliberately not valid today -- syntax the docs
# describe as unimplemented, or fragments shown for illustration -- and
# every one of them should have prose next to it saying so.
#
# WHICH FILES, AND WHICH DEFAULT
#
#   docs/src/*.md   OPT-OUT. ```monad is checked, ```monad,ignore skips.
#                   The chapters are mostly runnable samples, so checking
#                   is the right default.
#
#   AGENTS.md       OPT-IN. ```monad is SKIPPED, ```monad,check asks for it.
#                   AGENTS.md is prose written for contributors and agents,
#                   and most of its fences are FRAGMENTS that cannot be a
#                   file at all: bare expressions, a literal `...`, blocks
#                   whose own next line says they are invalid, blocks that
#                   redefine a prelude name. Compiling them all is not
#                   possible, and mass-tagging them `monad,ignore` would
#                   break the rule above -- an ignore tag means "there is
#                   prose here saying why this is not valid", and for a
#                   fragment there is nothing to say.
#
# So AGENTS.md is opt-in, and the fences worth checking are the ones that
# make a CLAIM a reader would copy: a `use` line, a declaration form, a
# complete example. That is the class that has actually been wrong here --
# AGENTS.md carried a `use` spelling neither compiler accepts, for months,
# while every gate was green (this script never opened the file).
#
# ```monad,check is honoured in docs/src too, so a chapter can opt a
# fragment in for the same reason.
#
# Blocks are checked in isolation, so each ```monad block must stand on its
# own: its own `use`/`open` lines, its own type annotations. That is a
# feature, not a limitation -- a reader copying one block into a file gets
# exactly what the checker saw.
#
# Two modes. The default uses the Rust bootstrap host, which is fast and is
# what the pre-commit hook runs:
#
#   scripts/check-docs.sh
#
# The book documents the SELF-HOSTED compiler, though, so the stricter check is
# to point MONAD_BIN at a bootstrapped `monad` binary:
#
#   MONAD_BIN=/path/to/monad scripts/check-docs.sh
#
# Both binaries take the same `check <paths>...` shape and the same exit codes,
# so no other change is needed. The self-hosted run is expected to be GREEN:
# every construct this header used to tolerate a failure for -- `#[derive]`, a
# `\u{...}` escape, a dotted instance name, a call relying on a brace
# parameter's default -- now checks self-hosted. Measured 2026-09-23 with a
# binary built from the tree: 114 block(s) checked, 0 error(s). Anything it
# reports is therefore a real problem, and docs/src/bootstrap-host.md is where
# the differences that remain between the two compilers are recorded.
#
# The reverse also exists, which is why a few blocks are tagged
# ```monad,ignore even though they are correct: a multiplicity prefix on a
# destructured parameter parses self-hosted and is a parse error on the host.
#
# Module resolution is relative to the working directory, so this must run
# from the repository root (it cd's there itself).

set -euo pipefail

cd "$(dirname "$0")/.."

# Overridable so local runs can use an already-installed `monad-rs` instead
# of paying for a cargo rebuild: MONAD_BIN=monad-rs scripts/check-docs.sh
MONAD_BIN=${MONAD_BIN:-"cargo run --release --quiet --"}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

total=0
skipped=0
declare -a blocks=()
declare -a origins=()

for md in docs/src/*.md AGENTS.md; do
  [ -f "$md" ] || continue
  # Resolved BEFORE the loop, not inside it: a `$(basename "$md" ...)` in the
  # body of a `while ... done < "$md"` reads as writing the file it redirects
  # from (shellcheck SC2094), which it isn't.
  stem=$(basename "$md" .md)
  # Which default this file gets -- see the header. `docs/src` is the book and
  # is checked by default; everything else must ask.
  case "$md" in
    docs/src/*) default=check ;;
    *)          default=skip ;;
  esac
  # State machine over the file: `fence` holds the info string of the block
  # we're inside ("" when outside one), `start` its opening line number.
  fence=""
  start=0
  buf=""
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ -z "$fence" ]; then
      case "$line" in
        '```'*)
          fence=${line#'```'}
          start=$lineno
          buf=""
          ;;
      esac
      continue
    fi
    if [ "$line" = '```' ]; then
      case "$fence" in
        monad)
          if [ "$default" = check ]; then
            total=$((total + 1))
            f="$work/${stem}_$start.mo"
            printf '%s' "$buf" > "$f"
            blocks+=("$f")
            origins+=("$md:$start")
          else
            skipped=$((skipped + 1))
          fi
          ;;
        monad,check)
          total=$((total + 1))
          f="$work/${stem}_$start.mo"
          printf '%s' "$buf" > "$f"
          blocks+=("$f")
          origins+=("$md:$start")
          ;;
        monad,ignore)
          skipped=$((skipped + 1))
          ;;
      esac
      fence=""
      continue
    fi
    buf+="$line"$'\n'
  done < "$md"
done

if [ "$total" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "check-docs: no \`\`\`monad blocks found at all -- is the tag right?" >&2
  exit 1
fi

echo "check-docs: checking $total block(s), skipping $skipped"

# One `check` invocation over every block: it reports per-file diagnostics
# already, and paying the module-loading cost once instead of N times takes
# this from minutes to seconds.
if out=$($MONAD_BIN check "${blocks[@]}" 2>&1); then
  echo "$out" | tail -1
  echo "check-docs: OK"
  exit 0
fi

echo "$out"
echo
echo "check-docs: FAILED -- the block(s) above came from:" >&2
# Only the blocks the diagnostics actually named. Listing all of them buries
# the failure under every origin in the book, and the diagnostic does name the
# block's file, so a substring test on the basename finds the right ones.
# If nothing matches -- a `check` that failed without naming a file, say -- fall
# back to the full list rather than printing nothing.
found_all=0
for i in "${!blocks[@]}"; do
  if grep -qF "$(basename "${blocks[$i]}")" <<<"$out"; then
    echo "  $(basename "${blocks[$i]}")  <-  ${origins[$i]}" >&2
    found_all=1
  fi
done
if [ "$found_all" -eq 0 ]; then
  for i in "${!blocks[@]}"; do
    echo "  $(basename "${blocks[$i]}")  <-  ${origins[$i]}" >&2
  done
fi
exit 1
