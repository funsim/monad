#!/usr/bin/env bash
# Enforce commit message format: "scope: msg", "scope/sub: msg", or
# "scope/sub(type): msg" (matches existing convention, e.g. "codegen: ...",
# "lang/scope: ...", "core/term/module: ...").
#
# Exempt: the messages git generates itself -- "Merge ...", "Revert ...", and
# the "fixup! "/"squash! "/"amend! " prefixes from `git commit --fixup` and
# friends. See the `case` below for why each is exempt rather than rewritten.
#
# Wired in as a git commit-msg hook via devenv.nix's git-hooks.hooks, but
# runs standalone too:
#   ./scripts/check-commit-msg.sh <path-to-commit-msg-file>
set -euo pipefail

msg_file="$1"
first_line="$(head -n1 "$msg_file")"

# Messages git itself generates, which cannot carry a scope and must not be
# rewritten to fake one.
#
# `fixup!`/`squash!`/`amend!` are what `git commit --fixup/--squash` writes: the
# subject is the TARGET commit's, verbatim, so demanding a scope here would mean
# hand-editing a line `git rebase --autosquash` matches on -- and a edited one no
# longer matches, which silently turns an autosquash into an ordinary commit.
# Nested forms (`fixup! fixup! ...`, produced by `--fixup` against a fixup) are
# covered for free: the prefix glob only looks at the start.
#
# The scope still gets enforced where it matters. A fixup is not a commit that
# survives -- `--autosquash` folds it into its target, whose own message already
# passed this hook. If one reaches `main` unsquashed, that is a rebase that was
# not run, not a message this hook should have caught.
case "$first_line" in
  "Merge "*|"Revert "*|"fixup! "*|"squash! "*|"amend! "*)
    exit 0
    ;;
esac

pattern='^[a-zA-Z][a-zA-Z0-9_-]*(\([a-zA-Z][a-zA-Z0-9_-]*\))?\!?(/[a-zA-Z0-9_-]+)*(\([a-zA-Z0-9_-]+\))?: .+'

if ! printf '%s' "$first_line" | grep -qE "$pattern"; then
  echo "Commit message must start with 'scope: ', 'scope/sub: ', or 'scope/sub(type): ' (got: '$first_line')" >&2
  exit 1
fi
