#!/usr/bin/env bash
# check-deploy-ref.sh — refuse to deploy from a stale or dirty run directory.
#
# Why this exists
# ───────────────
# Komodo Stacks configured `files_on_host = true` deploy whatever is checked
# out at the instant the operator presses Deploy. Nothing reconciles that
# working tree with the remote. So a deploy from a stale checkout silently
# ships code nobody reviewed, reverts merged work, and *reports success* —
# the worst failure shape there is, because nothing looks wrong.
#
# This runs FIRST in every pre_deploy chain. Order is deliberate: a wrong
# branch explains more failures than anything downstream of it, and "the bind
# is not loopback" is a confusing symptom of a branch problem.
#
# Usage:  scripts/check-deploy-ref.sh <expected-ref>
#
# Note on scope: this checks the LOCAL ref and cleanliness only. It does not
# fetch. Comparing against a remote-tracking ref without a fetch would compare
# against a snapshot of unknown age and report "up to date" when it is not —
# a check that lies is worse than no check.

set -euo pipefail

fail() { printf 'FAIL: check-deploy-ref: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: check-deploy-ref: %s\n' "$*"; }

EXPECTED_REF="${1:-}"
[ -n "$EXPECTED_REF" ] || fail "no expected ref given; usage: check-deploy-ref.sh <expected-ref>"

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Komodo Periphery runs as root; this run directory belongs to the operator.
# Git treats mismatched ownership as "dubious" and REFUSES outright rather
# than degrading, so every git call below carries -c safe.directory.
#
# Do NOT "fix" a future ownership error by adding safe.directory to root's
# ~/.gitconfig. That leaves host state behind that no file in this repository
# owns, and it silently widens the exemption to every repo root ever touched.
git_() { git -c "safe.directory=$REPO_DIR" -C "$REPO_DIR" "$@"; }

git_ rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "$REPO_DIR is not a git work tree"

# A detached HEAD reports the literal string "HEAD", which will not match any
# real branch name, so this comparison rejects it without a special case.
branch=$(git_ rev-parse --abbrev-ref HEAD)
[ "$branch" = "$EXPECTED_REF" ] \
  || fail "run directory is on '$branch' but this stack deploys '$EXPECTED_REF'; deploying would ship the wrong code"

# --porcelain reports untracked files by default. That is intentional: an
# untracked compose fragment or a stray override is exactly the kind of thing
# that makes a deploy unreproducible.
dirty=$(git_ status --porcelain)
if [ -n "$dirty" ]; then
  printf 'FAIL: check-deploy-ref: run directory has uncommitted or untracked changes:\n' >&2
  printf '%s\n' "$dirty" | sed 's/^/  /' >&2
  exit 1
fi

pass "on '$branch', working tree clean ($(git_ rev-parse --short HEAD))"
