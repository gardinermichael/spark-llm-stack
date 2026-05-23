# Build tuning — what's GB10, what's just speed

This note exists because the `docker/Dockerfile` builder stage has two
distinct sets of choices that are easy to confuse:

1. **GB10 / SM 12.1 performance tuning** — cmake `-D` flags.
2. **Build-set vs install-set bookkeeping** — `--target`, `cmake --install`,
   `LLAMA_BUILD_*` knobs.

They live next to each other in one `RUN` block and look superficially
similar, but only group (1) affects what the resulting binary can do.
Group (2) only affects how long the builder stage takes and how robust it
is to llama.cpp upstream churn.

---

## Group 1 — GB10 tuning (do not touch without measuring)

| Flag | What it does |
|---|---|
| `-DCMAKE_CUDA_ARCHITECTURES="121a-real"` | Emits native SASS for SM 12.1 (GB10). Without the `a-real` suffix you get generic PTX, which JIT-compiles on every model load (slow first request, sometimes silent perf regression). See [`CLAUDE.md`](../CLAUDE.md). |
| `-DGGML_NATIVE=ON` | Host-CPU `-march=native`. Picks up Grace's ARM v9 features. |
| `-DGGML_CPU_KLEIDIAI=ON` | Arm KleidiAI kernels for Neoverse cores — the CPU-side matmul library Grace targets. |
| `-DGGML_CUDA=ON` | Enables the CUDA backend at all. |
| `-DGGML_CUDA_FA=ON` + `-DGGML_CUDA_FA_ALL_QUANTS=ON` | Flash attention kernels, all quant types. |
| `-DGGML_CUDA_FORCE_MMQ=ON` | Forces the matmul-quant kernel path on Blackwell (faster than the generic int8 path for our workloads). |
| `-DGGML_CURL=ON` | llama-server needs libcurl to download GGUFs on demand (`-hf <repo>:<file>`). |

These are the ones that matter for tokens/sec. Apply to *every* target the
builder produces — they're translation-unit flags, not target filters.

## Group 2 — build/install bookkeeping (the part this doc is about)

The Dockerfile currently uses:

```cmake
cmake -B build … -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build           # builds the full ALL target
cmake --install build         # installs everything install() rules declare
```

This is the **stable but slightly slow** posture. The pre-2026-05-23
Dockerfile used a narrower `--target llama-server llama-bench` plus
hand-picked `COPY --from=builder` lines, which was faster but missed
shared libraries (`libllama-server-impl.so`) and broke whenever upstream
moved the shared lib to a different filename.

### Why we don't filter targets right now

Each time we narrow `--target`, the corresponding `cmake --install` either:

- Installs nothing matching the targets we asked for (because llama.cpp's
  `install()` rules aren't gated on target presence), OR
- Tries to install files whose targets we filtered out, and aborts on the
  first missing file.

Disabling whole subdirectories at configure time (`LLAMA_BUILD_TESTS=OFF`,
`LLAMA_BUILD_EXAMPLES=OFF`) makes cmake **not generate install rules** for
those subdirs in the first place — which is the only filter that
composes cleanly with `cmake --install`.

### Cost of the current posture

The builder stage compiles a few extra small CLI tools under `tools/`
(quantize, gguf-split, perplexity, etc.) that are never invoked at
runtime. They add **~30–60 s** to the builder stage on a fast box and a
handful of MB to `/install`, which then end up in the runtime image.

### When to revisit

- If `docker compose build llama` is on the critical path for an iteration
  loop and the extra minute hurts.
- If a future llama.cpp release adds a heavy build target under
  `tools/` (e.g. a new training utility) that doubles the builder stage.
- If the runtime image grows past a threshold you care about.

---

## Prompt: have a model derive a minimal filter

When you do want to revisit, paste the prompt below into any
coding-capable model (Claude, Codex, Gemini, etc.) with this repo
mounted. The prompt is self-contained — it tells the model the
constraints, the verification gate, and the structured output format
expected.

```text
You are working in the spark-llm-stack repo. Your task: minimise the
llama.cpp builder stage in docker/Dockerfile without breaking the
runtime image.

CONTEXT
- docker/Dockerfile builds llama.cpp from upstream source in a multi-stage
  build, then runs `cmake --install build` and `COPY --from=builder
  /install /usr/local` into the runtime stage.
- Currently the builder configures with -DLLAMA_BUILD_TESTS=OFF and
  -DLLAMA_BUILD_EXAMPLES=OFF, builds the full ALL target, and installs
  everything cmake knows how to install.
- The runtime image only invokes /usr/local/bin/llama-server at runtime
  (see ENTRYPOINT). llama-bench is shipped but only run by humans for
  ad-hoc perf checks.
- docker/BUILD-TUNING.md "Group 1" lists flags that MUST NOT change —
  they're GB10-specific perf tuning, orthogonal to your task.

GOAL
- Reduce builder-stage wall-clock time on a clean build (no buildkit cache).
- Maintain: /usr/local/bin/llama-server present and runnable; ldd reports
  no missing shared libraries; curl /health returns {"status":"ok"} after
  starting the coder slot.

CONSTRAINTS
- Do not touch any flag in BUILD-TUNING.md's Group 1 table.
- Do not switch llama.cpp branches or pin a different LLAMA_REF.
- Do not introduce per-file COPY --from=builder lines — they regressed
  in commit 0cc8457 because shared library names drift upstream.
- Keep the failure mode loud: if cmake --install produces no
  llama-server binary, the build must fail at the builder stage with
  a clear error, not as a cryptic COPY cache-key error downstream.

APPROACH (suggested, not prescribed)
1. Inspect upstream llama.cpp CMakeLists for available LLAMA_BUILD_* knobs
   at the LLAMA_REF currently pinned.
2. Identify the smallest subset of subdirectories needed for llama-server
   + llama-bench + the libraries they link against (libllama, libggml-*,
   libmtmd if vision is in play).
3. Propose a diff to docker/Dockerfile that disables the rest at configure
   time. Do not use --target unless paired with subdir disables that make
   the install set match.
4. Run a clean build twice — once before the diff, once after — and
   report wall-clock for the `RUN cmake -B build … && cmake --install`
   layer specifically. Use:
     docker build --no-cache --target builder -f docker/Dockerfile -t bench-llama-builder .
5. Smoke-test the resulting runtime image:
     docker build --no-cache -f docker/Dockerfile -t bench-llama .
     docker run --rm --gpus=all -p 8152:8152 -v ~/models:/models bench-llama &
     # poll /health until ready, then kill
6. Revert and try the next narrower configuration if smoke passes.
   Stop narrowing once a configuration breaks /health or a smoke step.

OUTPUT (required exactly, end of reply)
- A markdown ## Report section with: chosen flags, before/after timings,
  image size delta, list of files added/removed from /install, smoke-test
  pass/fail.
- Final line must be a single JSON object on one line, no fences:
  {"flags_added":["..."],"flags_removed":["..."],"builder_seconds_before":NNN,"builder_seconds_after":NNN,"image_bytes_before":NNN,"image_bytes_after":NNN,"smoke_passed":true|false}

Do not modify files outside docker/Dockerfile and docker/BUILD-TUNING.md
without explaining why in the report.
```

The trailing JSON line is for ingestion: a parent agent can read the
final line, decide whether to accept the diff, and roll the rest of the
report into a commit message or PR body.

### What "minimal filter" looks like

A good result lands one of these shapes:

- `-DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF` plus an additional
  knob the model discovers (e.g. `-DLLAMA_BUILD_COMMON=OFF` if upstream
  introduces one, or disabling specific tools under `tools/` via a knob
  upstream adds).
- A `--target` list combined with subdir disables that line up exactly,
  verified by reading `build/install_manifest.txt` after `cmake --install`
  and confirming every entry is in fact built.

A bad result the prompt should *not* produce:

- Hand-picked `COPY --from=builder /build/.../bin/foo` lines. We tried
  that. Upstream renames break it silently.
- Disabling `LLAMA_BUILD_TOOLS` — llama-server lives there.
- Stripping `-DGGML_CURL=ON` to "save time" — breaks `-hf` downloads.

---

## Verification one-liners

If you change anything in the builder stage by hand, run these before
pushing:

```bash
# Clean build, builder stage only — should finish without errors
docker build --no-cache --target builder -f docker/Dockerfile -t bench-llama-builder .

# Full image
docker build --no-cache -f docker/Dockerfile -t bench-llama .

# llama-server exists and links
docker run --rm --entrypoint /usr/bin/ldd bench-llama /usr/local/bin/llama-server | grep -i "not found" && echo "BAD: missing shared libs" || echo "OK: linkage clean"

# Health check (needs ~/models populated)
docker run -d --name bench-llama-test --gpus=all -p 8152:8152 -v ~/models:/models bench-llama
for i in {1..60}; do
  curl -sf http://127.0.0.1:8152/health && echo " — ready in ${i}s" && break
  sleep 1
done
docker rm -f bench-llama-test
```
