#!/usr/bin/env bash
# cmd-parity.sh — assert every docker/compose.<slot>.yaml carries exactly the
# same server arguments as the corresponding CMD_<slot> array in
# docker/docker-llm-switch.
#
# Why this exists
# ───────────────
# There are now two places that describe how to launch a slot: the bash array
# that docker-llm-switch uses interactively, and the compose file that Komodo
# deploys. Duplication is the price of Komodo managing these as Stacks — a
# compose `command:` cannot reference a bash array.
#
# The failure this prevents is silent and slow: someone tunes --cache-ram or
# walks back --spec-draft-n-max in one place, the other keeps the old value,
# and the two paths quietly serve different models until somebody benchmarks
# them against each other and cannot explain the gap.
#
# 329 arguments across seven slots. Nobody is diffing that by eye.
#
# Usage:  docker/tests/cmd-parity.sh

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SWITCH="$REPO_DIR/docker/docker-llm-switch"
COMPOSE_DIR="$REPO_DIR/docker"

SLOTS=(coder architect gemma vision gptoss imagine comfyui)

rc=0
for slot in "${SLOTS[@]}"; do
  # Evaluate ONLY the array definitions, never the script body. CMD_<slot>
  # interpolates "${PORTS[<slot>]}", so PORTS has to come along.
  reference=$(
    { sed -n '/^declare -A PORTS=(/,/^)/p' "$SWITCH"
      sed -n "/^CMD_${slot}=(/,/^)/p" "$SWITCH"
      # Single quotes are required: this printf emits SOURCE CODE for the
      # inner bash below. Expanding ${CMD_...[@]} in this shell would read an
      # array that does not exist here and emit nothing.
      # shellcheck disable=SC2016
      printf 'printf "%%s\\n" "${CMD_%s[@]}"\n' "$slot"
    } | bash
  )

  if [ -z "$reference" ]; then
    printf 'FAIL: cmd-parity: could not extract CMD_%s from docker-llm-switch\n' "$slot" >&2
    rc=1
    continue
  fi

  actual=$(docker compose -f "$COMPOSE_DIR/compose.$slot.yaml" config --format json 2>/dev/null \
    | python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
command = list(services.values())[0].get("command") or []
print("\n".join(command))
')

  if [ "$reference" = "$actual" ]; then
    printf 'PASS: cmd-parity: %-10s %s args identical\n' "$slot" "$(printf '%s' "$reference" | grep -c '')"
  else
    printf 'FAIL: cmd-parity: %s differs between docker-llm-switch and compose.%s.yaml\n' "$slot" "$slot" >&2
    printf '  < docker-llm-switch   > compose file\n' >&2
    diff <(printf '%s\n' "$reference") <(printf '%s\n' "$actual") | sed 's/^/  /' >&2
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  printf '\nFAIL: cmd-parity: the two launch paths have drifted. Reconcile them before deploying.\n' >&2
fi
exit "$rc"
