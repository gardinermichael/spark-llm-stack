#!/usr/bin/env bash
# check-gpu-slot.sh — admission gate for an exclusive GPU slot.
#
# Why this exists
# ───────────────
# DGX Spark has 128 GB of LPDDR5X shared by CPU and GPU. Per
# docker/lib/spark-mem.sh, Docker's --memory flags and cgroup memory.max do
# NOT enforce against CUDA allocations, which go through /dev/nvidia-uvm and
# bypass cgroup reclaim. The mem_limit in a compose file is documentation.
#
# So starting a second heavyweight slot does not get throttled — it exhausts
# the pool and starves the kernel, which is the OOM brick loop in
# gremlins/00_POSTMORTEM.md. Komodo has no anti-affinity between Stacks and
# will happily deploy two, reporting both green.
#
# Primary defence is therefore a Komodo Procedure that destroys the peer
# stacks before deploying this one, declared in the komodo repository. THIS
# guard is defence-in-depth: it catches an operator who clicks Deploy on the
# Stack directly, bypassing the Procedure.
#
# What it reads
# ─────────────
# Everything comes from the resolved compose model of the stack being
# deployed — container name, weight class, and projected memory. There is
# deliberately no slot table duplicated here: a second copy of MEMCAP would
# drift from docker/docker-llm-switch and the drift would be invisible until
# the day it mattered.
#
# Known limitation, stated rather than papered over
# ─────────────────────────────────────────────────
# pre_deploy runs as its own process, so the flock acquired here is released
# when this script exits — BEFORE `compose up` runs. Two operators deploying
# simultaneously can still race. Single-operator use is safe; the Procedure
# path is the one that keeps Komodo's own view of state correct.
#
# Usage:  scripts/check-gpu-slot.sh <compose-file>

set -euo pipefail

fail() { printf 'FAIL: check-gpu-slot: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: check-gpu-slot: %s\n' "$*"; }
pass() { printf 'PASS: check-gpu-slot: %s\n' "$*"; }

COMPOSE_FILE="${1:-}"
[ -n "$COMPOSE_FILE" ] || fail "no compose file given; usage: check-gpu-slot.sh <compose-file>"

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Prefer the installed copy: it is what earlyoom's -N hook and spark-panic
# resolve, so using the same file means the guard and the failsafe cannot
# disagree about what "exclusive" means. Fall back to the repo copy for a
# checkout where install-earlyoom-failsafe.sh has not been run.
for candidate in /usr/local/lib/spark-mem.sh "$REPO_DIR/docker/lib/spark-mem.sh"; do
  if [ -r "$candidate" ]; then
    # shellcheck source=/dev/null
    . "$candidate"
    SPARK_MEM_LIB="$candidate"
    break
  fi
done
[ -n "${SPARK_MEM_LIB:-}" ] || fail "spark-mem.sh not found in /usr/local/lib or $REPO_DIR/docker/lib"

if ! model=$(cd "$REPO_DIR" && docker compose -f "$COMPOSE_FILE" config --format json 2>&1); then
  printf 'FAIL: check-gpu-slot: %s did not render:\n' "$COMPOSE_FILE" >&2
  printf '%s\n' "$model" | sed 's/^/  /' >&2
  exit 1
fi

# Emits four lines: container name, slot, weight, projected bytes. Reading
# these from the artifact keeps this script honest about what is deploying.
readarray -t facts < <(printf '%s' "$model" | python3 -c '
import json, sys

model = json.load(sys.stdin)
services = model.get("services") or {}

names, slots, weights, total = [], set(), set(), 0
for svc in services.values():
    labels = svc.get("labels") or {}
    if labels.get("spark.exclusive") != "true":
        continue
    if svc.get("container_name"):
        names.append(svc["container_name"])
    if labels.get("spark.slot"):
        slots.add(labels["spark.slot"])
    weights.add(labels.get("spark.weight") or "unlabelled")
    try:
        total += int(svc.get("mem_limit") or 0)
    except (TypeError, ValueError):
        pass

# Any unlabelled or heavy member makes the whole stack heavy. Erring toward
# heavy costs an unnecessary eviction; erring toward light bricks the host.
weight = "light" if weights and weights == {"light"} else "heavy"

print(names[0] if names else "")
print(sorted(slots)[0] if slots else "")
print(weight)
print(total)
')

CONTAINER_NAME="${facts[0]:-}"
SLOT="${facts[1]:-unknown}"
WEIGHT="${facts[2]:-heavy}"
PROJECTED_BYTES="${facts[3]:-0}"

[ -n "$CONTAINER_NAME" ] || fail "no service in $COMPOSE_FILE carries spark.exclusive=true with a container_name; the failsafe in $SPARK_MEM_LIB finds its targets by that label, so an unlabelled container is invisible to spark-panic"

# spark_parse_gb accepts a bare byte count, so the compose model's resolved
# mem_limit feeds straight in without a second unit convention.
PROJECTED_GB=$(spark_parse_gb "$PROJECTED_BYTES")

info "slot=$SLOT weight=$WEIGHT container=$CONTAINER_NAME projected=${PROJECTED_GB}GiB"

# ── idempotency short-circuit ────────────────────────────────────────────────
#
# Mirrors docker-llm-switch:2006-2011. If the target is already up, this is an
# "ensure up" call and no new memory is about to be claimed. Running the gate
# anyway would evict in-flight cross-stack workloads to make room for a
# container that already exists.
if [ -n "$(docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null)" ]; then
  pass "$CONTAINER_NAME is already running; no admission needed"
  exit 0
fi

spark_acquire_lock || fail "another spark switch is in progress; refusing to race it"

# ── evict conflicting heavyweights ───────────────────────────────────────────
#
# Only heavy-vs-heavy conflicts force an eviction, matching class_conflict at
# docker-llm-switch:423-442. The light slots coexist by design.
#
# A running container with no spark.weight label predates this convention —
# docker-llm-switch does not set it — so it is counted as heavy. That is the
# safe direction to be wrong in.
if [ "$WEIGHT" = "heavy" ]; then
  evicted=0
  while IFS=$'\t' read -r other other_weight; do
    [ -z "$other" ] && continue
    [ "$other" = "$CONTAINER_NAME" ] && continue
    [ "$other_weight" = "light" ] && continue
    info "evicting conflicting heavyweight: $other (weight=${other_weight:-unlabelled})"
    docker update --restart=no "$other" >/dev/null 2>&1 || true
    docker stop -t 30 "$other" >/dev/null 2>&1 || true
    evicted=$(( evicted + 1 ))
  done < <(docker ps --filter "label=${SPARK_EXCLUSIVE_LABEL}" \
                     --format '{{.Names}}'$'\t''{{.Label "spark.weight"}}' 2>/dev/null)
  [ "$evicted" -gt 0 ] && info "evicted $evicted conflicting container(s)"
fi

# Ordering is deliberate and matches docker-llm-switch:2021-2024: flush the
# buffer cache BEFORE measuring, or admission is judged against 8-20 GiB of
# reclaimable page cache that MemAvailable already counts but the operator's
# intuition does not.
spark_drop_caches

if ! spark_admission_check "$PROJECTED_GB"; then
  info "insufficient memory for $SLOT (${PROJECTED_GB}GiB); stopping remaining cross-stack containers"
  spark_cross_stack_stop_others "$CONTAINER_NAME"
  spark_drop_caches
  spark_admission_check "$PROJECTED_GB" \
    || fail "still cannot fit ${PROJECTED_GB}GiB for $SLOT after stopping every exclusive container; refusing to deploy rather than risk the OOM brick loop"
fi

# ── pre-create bind sources with the right owner ─────────────────────────────
#
# Reproduces the mkdir at docker-llm-switch:504, generically. If a bind source
# is missing, the daemon creates it as root; the operator then cannot write to
# their own ComfyUI output directory. Periphery runs this as root, so create
# and chown to whoever owns the run directory.
run_dir_owner=$(stat -c '%u:%g' "$REPO_DIR")
while IFS= read -r src; do
  [ -z "$src" ] && continue
  case "$src" in /*) ;; *) continue ;; esac
  [ -e "$src" ] && continue
  info "creating missing bind source $src (owner $run_dir_owner)"
  mkdir -p "$src"
  chown "$run_dir_owner" "$src" 2>/dev/null || true
done < <(printf '%s' "$model" | python3 -c '
import json, sys
model = json.load(sys.stdin)
for svc in (model.get("services") or {}).values():
    for vol in svc.get("volumes") or []:
        if vol.get("type") == "bind" and vol.get("source"):
            print(vol["source"])
')

pass "$SLOT admitted: ${PROJECTED_GB}GiB fits"
