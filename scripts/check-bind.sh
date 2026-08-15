#!/usr/bin/env bash
# check-bind.sh — refuse to deploy a compose file that exposes a service
# anywhere but loopback.
#
# Why this exists
# ───────────────
# Every slot's server process binds 0.0.0.0 inside its own container, which is
# correct and must stay that way. What matters is where the HOST publishes it.
# The pre-Komodo runtime used `--network=host`, so `--host 0.0.0.0` landed
# directly on every host interface — LAN and tailnet included. Moving to
# published loopback ports is the fix; this guard is what keeps it fixed.
#
# Two traps this guard exists to catch, both verified against
# `docker compose config --format json` on Compose v5.0.2:
#
#   1. A wildcard bind OMITS host_ip entirely — it does not report "0.0.0.0".
#      So the test must be `host_ip == 127.0.0.1`, asserted positively. A
#      check written as `host_ip != "0.0.0.0"` passes "8153:8153" and is worse
#      than useless, because it looks like it is working.
#
#   2. A service with `network_mode: host` emits NO ports key at all. A guard
#      that only walks ports waves it straight through while it binds every
#      interface. Host networking is therefore rejected outright.
#
# Usage:  scripts/check-bind.sh <compose-file> [<compose-file> ...]

set -euo pipefail

fail() { printf 'FAIL: check-bind: %s\n' "$*" >&2; exit 1; }

[ "$#" -ge 1 ] || fail "no compose file given; usage: check-bind.sh <compose-file> [...]"

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for compose_file in "$@"; do
  [ -f "$REPO_DIR/$compose_file" ] || [ -f "$compose_file" ] \
    || fail "compose file not found: $compose_file"

  # Resolve the model the way Komodo will: from the run directory, with -f.
  # `config` performs full interpolation, so this sees the same bytes the
  # deploy would, including anything an .env file changed.
  if ! model=$(cd "$REPO_DIR" && docker compose -f "$compose_file" config --format json 2>&1); then
    printf 'FAIL: check-bind: %s did not render:\n' "$compose_file" >&2
    printf '%s\n' "$model" | sed 's/^/  /' >&2
    exit 1
  fi

  printf '%s' "$model" | COMPOSE_FILE_LABEL="$compose_file" python3 -c '
import json, os, sys

compose_file = os.environ["COMPOSE_FILE_LABEL"]
model = json.load(sys.stdin)
problems = []

# Loopback in both families. A bare "*" or "" is Compose spelling a wildcard.
ALLOWED_HOST_IPS = {"127.0.0.1", "::1"}

for name, svc in sorted((model.get("services") or {}).items()):
    if svc.get("network_mode") == "host":
        problems.append(
            f"service {name!r} uses network_mode: host, so the container binds "
            f"host interfaces directly and publishes nothing this guard can check"
        )
        continue

    for entry in svc.get("ports") or []:
        published = entry.get("published")
        target = entry.get("target")
        host_ip = entry.get("host_ip")
        if host_ip is None:
            problems.append(
                f"service {name!r} publishes {published}->{target} with no host_ip, "
                f"which is a wildcard bind on every interface"
            )
        elif host_ip not in ALLOWED_HOST_IPS:
            problems.append(
                f"service {name!r} publishes {published}->{target} on {host_ip}, "
                f"which is not loopback"
            )

if problems:
    print(f"FAIL: check-bind: {compose_file}:", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    sys.exit(1)

published = sum(len(s.get("ports") or []) for s in (model.get("services") or {}).values())
print(f"PASS: check-bind: {compose_file}: {published} published port(s), all loopback")
'
done
