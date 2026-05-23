#!/usr/bin/env bash
# spark-llm-stack docker smoke tests
#
# Single-file, dependency-light runner. Every subcommand prints PASS/FAIL
# per check, accumulates failures, and exits non-zero if anything failed.
#
# Usage:
#   docker/tests/smoke.sh all                 # everything (slow; spins slots up)
#   docker/tests/smoke.sh static              # bash -n, compose lint, ctx-size parity
#   docker/tests/smoke.sh bad-ref             # ensure typo refs fail builds
#   docker/tests/smoke.sh slots               # mutual exclusion across all slots
#   docker/tests/smoke.sh health <slot>       # wait for readiness, hit /health
#   docker/tests/smoke.sh prompt <slot>       # send a chat completion, verify
#   docker/tests/smoke.sh flux                # FLUX submit-poll-decode end-to-end
#   docker/tests/smoke.sh comfyui             # ComfyUI /system_stats + lib checks
#   docker/tests/smoke.sh hardening <slot>    # docker inspect parity (mem, oom, net)
#   docker/tests/smoke.sh bench <slot>        # llama-bench inside the running container
#
# Exit codes:
#   0  — all checks in the run passed
#   1  — at least one check failed
#   2  — usage error / missing dependency

set -uo pipefail

# ─── config ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

declare -A PORTS=(
    [coder]=8152 [architect]=8154 [vision]=8155 [gemma]=8156 [gptoss]=8157
    [imagine]=8160 [comfyui]=8188
)
declare -A ALIAS=(
    [coder]="qwen3.6-27b-coder"
    [architect]="qwen3.6-35b-architect"
    [vision]="gemma4-vision"
    [gemma]="gemma4-31b"
    [gptoss]="gpt-oss-20b"
)
declare -A MEMCAP_GB=(
    [coder]=80 [architect]=80 [gemma]=80 [vision]=20 [gptoss]=40
    [imagine]=16 [comfyui]=40
)
LLAMA_SLOTS=(coder architect vision gemma gptoss)
READY_TIMEOUT_DEFAULT=180

# ─── output helpers ───────────────────────────────────────────────────────────
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

FAIL_COUNT=0
PASS_COUNT=0
SKIP_COUNT=0

section() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$RESET"; }
pass()    { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail()    { printf '  %sFAIL%s %s\n' "$RED"   "$RESET" "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
skip()    { printf '  %sSKIP%s %s\n' "$YELLOW" "$RESET" "$1"; SKIP_COUNT=$((SKIP_COUNT+1)); }
info()    { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }

# assert <description> <command...>  — runs the command, PASS on 0, FAIL otherwise.
assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc  ($DIM$*$RESET)"
    fi
}

# refute <description> <command...> — opposite of assert.
refute() {
    local desc="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc  (command unexpectedly succeeded: $*)"
    fi
}

# require_cmd <cmd>  — exit 2 if missing.
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '%serror:%s required command not found: %s\n' "$RED" "$RESET" "$1" >&2
        exit 2
    fi
}

# wait_for_url <url> <timeout> <description> — polls every 2s.
wait_for_url() {
    local url="$1" timeout="${2:-$READY_TIMEOUT_DEFAULT}" desc="${3:-readiness}" t=0
    while (( t < timeout )); do
        if curl -sfo /dev/null "$url"; then
            pass "$desc  (ready in ${t}s)"
            return 0
        fi
        sleep 2
        t=$((t+2))
    done
    fail "$desc  (timeout after ${timeout}s waiting on $url)"
    return 1
}

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed -n '/^# Usage:/,/^#$/p'
    exit 2
}

# ─── 1. static checks ─────────────────────────────────────────────────────────
cmd_static() {
    section "Static checks (no hardware)"
    require_cmd docker

    assert "bash -n docker/run.sh"                    bash -n docker/run.sh
    assert "bash -n docker/docker-llm-switch"         bash -n docker/docker-llm-switch
    assert "bash -n docker/comfyui/entrypoint.sh"     bash -n docker/comfyui/entrypoint.sh
    assert "bash -n systemd/llm-switch"               bash -n systemd/llm-switch
    assert "bash -n systemd/harden-llm-stack.sh"      bash -n systemd/harden-llm-stack.sh
    assert "bash -n systemd/install-earlyoom-failsafe.sh" bash -n systemd/install-earlyoom-failsafe.sh
    assert "bash -n systemd/install-drop-caches-sudoers.sh" bash -n systemd/install-drop-caches-sudoers.sh
    assert "bash -n tools/install-user-cli.sh"        bash -n tools/install-user-cli.sh

    assert "docker compose config validates" \
        docker compose -f docker/docker-compose.yml config

    # Context-size parity: every "-c <N>" in docker-llm-switch should appear
    # for the same slot in the matching systemd unit. Heuristic check —
    # produces a warning, not a failure, since slot names don't map 1:1.
    if grep -hE -- '-c +[0-9]+' docker/docker-llm-switch >/tmp/smoke-ctx-docker 2>/dev/null \
    && grep -hE -- '-c +[0-9]+' systemd/units/*.service >/tmp/smoke-ctx-systemd 2>/dev/null; then
        info "ctx-size lines (compare manually):"
        info "$(paste -d' | ' /tmp/smoke-ctx-docker /tmp/smoke-ctx-systemd | head -10)"
    fi
}

# ─── 2. bad-ref regression: typo'd build args MUST fail ───────────────────────
cmd_bad_ref() {
    section "Bad-ref regression — typo'd refs must fail"
    refute "Dockerfile rejects LLAMA_REF=no-such-ref" \
        docker build -f docker/Dockerfile --build-arg LLAMA_REF=no-such-ref --target builder .
    refute "sd-server rejects SD_REF=no-such-ref" \
        docker build -f docker/sd-server/Dockerfile --build-arg SD_REF=no-such-ref --target builder .
    refute "comfyui rejects COMFYUI_REF=no-such-ref" \
        docker build -f docker/comfyui/Dockerfile --build-arg COMFYUI_REF=no-such-ref .
}

# ─── 3. mutual exclusion ──────────────────────────────────────────────────────
running_spark_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^spark-llm-' || true
}

assert_one_slot_running() {
    local expected="spark-llm-$1"
    local got
    got="$(running_spark_containers | tr '\n' ' ')"
    if [[ "$(echo "$got" | wc -w)" -eq 1 && "$got" == "$expected "* ]]; then
        pass "only $expected running  ($(echo "$got" | xargs))"
    else
        fail "expected only $expected, got: $(echo "$got" | xargs)"
    fi
}

cmd_slots() {
    section "Mutual exclusion + slot startup"
    require_cmd docker-llm-switch

    for slot in coder architect imagine comfyui; do
        info "switching to $slot..."
        if ! docker-llm-switch "$slot" >/dev/null 2>&1; then
            fail "docker-llm-switch $slot exited non-zero"
            continue
        fi
        assert_one_slot_running "$slot"
    done

    info "switching off..."
    docker-llm-switch off >/dev/null 2>&1 || true
    if [[ -z "$(running_spark_containers)" ]]; then
        pass "no spark-llm-* containers after 'off'"
    else
        fail "containers still running after 'off': $(running_spark_containers | xargs)"
    fi
}

# ─── 4. readiness + health ────────────────────────────────────────────────────
cmd_health() {
    local slot="${1:?slot required}"
    local port="${PORTS[$slot]:-}"
    [[ -n "$port" ]] || { fail "unknown slot: $slot"; return; }

    section "Health: $slot (port $port)"
    require_cmd docker-llm-switch
    require_cmd curl

    info "starting $slot..."
    docker-llm-switch "$slot" >/dev/null 2>&1 \
        || { fail "docker-llm-switch $slot failed"; return; }

    case "$slot" in
        comfyui)  wait_for_url "http://127.0.0.1:$port/system_stats" 240 "$slot /system_stats" ;;
        imagine)  wait_for_url "http://127.0.0.1:$port/sdcpp/v1/capabilities" 120 "$slot capabilities" ;;
        *)        wait_for_url "http://127.0.0.1:$port/health" 180 "$slot /health"
                  assert "$slot advertises a model on /v1/models" \
                      bash -c "curl -sf http://127.0.0.1:$port/v1/models | grep -q '\"id\"'"
                  ;;
    esac
}

# ─── 5. prompt round-trip (llama slots only) ──────────────────────────────────
cmd_prompt() {
    local slot="${1:?slot required}"
    local port="${PORTS[$slot]:-}"
    local model_alias="${ALIAS[$slot]:-}"
    [[ -n "$port" && -n "$model_alias" ]] || { fail "$slot is not a chat slot"; return; }

    section "Prompt round-trip: $slot"
    require_cmd curl; require_cmd jq

    # Snapshot FAIL_COUNT so we can detect failures from THIS health call
    # specifically — a global "FAIL_COUNT > 0" check would skip the prompt
    # test for every subsequent slot in `cmd_all` after the first failure.
    local fails_before=$FAIL_COUNT
    cmd_health "$slot"
    [[ $FAIL_COUNT -gt $fails_before ]] && return  # this slot's health failed

    local body
    body=$(jq -n --arg m "$model_alias" \
        '{model:$m, max_tokens: 32, messages:[{role:"user", content:"Reply with the single word: pong"}]}')

    local resp
    resp="$(curl -s -m 60 -X POST "http://127.0.0.1:$port/v1/chat/completions" \
        -H "Content-Type: application/json" -d "$body")"

    if [[ -z "$resp" ]]; then
        fail "$slot returned empty response"
        return
    fi

    if echo "$resp" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
        local content; content=$(echo "$resp" | jq -r '.choices[0].message.content')
        pass "$slot chat completion returned content (${#content} chars)"
        info "response snippet: ${content:0:80}"
    else
        fail "$slot chat completion has no .choices[0].message.content"
        info "got: $(echo "$resp" | head -c 200)"
    fi

    # /v1/models shape sanity — use jq's `any` so the test is order-independent
    # (`.data[]?.id == X` would only pass if the *last* element matched).
    assert "$slot /v1/models includes alias '$model_alias'" \
        bash -c "curl -sf http://127.0.0.1:$port/v1/models | jq -e --arg a \"$model_alias\" 'any(.data[]?; .id == \$a)' >/dev/null"
}

# ─── 6. FLUX submit-poll round-trip ───────────────────────────────────────────
cmd_flux() {
    section "FLUX submit-poll-decode"
    require_cmd curl; require_cmd jq; require_cmd base64; require_cmd docker-llm-switch

    info "starting imagine..."
    docker-llm-switch imagine >/dev/null 2>&1 || { fail "docker-llm-switch imagine failed"; return; }
    wait_for_url "http://127.0.0.1:8160/sdcpp/v1/capabilities" 120 "imagine capabilities" || return

    local job
    job=$(curl -s -m 30 -X POST http://127.0.0.1:8160/sdcpp/v1/img_gen \
        -H "Content-Type: application/json" \
        -d '{
          "prompt": "smoke test pattern",
          "width": 256, "height": 256, "batch_count": 1, "seed": 42,
          "sample_params": {"sample_steps": 2, "sample_method": "euler",
            "guidance": {"txt_cfg": 1.0, "distilled_guidance": 3.5}}
        }' | jq -r '.id // empty')

    if [[ -z "$job" ]]; then
        fail "FLUX img_gen did not return a job id"
        return
    fi
    pass "FLUX accepted submission (job=$job)"

    local status t=0
    while (( t < 60 )); do
        status=$(curl -sf "http://127.0.0.1:8160/sdcpp/v1/jobs/$job" | jq -r '.status // "unknown"')
        case "$status" in completed|failed|cancelled) break;; esac
        sleep 1; t=$((t+1))
    done
    if [[ "$status" == "completed" ]]; then
        pass "FLUX job completed (${t}s)"
    else
        fail "FLUX job ended status=$status"
        return
    fi

    local png; png="$(mktemp -t flux-smoke-XXXX.png)"
    if ! curl -sf "http://127.0.0.1:8160/sdcpp/v1/jobs/$job" \
        | jq -r '.result.images[0].b64_json' | base64 -d > "$png" 2>/dev/null \
        || [[ ! -s "$png" ]]; then
        fail "FLUX result decoded to empty file"
        return
    fi
    # Verify it's actually a PNG, not a base64-decoded JSON error blob.
    if file -b "$png" 2>/dev/null | grep -q '^PNG image'; then
        pass "FLUX produced a valid PNG  ($(wc -c <"$png") bytes, $png)"
    else
        fail "FLUX result is not a PNG  (file says: $(file -b "$png" 2>/dev/null | head -c 80))"
    fi
}

# ─── 7. ComfyUI ───────────────────────────────────────────────────────────────
cmd_comfyui() {
    section "ComfyUI smoke"
    require_cmd docker; require_cmd docker-llm-switch; require_cmd curl

    docker-llm-switch comfyui >/dev/null 2>&1 || { fail "docker-llm-switch comfyui failed"; return; }
    wait_for_url "http://127.0.0.1:8188/system_stats" 240 "comfyui /system_stats" || return

    # GB10 patches should announce themselves in logs.
    if docker logs spark-llm-comfyui 2>&1 | grep -qE 'aimdo|DynamicVRAM'; then
        pass "comfy-aimdo / DynamicVRAM banner present in logs"
    else
        fail "comfy-aimdo / DynamicVRAM banner missing — GB10 unified-memory patch may not have applied"
    fi

    if docker logs spark-llm-comfyui 2>&1 | grep -qi 'sageattention'; then
        pass "SageAttention initialised"
    else
        skip "SageAttention banner not seen in logs (may have rolled, check manually)"
    fi
}

# ─── 8. hardening parity ──────────────────────────────────────────────────────
cmd_hardening() {
    local slot="${1:?slot required}"
    section "Hardening parity: $slot"
    require_cmd docker

    local name="spark-llm-$slot"
    if ! docker inspect "$name" >/dev/null 2>&1; then
        fail "$name is not running (start it first with: docker-llm-switch $slot)"
        return
    fi

    local network oom mem expected_bytes
    network=$(docker inspect "$name" --format '{{.HostConfig.NetworkMode}}')
    oom=$(docker inspect "$name" --format '{{.HostConfig.OomScoreAdj}}')
    mem=$(docker inspect "$name" --format '{{.HostConfig.Memory}}')
    expected_bytes=$(( ${MEMCAP_GB[$slot]} * 1024 * 1024 * 1024 ))

    [[ "$network" == "host" ]]   && pass "NetworkMode=host" \
                                 || fail "NetworkMode=$network (expected host)"
    [[ "$oom"     == "200"  ]]   && pass "OomScoreAdj=200"  \
                                 || fail "OomScoreAdj=$oom (expected 200)"
    [[ "$mem"     == "$expected_bytes" ]] && pass "Memory=${MEMCAP_GB[$slot]}g  ($mem bytes)" \
                                          || fail "Memory=$mem bytes (expected $expected_bytes, ${MEMCAP_GB[$slot]}g)"
}

# ─── 9. llama-bench inside the container ──────────────────────────────────────
cmd_bench() {
    local slot="${1:-coder}"
    local n_gen="${2:-128}"
    section "Bench: $slot (n_gen=$n_gen, reps=3)"
    require_cmd docker

    local name="spark-llm-$slot"
    if ! docker ps --format '{{.Names}}' | grep -q "^$name$"; then
        fail "$name not running — start with: docker-llm-switch $slot"
        return
    fi

    # Extract the model path from the running container's command line.
    local model
    model=$(docker inspect "$name" --format '{{range .Config.Cmd}}{{println .}}{{end}}' \
        | grep -E '\.gguf$' | head -1)
    if [[ -z "$model" ]]; then
        skip "$slot does not load a GGUF via -m (gptoss uses --gpt-oss-20b-default)"
        return
    fi
    info "model: $model"

    # llama-bench has its own perf flags; mirror ExecStart's compute knobs but
    # avoid sampling args (bench doesn't generate via sampler).
    info "running llama-bench (this stops the server while it runs)..."
    docker exec "$name" /usr/local/bin/llama-bench \
        -m "$model" -ngl 999 -fa 1 -t 8 -p 512 -n "$n_gen" --reps 3 \
        || { fail "llama-bench exited non-zero"; return; }
    pass "bench completed for $slot"
}

# ─── 10. run-everything ───────────────────────────────────────────────────────
cmd_all() {
    cmd_static
    cmd_slots
    for slot in "${LLAMA_SLOTS[@]}"; do
        cmd_prompt "$slot"
        cmd_hardening "$slot"
    done
    cmd_flux
    cmd_comfyui
}

# ─── dispatch ─────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        static)     cmd_static "$@" ;;
        bad-ref)    cmd_bad_ref "$@" ;;
        slots)      cmd_slots "$@" ;;
        health)     cmd_health "$@" ;;
        prompt)     cmd_prompt "$@" ;;
        flux)       cmd_flux "$@" ;;
        comfyui)    cmd_comfyui "$@" ;;
        hardening)  cmd_hardening "$@" ;;
        bench)      cmd_bench "$@" ;;
        all)        cmd_all "$@" ;;
        ""|-h|--help) usage ;;
        *)          printf '%serror:%s unknown subcommand: %s\n' "$RED" "$RESET" "$cmd" >&2
                    usage ;;
    esac

    printf '\n%s%d passed, %d failed, %d skipped%s\n' \
        "$BOLD" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$RESET"
    [[ $FAIL_COUNT -eq 0 ]]
}

main "$@"
