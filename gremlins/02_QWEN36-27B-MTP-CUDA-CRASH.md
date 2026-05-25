# DGX Spark LLM Stack — Incident Report

**Incident:** `coder` slot (Qwen3.6-27B + MTP speculative decoding) crashes
with CUDA "illegal memory access" once context grows past ~30k tokens.
Container exits with code 133 (SIGTRAP from `__builtin_trap()` in CUDA
assertion).
**Hardware:** DGX Spark GB10 (Grace Blackwell, aarch64, SM 12.1, 128 GiB
unified memory). Engine: llama.cpp (both pre-merge `llama.cpp-mtp` branch and
post-merge mainline reproduce the crash identically). Model:
`Qwen3.6-27B-UD-Q4_K_XL.gguf` with MTP head.
**Severity:** High — `coder` slot dies mid-conversation under normal coding
workloads (any session that accumulates >30k context). Hermes / clients see
`APIConnectionError` and `No such container` because the container `--rm`'d
itself.
**Status:** Open upstream. Mitigated locally via workarounds (see below). No
edit has been applied to `docker/docker-llm-switch` yet pending decision on
which workaround stack to adopt.

---

## Summary

After a normal load and a few requests, the `coder` container dies with
`exitCode=133` (`128 + 5` = SIGTRAP). The llama-server log shows a CUDA
illegal-memory-access stack trace originating in
`common_speculative_impl_draft_mtp::process` →
`llama_get_embeddings_pre_norm` → `ggml_backend_cuda_synchronize`. The
crash is reproducible on a fresh mainline-master build (post the
[2026-05-21 MTP VRAM-leak fix](https://github.com/ggml-org/llama.cpp/issues/23395)
landing), proving that fix is unrelated.

This is **not** an OOM (`earlyoom` / `journalctl -k` show 96 GiB free at the
moment of crash). It is **not** a GB10-specific bug — vLLM users on discrete
NVIDIA GPUs hit the same crash with the same model
([vLLM #40756](https://github.com/vllm-project/vllm/issues/40756)). The bug
sits in the **Qwen3.6 MTP head's interaction with sliding-window attention
(SWA) when the KV cache slides**, not in the engine. Two engines, same model,
same crash signature.

Pre-crash log signature is consistent across reports: MTP draft acceptance
saturates to **100%** with **`-1` scheduled tokens** in the slot stats — the
draft state has desynced from the main model's KV cache, and the next
checkpoint write reaches into invalidated memory.

---

## Root cause

```
factor                                                  category         severity
──────────────────────────────────────────────────────  ───────────────  ────────
1. Qwen3.6 uses SWA / hybrid recurrent memory; KV       upstream model   HIGH
   entries are invalidated when the window slides
2. MTP draft state caches embeddings that point into    upstream engine  HIGH
   those KV entries; after SWA invalidation the draft
   references freed regions
3. Acceptance counter saturates artificially to 100%    symptom          —
   ("-1 scheduled tokens") because the draft is reading
   stale data that always matches itself
4. Next --ctx-checkpoints write into the now-fragmented context-checkpoint HIGH
   draft pool dereferences invalid GPU memory →
   `cudaErrorIllegalAddress` → `__builtin_trap()` → 133
5. `--cache-reuse` and `--kv-unified` accelerate the    config           MEDIUM
   condition (more aggressive KV reuse across slides)
6. Higher `--spec-draft-n-max` widens the draft window  config           MEDIUM
   and makes the desync more likely per step
```

The same root cause is described from two angles in upstream:

- [llama.cpp #23322](https://github.com/ggml-org/llama.cpp/issues/23322)
  documents the SWA / hybrid-memory invalidation and the "acceptance saturates
  to 100%" precursor.
- [llama.cpp #23264](https://github.com/ggml-org/llama.cpp/issues/23264)
  documents the crash itself — `draft-mtp` ILM at a checkpoint write after
  the context-memory pool is exhausted / fragmented.
- [vLLM #40756](https://github.com/vllm-project/vllm/issues/40756) is the
  cross-engine reproduction confirming the bug is model-side, not engine-side.

---

## How the failure looked

llama-server log (excerpted from a real crash):

```
slot launch_slot_: id  0 | task  N | processing task
…
slot update_slots: id  0 | task N | n_past = 30912, n_tokens = 8192
common_speculative_impl_draft_mtp::process: acceptance 100% (scheduled = -1)
…
ggml_backend_cuda_synchronize: CUDA error: an illegal memory access was encountered
  current device: 0, in function ggml_backend_cuda_synchronize at …/ggml-cuda.cu:NNNN
  cudaDeviceSynchronize()
GGML_ASSERT(!"CUDA error") failed
[1]    PID trace trap (core dumped)  llama-server …
```

`docker events` shows the death:

```
2026-05-25T… container die spark-llm-coder (exitCode=133, execDuration=89)
2026-05-25T… container destroy spark-llm-coder      # because --rm
```

Client side (Hermes):

```
docker logs spark-llm-coder
Error response from daemon: No such container: spark-llm-coder

openai.APIConnectionError: Connection error.
```

`earlyoom` log and `journalctl -k --since` show **no** OOM event in the same
window — this is a CUDA crash, not memory pressure.

---

## Remediations / Workarounds

**No upstream fix exists** as of 2026-05-25. Both vLLM #40756 and llama.cpp
#23264 are open. The [2026-05-21 mainline MTP VRAM-leak fix](https://github.com/ggml-org/llama.cpp/issues/23395)
is a different bug and does not help.

Rank-ordered mitigations (combine until stable; each addresses a different
contributing factor):

### 1. Lower `--spec-draft-n-max` from 5 → 2

Smallest change, narrows the draft horizon so per-step desync is less likely.
[Unsloth's Qwen3.6 MTP GGUF discussion #3](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/discussions/3)
recommends this as the first lever.

Trade-off: lower speculative speedup. Effectively brings MTP closer to vanilla
decode throughput.

### 2. Drop `--cache-reuse` and `--kv-unified`

`--cache-reuse` is the trigger for the SWA-invalidation chain in #23322;
`--kv-unified` increases the surface for cross-slot KV sharing. Note that the
current `CMD_coder` log already shows MTP silently disabling `--cache-reuse`
internally, so removing it has no functional cost.

Trade-off: slightly slower prefix-cache hits on long conversations.

### 3. Switch KV cache to FP16

Change `--cache-type-k q8_0 --cache-type-v q8_0` → `--cache-type-k f16
--cache-type-v f16` (or even FP16 weights + Q8 KV). Multiple community reports
([dredyson writeup](https://dredyson.com/how-i-solved-the-mtpllama-cpp-qwen3-6-27b-performance-and-stability-problems-complete-step-by-step-fix-guide-for-beginners/),
[unsloth discussion #3](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/discussions/3))
say FP16 KV eliminates the crash entirely.

Trade-off: ~2× KV cache VRAM. On 128 GiB UMA with 96 GiB free at crash this is
affordable.

### 4. Cap `--ctx-checkpoints` to 8 (down from 128)

Per #23264 the crash lands during a checkpoint write after pool fragmentation.
Fewer checkpoints → less fragmentation pressure.

Trade-off: less prefix-reuse on long sessions.

### 5. Keep `--parallel 1`

Already set in `CMD_coder`. Don't raise it — removes draft/verify race
conditions during checkpoint writes.

### 6. Cap context below the cliff (`-c 28672`)

Crude but reliable. Several users on r/LocalLLaMA report stable operation
indefinitely with `-c 28672`. Only use if (1)–(4) combined still aren't
stable.

Trade-off: hard ceiling on coding sessions; ~30k tokens fills quickly with a
large repo.

### Fallback: disable MTP entirely

If all of the above still crash, remove `--spec-type draft-mtp` and the three
`--spec-draft-*` flags. This is the **only guaranteed fix** until upstream
patches land. Vanilla decode on Qwen3.6-27B-Q4 is ~18–20 t/s on GB10 vs.
~28 t/s with MTP working — a meaningful loss but tolerable.

### Recommended starting stack for GB10

Apply (1) + (2) + (3) together. That addresses both the SWA-invalidation root
cause (#23322) and the checkpoint-pool exhaustion (#23264) at once without
giving up MTP. If still unstable, add (4). Disable MTP only if all four fail.

Concrete diff for `docker/docker-llm-switch` `CMD_coder` (NOT YET APPLIED):

```diff
   --cache-type-k q8_0 --cache-type-v q8_0 --kv-unified
-  --cache-ram 49152 --cache-idle-slots
-  --ctx-checkpoints 128 --cache-reuse 1024
+  --cache-type-k f16 --cache-type-v f16
+  --cache-ram 49152 --cache-idle-slots
+  --ctx-checkpoints 128
   -b 32768 -ub 8192 --parallel 1
   --threads 16 --threads-batch 24 --threads-http 4
   --prio 3 --poll 100
   --spec-type draft-mtp
-  --spec-draft-n-max 5 --spec-draft-n-min 1 --spec-draft-p-min 0.75
+  --spec-draft-n-max 2 --spec-draft-n-min 1 --spec-draft-p-min 0.75
```

(Also remove `--kv-unified` if combining all of (1)+(2)+(3); the diff above
shows the minimal change keeping `--kv-unified` for users who want to drop
only the highest-impact knobs.)

---

## Troubleshooting log

Chronological record of what was tried on this host. Read this before trying
"obvious" mitigations — several of them were already proven insufficient.

1. **First hypothesis: OOM.** Symptom (container exits, "no such container"
   on `docker logs`) initially looked like an OOM-kill plus `--rm` tear-down.
   Checked `journalctl --user -u earlyoom` and `journalctl -k --since '15 min
   ago' | grep -iE 'oom|killed process'` — both empty, 96 GiB free in
   `free -g` at the crash timestamp from `docker events`. **Ruled out.**

2. **Second hypothesis: stale pre-merge MTP branch.** Service files point at
   `%h/src/llama.cpp-mtp/build/bin/llama-server`, which predates the mainline
   MTP merge (2026-05-16, PR #22673) and the [VRAM-leak fix](https://github.com/ggml-org/llama.cpp/issues/23395)
   (2026-05-21). Rebuilt llama.cpp from mainline-master post-leak-fix, ran the
   same model with the same flags. **Crashed identically at the same ~30k
   boundary.** Ruled out — the May 21 leak fix is a different bug.

3. **Third hypothesis: GB10-specific (aarch64 / SM 12.1).** Searched upstream
   for matching reports. Found [vLLM #40756](https://github.com/vllm-project/vllm/issues/40756)
   on discrete NVIDIA GPUs with the same model and same crash signature.
   Cross-engine, cross-arch reproduction → **bug is in the Qwen3.6 MTP head,
   not in llama.cpp or in GB10**. Ruled out.

4. **Identified root cause via upstream:** [llama.cpp #23322](https://github.com/ggml-org/llama.cpp/issues/23322)
   documents the Qwen3.6 SWA → KV invalidation → MTP draft desync chain, with
   "acceptance saturates to 100% / scheduled = -1" as the leading indicator.
   [llama.cpp #23264](https://github.com/ggml-org/llama.cpp/issues/23264)
   documents the crash itself at the next checkpoint write. Confirmed our
   pre-crash logs match both signatures.

5. **Applied (2026-05-25): FP16 KV + `--spec-draft-n-max 2`.** Kept
   `--kv-unified` and `--cache-reuse 1024` for now. Reasoning: FP16 KV is the
   highest-evidence community workaround (multiple independent reports of full
   stability); reducing draft horizon is the lowest-cost first lever.
   Committed in `3b431a4`. **Verification pending on hardware.**

6. **Next step if step 5 fails:** drop `--cache-reuse 1024` and `--kv-unified`
   per #23322's analysis of KV-reuse-across-SWA-slide as the trigger.

7. **Next step after that:** add `--ctx-checkpoints 8` (down from 128).

8. **Last resort:** disable MTP entirely (remove `--spec-type draft-mtp` and
   the three `--spec-draft-*` flags). The only guaranteed fix. Loses ~30%
   throughput on coder.

## Lessons learned

1. **Cross-engine reproduction is strong evidence of model-side bugs.** When
   vLLM and llama.cpp both crash the same model the same way at the same
   threshold, stop debugging the engine.

2. **MTP acceptance saturation to 100% is a leading indicator, not a feature.**
   If draft acceptance suddenly pins at 100% with `-1` scheduled tokens, the
   draft state has desynced — a crash within the next few requests is likely.
   This is worth surfacing in `docker-llm-switch usage`.

3. **Exit code 133 is a CUDA assertion, not OOM.** `128 + 5 = SIGTRAP`, raised
   by `__builtin_trap()` inside a `GGML_ASSERT` after `cudaDeviceSynchronize`
   returns an illegal-address error. Always check `journalctl -k` for an OOM
   line before assuming it's a memory issue — its absence rules OOM out.

4. **`--rm` containers destroy their own forensic state.** The
   `<slot> debug` / `<slot> logs` subcommands added to `docker-llm-switch`
   exist specifically because once a `--rm` container dies, `docker logs`
   returns "no such container". Capture logs proactively when crashes are
   intermittent.

---

## Useful diagnostic commands

```bash
# Was the death an OOM or a CUDA crash?
journalctl --user -u earlyoom --since '15 min ago'
journalctl -k --since '15 min ago' | grep -iE 'oom|killed process|out of memory'
# Empty + exitCode=133 in docker events = CUDA crash, not OOM.

# Get the precise exit code and timing
docker events --since '30 min ago' --filter container=spark-llm-coder

# Capture the last few hundred lines of the crashed container (use the
# subcommand we added; works after the --rm tear-down via journalctl).
docker-llm-switch coder logs
docker-llm-switch coder debug

# Watch acceptance saturation in real time (precursor of crash)
docker-llm-switch usage
# Look for: spec_acceptance climbing to 100% and pinning there.

# Confirm engine version (the May 21 leak fix is irrelevant to this bug)
docker exec spark-llm-coder llama-server --version
```

---

## Sources

- [vLLM #40756 — MTP ILM on long sequences (Qwen3.6-27B-FP8)](https://github.com/vllm-project/vllm/issues/40756) — canonical upstream issue; cross-engine reproduction.
- [llama.cpp #23264 — `draft-mtp` crash, context-memory pool exhaustion](https://github.com/ggml-org/llama.cpp/issues/23264) — matches our stack trace exactly.
- [llama.cpp #23322 — Low MTP acceptance with SWA / hybrid memory (Qwen3.6)](https://github.com/ggml-org/llama.cpp/issues/23322) — root-cause analysis: SWA invalidates KV, MTP desyncs.
- [llama.cpp #23395 — MTP VRAM-not-freed (the 2026-05-21 leak fix)](https://github.com/ggml-org/llama.cpp/issues/23395) — *not* this bug; documented here to prevent confusion.
- [vLLM #41190 — TP=2 MTP ILM at `num_accepted_tokens_event.synchronize`](https://github.com/vllm-project/vllm/issues/41190) — sibling report, same family.
- [vLLM #36613 — MTP ILM under high concurrency (Qwen3.5)](https://github.com/vllm-project/vllm/issues/36613) — older sibling on Qwen3.5-MoE.
- [unsloth/Qwen3.6-35B-A3B-MTP-GGUF — discussion #3 (workaround thread)](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/discussions/3) — community-recommended `--spec-draft-n-max` reduction.
- [dredyson — "How I solved the MTP/llama.cpp Qwen3.6-27B stability problems"](https://dredyson.com/how-i-solved-the-mtpllama-cpp-qwen3-6-27b-performance-and-stability-problems-complete-step-by-step-fix-guide-for-beginners/) — FP16-KV workaround writeup.

Upstream state last verified: **2026-05-25**. Re-check the two llama.cpp
issues (#23264, #23322) and vLLM #40756 before changing the workaround stack;
a real fix would land in one of those threads.
