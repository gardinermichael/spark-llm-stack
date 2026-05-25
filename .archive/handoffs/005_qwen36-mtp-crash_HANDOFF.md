# Handoff: Disable MTP on coder slot (Qwen3.6-27B MTP head crash)

**Generated**: 2026-05-25
**Branch**: dev (clean, ahead of origin/dev by recent commits)
**Status**: Blocked on user approval — proposed edit identified, awaiting "go"

## Goal

Stop `spark-llm-coder` from crashing with `CUDA error: an illegal memory access` mid-conversation when Hermes drives it. Root cause is confirmed upstream as a Qwen3.6-27B MTP-head bug that fires at ~26-31k token context — reproducible in both llama.cpp and vLLM, so the fix is "disable MTP on coder," not engine-level.

## Completed (already committed)

- [x] Fixed silent-exit bug in `_apply_overrides` (while-loop body's last command was a failing `&&`, causing `set -e` to kill script after override match). Now uses `if/then/fi`.
- [x] Renamed `docker-llm-switch check`/`doctor` → `health` (aliases preserved). Added interactive remediation prompt that offers to run the relevant install scripts when something fails.
- [x] Added installed-file drift detection to `health`: compares `~/.local/bin/{docker-llm-switch,llm-switch,flux-gen}` (must be symlinks into repo) and `/usr/local/{lib,bin}/spark-{mem.sh,panic}` (must `cmp -s` match repo source).
- [x] Drift-remediation for user CLIs `rm -f`s the regular-file copies first so `install-user-cli.sh`'s "refuses to overwrite a regular file" safety doesn't block the auto-fix path.
- [x] Added `docker-llm-switch usage` subcommand (aliases: `tokens`, `top`) — live token/throughput watcher polling each running llama slot's `/metrics` Prometheus endpoint. LIVE table (Δ since last sample) + CUMULATIVE table (since container start) + ERRORS section (only shown when non-empty, harvests `docker logs -t --since` for lines matching `(error|errno|fatal|panic|segfault|abort|cuda error|out of memory|exception)`). Re-evaluates active slot list each frame; logs synthetic "container exited" line on running→absent transition; filters out `docker logs` CLI's own stderr.
- [x] Added `<slot> debug` and `<slot> logs` subcommands. `debug` starts the container *without* `--rm` and follows logs live, so a crashing container's logs survive for post-mortem.
- [x] README updated with all new commands.
- [x] **Diagnosed the actual crash**: CUDA illegal memory access in `common_speculative_impl_draft_mtp::process` → `llama_get_embeddings_pre_norm` → `ggml_backend_cuda_synchronize`. Triggers at ~30k context tokens. Confirmed via fresh mainline-master rebuild (same crash, same stack, same threshold).

## Not Yet Done

- [ ] **Apply the proposed `CMD_coder` edit** (see Code Context below) — user said "yes" earlier in spirit but I never made the edit before context ran out. **Do not commit without explicit user confirmation.**
- [ ] Update `CLAUDE.md` line 47 — the "Mainline llama.cpp currently underperforms on GB10 (~23 vs ~28 t/s)" note is stale post-May-16 MTP merge. Should mention current mainline includes MTP + the May 21 VRAM leak fix.
- [ ] Update `docker/Dockerfile` lines 8-13 perf warning for the same reason.
- [ ] Optional: search for an upstream patch/PR that adds a defensive guard when MTP draft acceptance saturates to 100% with `-1` scheduled tokens (the pre-crash signature in vLLM #40756). Not yet done — context ran out before I could WebFetch llama.cpp PRs.

## Failed Approaches (Don't Repeat These)

- **Resetting the `-c 65536` override to default `-c 131072`**: didn't help. Crashes still happen, just at a different request because the trigger is total context size at request time, not the `-c` cap.
- **Rebuilding the docker image on current mainline master (which has the May 21 VRAM-leak fix)**: didn't help. The mainline rebuild crashed identically — same stack trace, same MTP code path. So the May 21 fix is *not* this bug. Confirmed via fresh `docker compose build --no-cache llama` + restart + repro.
- **Hypothesis: "crash is MTP + checkpoint-restoration interaction"**: partially wrong. The fresh rebuild crashed on the *first* turn, with no checkpoint restoration involved, just after creating the initial checkpoint. The real trigger is total context size crossing ~30k tokens while MTP is active.
- **Hypothesis: hardware/memory issue**: ruled out. `journalctl -u earlyoom` and `dmesg` show no OOM events. Docker `event=die exitCode=133` = SIGTRAP = `__builtin_trap()` from CUDA assertion, not SIGKILL/OOM.

## Key Decisions

| Decision | Rationale |
|---|---|
| Drop MTP entirely on coder (not just lower `-ub` or disable checkpoints) | Cross-engine reproduction in vLLM #40756 proves the bug is in the model's MTP head, not any engine knob. Tuning around it would be guesswork. |
| Keep `architect` slot unchanged | `CMD_architect` does not use `--spec-type draft-mtp` — Qwen3.6-35B-A3B doesn't ship an MTP head. Unaffected by this bug. |
| Use `docker-llm-switch <slot> debug` for post-mortems instead of `--rm` everywhere | Default `--rm` is correct (POSTMORTEM OOM-respawn safety). `debug` is opt-in: same flags minus `--rm`, foreground log follow. |
| `health` interactive remediation prompts only on `-t 0 && -t 1` | Non-interactive sessions (CI, ssh -T) get a printed command list, not a blocking read. |

## Current State

**Working**:
- `docker-llm-switch` script syntax-valid (`bash -n`). All new subcommands (`health`, `usage`, `tokens`, `top`, `<slot> debug`, `<slot> logs`) functional based on read-through.
- Diagnosis is solid; upstream root cause cited.

**Broken**:
- `coder` slot crashes with `exitCode=133` SIGTRAP whenever a conversation crosses ~30k context tokens. Not fixed yet — only mitigation identified.

**Uncommitted Changes**: None. All session work was committed (5 commits on `dev`). The pending MTP-disable edit has *not* been made — that's the next action.

## Files to Know

| File | Why It Matters |
|---|---|
| `docker/docker-llm-switch` | Where the proposed edit goes. `CMD_coder` is at lines 126-142. MTP flags are lines 137-138. `--cache-reuse 1024` (silently disabled by MTP — log line confirms) is on line 133. |
| `docs/research/config_expansion/findings_mtp.md` | Repo's own notes citing PR #22673 (May 16 mainline merge) and the May 21 VRAM leak fix. Confirmed the user's pre-merge `~/src/llama.cpp-mtp` build was stale. |
| `CLAUDE.md` line 47 | Stale "Mainline underperforms ~23 vs ~28 t/s" note — predates the May 16 MTP merge. Worth refreshing after the user validates stability without MTP. |
| `docker/Dockerfile` lines 8-13 | Same stale perf warning, same note. |

## Code Context

### The exact edit to make in `docker/docker-llm-switch`

Current lines 126-142 (`CMD_coder`):

```bash
CMD_coder=(
  -m /models/Qwen3.6-27B-UD-Q4_K_XL.gguf
  --alias qwen3.6-27b-coder
  --host 0.0.0.0 --port "${PORTS[coder]}"
  -ngl 999 -fa on -c 131072
  --cache-type-k q8_0 --cache-type-v q8_0 --kv-unified
  --cache-ram 49152 --cache-idle-slots
  --ctx-checkpoints 128 --cache-reuse 1024
  -b 32768 -ub 8192 --parallel 1
  --threads 16 --threads-batch 24 --threads-http 4
  --prio 3 --poll 100
  --spec-type draft-mtp
  --spec-draft-n-max 5 --spec-draft-n-min 1 --spec-draft-p-min 0.75
  --reasoning off --jinja
  --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0.0
  --presence-penalty 0.0 --keep -1 --metrics --slots
)
```

**Proposed change**: remove the two MTP lines (137, 138) and `--cache-reuse 1024` (line 133 — silently disabled by MTP code path per log, but cleaner to drop it explicitly since we're removing the thing that disabled it). Replace with a comment block:

```bash
CMD_coder=(
  -m /models/Qwen3.6-27B-UD-Q4_K_XL.gguf
  --alias qwen3.6-27b-coder
  --host 0.0.0.0 --port "${PORTS[coder]}"
  -ngl 999 -fa on -c 131072
  --cache-type-k q8_0 --cache-type-v q8_0 --kv-unified
  --cache-ram 49152 --cache-idle-slots
  --ctx-checkpoints 128
  -b 32768 -ub 8192 --parallel 1
  --threads 16 --threads-batch 24 --threads-http 4
  --prio 3 --poll 100
  # MTP speculative decoding is DISABLED on coder due to an unfixed
  # upstream bug in the Qwen3.6-27B MTP head: CUDA illegal memory access
  # in common_speculative_impl_draft_mtp::process when total context
  # exceeds ~30k tokens. Reproduces in both llama.cpp and vLLM,
  # confirming the bug is in the model's MTP head, not the engine.
  # Re-enable after the upstream issue is fixed and a new GGUF is shipped.
  #   --spec-type draft-mtp
  #   --spec-draft-n-max 5 --spec-draft-n-min 1 --spec-draft-p-min 0.75
  # Tracking: https://github.com/vllm-project/vllm/issues/40756
  --reasoning off --jinja
  --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0.0
  --presence-penalty 0.0 --keep -1 --metrics --slots
)
```

### Crash signature (for matching against future bug reports)

```
/build/llama.cpp/ggml/src/ggml-cuda/ggml-cuda.cu:102: CUDA error
CUDA error: an illegal memory access was encountered
  current device: 0, in function ggml_backend_cuda_synchronize
ggml_backend_cuda_synchronize
  llama_context::synchronize
    llama_get_embeddings_pre_norm
      common_speculative_impl_draft_mtp::process(llama_batch)
```

Trigger: total context ≥ ~30k tokens while `--spec-type draft-mtp` is active. Docker reports `exitCode=133` (= 128 + signal 5 SIGTRAP from `__builtin_trap()`).

## Resume Instructions

1. **Confirm with the user**: "Make the `CMD_coder` MTP-disable edit now?" If yes, apply the diff shown in Code Context above.

2. **Install the edited script on the box** (user's DGX Spark):
   ```
   cp ~/Dev/spark-llm-stack/docker/docker-llm-switch ~/.local/bin/docker-llm-switch
   ```
   (Or run `docker-llm-switch health` and let the drift-remediation prompt re-symlink it — but they're equivalent since the file is now in the repo.)

3. **Bounce coder**:
   ```
   docker-llm-switch off
   docker-llm-switch coder
   docker-llm-switch coder logs --tail 30
   ```
   - Expected: startup log should NO LONGER contain `common_speculative_impl_draft_mtp: adding speculative implementation 'draft-mtp'`.
   - Expected: `cache_reuse is not supported by this context` warning should also be gone.

4. **Repro test**: have the user run the same Hermes prompt that crashed before.
   - Expected: no crash, generation completes. Generation t/s will drop from ~16 t/s (MTP-accelerated) to roughly similar — Qwen3.6-27B's MTP speedup wasn't huge on the user's workload anyway (n_max=5, ~89% acceptance, prompt-heavy).
   - Watch with `docker-llm-switch usage` to confirm throughput numbers and absence of ERRORS section.

5. **If stable** (≥1 full multi-turn conversation past 30k tokens with no crash):
   - Offer to commit the change. Suggested message: `fix(coder): disable MTP draft due to upstream Qwen3.6-27B MTP head bug`.
   - Offer to also update `CLAUDE.md:47` and `docker/Dockerfile:8-13` perf warning — both predate the May 16 mainline merge and are now misleading.

6. **If it still crashes** (would be surprising — the MTP code path is gone):
   - Get fresh `docker-llm-switch coder logs --tail 200`. The stack trace must not contain `common_speculative_impl_draft_mtp` anymore. If it does, the edit didn't actually take effect (check install step). If it doesn't, this is a different bug entirely — get the new stack trace.

## Setup Required

Nothing new. The DGX Spark already has:
- `docker-llm-switch` symlinked into `~/.local/bin/` via `tools/install-user-cli.sh` (assumed; verify with `docker-llm-switch health` if uncertain).
- `Qwen3.6-27B-UD-Q4_K_XL.gguf` in `~/models/`.
- `spark-llm-stack` docker image built (the user rebuilt fresh on mainline master during the session).

## Warnings

- **Do not commit the `CMD_coder` edit without explicit user approval.** They were leaning yes but the session ended on the question, not the answer.
- The user is on DGX Spark GB10 (aarch64) with 128 GiB unified memory and the OOM-respawn-brick-loop history documented in `gremlins/00_POSTMORTEM.md`. `--rm` on heavyweight containers is intentional — do not remove it from the normal run path. The `debug` subcommand adds an opt-in escape hatch.
- The user uses `rtk` (Rust Token Killer) for compact CLI output. Don't be surprised by `[rtk] WARNING` lines in tool output — they're benign filter-loader notices.
- The pre-merge `~/src/llama.cpp-mtp/build/bin/llama-server` referenced in systemd `.service` files is also stale. If/when the user switches the systemd path off the pre-merge branch, the systemd CMD lines also need the MTP flags removed for the same reason. (Out of scope for this handoff; the Docker path is the active deployment.)
- `--cache-reuse 1024` was being silently disabled by MTP per the log line `cache_reuse is not supported by this context, it will be disabled`. Without MTP, it would become active. The proposed edit drops it because it was never tested in this stack with MTP off. If the user wants to keep it for performance, that's a separate decision — flag it.

---

## Resolution (2026-05-25)

Mitigation applied in commit `3b431a4` (FP16 KV + `--spec-draft-n-max 2`),
then bumped to `n_max=3` for throughput recovery in commit `40fdf61`. Coder
slot is stable through real long-context workloads past the 30k cliff.

The full incident record — including the troubleshooting walk-through, the
stale-binary trap that masked the first validation, and the queued next-step
levers (hybrid KV, drop `--kv-unified`, lower `--ctx-checkpoints`, disable
MTP entirely) — lives in
[`gremlins/02_QWEN36-27B-MTP-CUDA-CRASH.md`](../../gremlins/02_QWEN36-27B-MTP-CUDA-CRASH.md).
Read that, not this handoff, when the gremlin recurs.

Upstream is still open: vLLM #40756, llama.cpp #23264, #23322.
