#!/usr/bin/env bash
# check-image.sh — refuse to deploy when an image the stack needs is not
# present locally.
#
# Why this exists
# ───────────────
# These images are built out of band by `docker compose -f
# docker/docker-compose.yml build` and exist in no registry. The per-slot
# stacks therefore declare no `build:` section — five slots share one image,
# and letting each stack rebuild it would rebuild the same layers five times.
#
# The consequence is that nothing in the deploy path creates a missing image.
# `auto_pull` is false (it must be: a pull would fail with "pull access denied
# for spark-llm-stack, repository does not exist", which reads like an auth
# problem and is not). So a missing image surfaces late, as a confusing
# container-create error.
#
# This guard turns that into an early, accurate message naming the build
# command. Same role as check-image.sh in the Pi's mcps stack, for the same
# reason: an image built outside the stack needs a guard inside it.
#
# Usage:  scripts/check-image.sh <compose-file>

set -euo pipefail

fail() { printf 'FAIL: check-image: %s\n' "$*" >&2; exit 1; }

COMPOSE_FILE="${1:-}"
[ -n "$COMPOSE_FILE" ] || fail "no compose file given; usage: check-image.sh <compose-file>"

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if ! model=$(cd "$REPO_DIR" && docker compose -f "$COMPOSE_FILE" config --format json 2>&1); then
  printf 'FAIL: check-image: %s did not render:\n' "$COMPOSE_FILE" >&2
  printf '%s\n' "$model" | sed 's/^/  /' >&2
  exit 1
fi

missing=0
while IFS= read -r image; do
  [ -z "$image" ] && continue
  if docker image inspect "$image" >/dev/null 2>&1; then
    printf 'PASS: check-image: %s is present locally\n' "$image"
  else
    printf 'FAIL: check-image: %s is not present locally and nothing will pull it\n' "$image" >&2
    missing=$(( missing + 1 ))
  fi
done < <(printf '%s' "$model" | python3 -c '
import json, sys
model = json.load(sys.stdin)
seen = []
for svc in (model.get("services") or {}).values():
    img = svc.get("image")
    if img and img not in seen:
        seen.append(img)
for img in seen:
    print(img)
')

if [ "$missing" -gt 0 ]; then
  printf 'FAIL: check-image: build the images first:\n' >&2
  printf '  docker compose -f docker/docker-compose.yml build\n' >&2
  exit 1
fi
