---
name: spark-llm-stack
last_updated: 2026-05-22
---

# spark-llm-stack Strategy

## Target problem

Bringing up high-performance LLM inference on a DGX Spark is a config-archaeology
tax: GB10 is ARM64 + SM 12.1 + CUDA 13 with new firmware, so generic deployment
guides don't apply, and the working knowledge is scattered across NVIDIA forum
threads, GitHub forks, and Discord posts. Every OS wipe or engine swap means
rediscovering it from scratch.

## Our approach

A curated cookbook of reproducible, parameterized recipes for the DGX Spark —
engine-agnostic (llama.cpp now, vLLM and others later), with every cmake flag
and runtime knob visible — so other people's hard-won config compounds instead
of evaporating. Transparent and swappable, not opinionated and hidden like
single-engine wrappers.

## Who it's for

**Primary:** DGX Spark owners (homelab / early-adopter devs) — they're hiring
spark-llm-stack to turn the Spark into a known-good inference server over their
existing network, whether that's first-day boot-up, swapping engines for better
t/s, or hosting a personal coding LLM on the Tailnet.

## Key metrics

- **Perf per quant** — tokens/sec at each quant level, per model. Measured via `llama-bench` and steady-state server logs.
- **OOM / brick incidents per month** — target zero. Measured via `journalctl --list-boots` and OOM kernel events; founding incident is POSTMORTEM.md.
- **Working recipes count** — engines × model slots that boot cleanly on a fresh build. Measured by smoke-testing each slot after image rebuild.
- **Perf gap vs. best published Spark numbers** — t/s delta between this stack and the best-known public number (MTP fork, croll83 fork, vLLM+NVFP4). Keeps the cookbook honest about which engine to recommend.

## Tracks

### Engine coverage

Recipes for the inference engines worth running on GB10 — llama.cpp + MTP today;
vLLM, the croll83 DGX fork, and stable-diffusion.cpp / ComfyUI as separate
images on the roadmap.

_Why it serves the approach:_ The cookbook is engine-agnostic by design; without
multiple engines it's just a llama.cpp wrapper.

### Hardware tuning

The GB10-specific config surface: cmake flags (`121a-real`, `KLEIDIAI`, FA-all-quants),
CUDA env vars (`CUDA_SCALE_LAUNCH_QUEUES`, graph-opt), unified-memory flag bans
(`--no-mmap`, `--mlock`), `LD_LIBRARY_PATH` compat shim, OOM safeguards.

_Why it serves the approach:_ This is the hard-won config the cookbook exists to
preserve — every value here is a forum thread someone else doesn't have to read.

### Operational ergonomics

The day-to-day UX around the recipes: `llm-switch` / `docker-llm-switch` slot
management with mutual exclusion, boot-state safety, health polling, Tailscale
exposure, and the `*-switch boot-status` pre-reboot check.

_Why it serves the approach:_ A cookbook nobody can run is just a list. The
ergonomics layer makes the recipes usable on a Tuesday without re-reading the
README every time.
