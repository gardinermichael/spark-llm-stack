---
date: 2026-05-22
topic: open-ideation
focus: surprise-me — what's the highest-leverage next move for spark-llm-stack
mode: repo-grounded
---

# Ideation: spark-llm-stack — Highest-Leverage Next Moves

## Grounding Context

**Codebase Context** (warm from this session, not re-scanned):

- **Project shape:** systemd + Docker recipes for running llama.cpp on DGX Spark GB10. ~10 files, no test suite, no CI. Tooling lives in `llm-switch`, `docker-llm-switch`, `harden-llm-stack.sh`, `flux-gen`.
- **Strategy** (just-written `STRATEGY.md`): "curated cookbook of reproducible, parameterized recipes" — engine coverage / hardware tuning / operational ergonomics tracks. Four metrics including "Working recipes count" (uncomputed today) and "Perf gap vs best published Spark numbers" (unmeasured today).
- **Notable patterns & pain:** `CLAUDE.md` flags slot definitions live "in four parallel places that must stay in sync" (mirroring tax); `POSTMORTEM.md` documents an OOM-respawn brick loop that motivated all the hardening; `HANDOFF.md` notes image has never been built and recipe smoke-tests don't exist.
- **External grounding** (from earlier in this session): NVIDIA Spark llama.cpp forum thread, eugr/spark-vllm-docker, croll83/llama.cpp-dgx fork (NVFP4 + DFlash MTP, ~2× mainline), community benchmarks at 88–104 t/s on Qwen3.6 via vLLM+NVFP4+DFlash.

## Topic Axes

Decomposition skipped — surprise-me mode.

## Ranked Ideas

### 1. Manifest-driven cookbook (integrated move)

**Description:** Define each slot once in a single `slots.yaml` (model path, port, role, memory caps, engine, full CLI args). Code-generate the four currently-mirrored artifacts from it: the `*-mtp.service` unit, the `CMD_<slot>` array in `docker-llm-switch`, the `SERVICES=()` entry in `harden-llm-stack.sh`, and a generated section of the README's model roster. Add a `make generate` (or equivalent) gate in CI.

**Basis:** `direct:` from `/home/m/Dev/spark-llm-stack/CLAUDE.md`: "Each model slot is defined in **four parallel places** that must stay in sync when adding or changing a slot." Mirroring is the named pain.

**Rationale:** This is the single move that most directly serves STRATEGY's "Operational ergonomics" track and removes the highest-leverage source of drift bugs. Every other improvement (lockfile, recipe-test, benchmark CI) becomes easier once there's one source of truth to read from.

**Downsides:** Real upfront engineering (1–2 days). Generators must be written carefully — bad codegen creates a *new* class of bug (silently desynced output) on top of the manual one. Adds a build dependency (likely a small Python/Bash + jinja2 toolchain).

**Confidence:** 85%
**Complexity:** High
**Status:** Unexplored

---

### 2. Lockfile / pinned recipes (smallest reproducibility step)

**Description:** Replace `LLAMA_REF=master` default with a `lockfile.toml` listing the exact pinned commit per engine, the GGUF SHA per model slot, and the base-image digest. `docker build` and `docker-llm-switch` read from the lockfile by default; `make lock` (or `bin/refresh-lock`) regenerates with current upstream.

**Basis:** `direct:` from `/home/m/Dev/spark-llm-stack/STRATEGY.md` Target problem: "every OS wipe or engine swap means rediscovering [config] from scratch." `direct:` from `/home/m/Dev/spark-llm-stack/CLAUDE.md`: "Mainline llama.cpp currently underperforms on GB10 (~23 vs ~28 t/s)." Default `master` ships the slow path.

**Rationale:** Smallest possible unit of work that addresses the strategy's central "reproducible" commitment. Pays off the very next time the user (or anyone else) reinstalls the OS — the build is byte-identical instead of forum-archaeology-identical.

**Downsides:** Stale pins rot — needs a `refresh-lock` workflow or it becomes a fossil. Doesn't fix the four-place mirroring (that's idea #1).

**Confidence:** 90%
**Complexity:** Low
**Status:** Unexplored

---

### 3. Recipe-test harness

**Description:** A `bin/test-recipes` script that, on a clean Docker daemon, boots each slot in turn, polls `/health` until ready, runs a 200-token prompt, runs `llama-bench` for steady-state t/s, captures memory peak from `docker stats`, and writes a JSON report. Eventually wired into GitHub Actions on a Spark self-hosted runner.

**Basis:** `direct:` from `/home/m/Dev/spark-llm-stack/STRATEGY.md` metric: "Working recipes count — engines × model slots that boot cleanly on a fresh build. Measured by smoke-testing each slot after image rebuild." That metric is currently uncomputed; this idea is the measurement.

**Rationale:** Turns the most concrete strategy metric from aspirational into observed. Catches regressions the moment a llama.cpp upstream change breaks a slot. Acts as living documentation: "here's a slot that's known to boot."

**Downsides:** First-time model downloads are 50–70 GB each — full-matrix smoke-tests are slow and bandwidth-heavy. Mitigation: cache models on the runner, run smoke (just `/health`) on every commit and full-bench weekly.

**Confidence:** 85%
**Complexity:** Medium
**Status:** Unexplored

---

### 4. Public benchmark CI publishing GB10 numbers

**Description:** Self-hosted runner on the Spark runs `llama-bench` across slots × quants × llama.cpp commits, publishes a static page (GitHub Pages) and a Markdown table in README. Includes vLLM and the croll83 fork as comparison rows once their recipes exist. Each cell links to the exact build it came from.

**Basis:** `direct:` from `/home/m/Dev/spark-llm-stack/STRATEGY.md` metric: "Perf gap vs best published Spark numbers — t/s delta between this stack and the best-known public number." Today that gap is unmeasurable without spelunking forum threads. `external:` from prior-art research (NVIDIA forum benchmark threads, croll83 fork claims, dasroot.net 2026-05 article) — the community wants a single source of truth that doesn't exist.

**Rationale:** Closes the loop on a strategy metric AND turns the project into a destination that other Spark owners link to. Network effect: the more authoritative the numbers, the more PRs and forks land here, the more recipes exist, the more authoritative the numbers. Directly seeds idea #6.

**Downsides:** Requires the Spark to be a stable CI runner — competes with using it for actual work. Bench results are noisy without careful methodology (warm-up, clock-pinning, repeated runs). The `nvidia-smi -lgc` firmware caveat from eugr's repo matters here.

**Confidence:** 70%
**Complexity:** Medium
**Status:** Unexplored

---

### 5. Nix/Guix-style hermetic builds (radical reproducibility)

**Description:** Wrap the build in a Nix flake (or Guix package) so every artifact — llama.cpp binaries, GGUFs, container layers — is content-addressed and bit-reproducible. "Wipe the OS, run `nix build .#spark-llm-stack`, get byte-identical containers." Coexists with the current Docker path; doesn't replace it.

**Basis:** `reasoned:` Nix already has a CUDA overlay and llama.cpp expressions. The Spark-specific delta (`121a-real`, `KLEIDIAI`, `LD_LIBRARY_PATH=/usr/local/cuda-13/compat`) is small enough to upstream or maintain as a flake overlay. The "reproducible across OS wipes" claim of `STRATEGY.md` reaches its strongest form here — lockfile (#2) is partial reproducibility, Nix is the limit.

**Rationale:** A Nix recipe is genuinely portable: anyone with a Spark can `nix build` and skip the entire Docker layer. It's also the only path that yields *byte-identical* artifacts under STRATEGY's reproducibility claim.

**Downsides:** Nix is high-leverage but high-mental-overhead. Most Spark owners are not Nix users; this attracts a different community than Docker recipes do. Likely several days of work for the first flake to compile cleanly.

**Confidence:** 55%
**Complexity:** High
**Status:** Unexplored

---

### 6. Strategic positioning as canonical GB10 source

**Description:** Once #4 (public benchmark CI) is real, lean into it: open the recipes to community PRs (a `recipes/` directory with a clear schema), tag releases, link from forum posts back to the canonical numbers, accept GGUF/engine combos contributors care about. Effectively make spark-llm-stack the place GB10 owners check first when they need a recipe.

**Basis:** `reasoned:` The strategy persona ("DGX Spark owners, homelab / early-adopter devs") explicitly maps to the audience that lives on NVIDIA dev forums and GitHub. Every prior-art reference researched today (eugr, croll83, shamily, the official `.devops/spark.Dockerfile` thread) is fragmentary. There's an open lane for "the canonical place," and the path to it is "publish the numbers nobody else does."

**Rationale:** This is the long-horizon compounding move. Recipe count (a STRATEGY metric) becomes community-supplied instead of solo-authored. Each contributor PR is an externalized cost.

**Downsides:** Requires real maintainership commitment — a community-facing project demands triage time that the current "personal cookbook" framing doesn't. Premature if #4 isn't real first; the value depends on having something authoritative to host.

**Confidence:** 50%
**Complexity:** Meta (depends on #4 + low-effort scaffolding once #4 exists)
**Status:** Unexplored

---

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| R1 | `docker-llm-switch fetch <slot>` model auto-download subcommand | Below meeting-test floor — a 10-line shell function. Fits inside idea #1 (manifest) as a generator output rather than a standalone idea. |
| R2 | Partial-coexistence memory budgeting (allow vision + coder simultaneously) | POSTMORTEM was caused by accounting errors in exactly this kind of code. High complexity, low value for the single-Spark-owner persona. Brick risk asymmetric to upside. |
| R3 | "README is generated from recipe data" | Subsumed by idea #1 — once a manifest exists, generating the README index is a 20-line follow-up, not a separate idea. |
| R4 | Homebrew-formula-style DSL for community recipes | Duplicates idea #5 (Nix); Nix is the stronger version of the same idea. Defer until #5 has been tried and rejected for ergonomic reasons. |
| R5 | "No-Docker option" — pure systemd recipes side-by-side | Repo already supports both Docker and systemd today; not a gap. Manifest (#1) would naturally generate both. |
| R6 | Runtime A/B config-toggle experiments (`llm-switch experiment coder --top-k 40`) | Interesting but a feature inside the bench-CI work (#4); defer. Without #4 there's no measurement loop to A/B against. |
| R7 | Multi-Spark coordination (Tailscale-native llama.cpp distribution) | Subject-overrun against STRATEGY's single-Spark persona; eugr/spark-vllm-docker already covers the multi-node space. |
| R8 | Auto-bisect perf regressions on llama.cpp upstream changes | Strong idea but contained inside #4 (public benchmark CI) — once benchmarks run automatically, bisect is a thin script layer on top. Not a standalone move. |
