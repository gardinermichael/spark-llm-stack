---
date: 2026-05-22
topic: spark-llm-leaderboard
---

# Spark LLM Leaderboard (Public Benchmark CI)

## Summary

A self-hosted GitHub Actions bench runner on the project maintainer's DGX Spark publishes a public leaderboard of model + configuration × throughput-and-quality. The initial slice covers coder-class models on llama.cpp with one quality eval; the contributor JSON result schema is designed so federated submissions from other Spark owners land alongside the runner's numbers without rework. Contributor PRs landing within ~2–3 months serve as the decision gate for widening the matrix.

---

## Problem Frame

`STRATEGY.md` names two metrics this brainstorm directly serves: "Working recipes count" (uncomputed today) and "Perf gap vs best published Spark numbers" (unmeasured today). The persona — Spark owners on homelab and early-adopter hardware — currently relies on scattered NVIDIA forum threads, GitHub forks, and Discord posts to know whether their throughput is normal, whether a new llama.cpp commit helped or hurt, and which engine / quant / config delivers the best output at the fastest pace. No canonical place to check exists, and the knowledge that does exist rots as drivers, firmware, and engines move.

The maintainer is in the same position: today there is no way to answer "is my t/s normal for this hardware?" without manually running `llama-bench` and eyeballing the result against a forum post that may be months old. Every llama.cpp upstream change could be a regression and nobody would notice until anecdotal reports surface.

---

## Actors

- A1. **Maintainer** — runs the canonical Spark, owns the runner, accepts contributor PRs, decides what the matrix covers.
- A2. **Contributor** — another Spark owner who wants their numbers represented; submits a JSON result file via PR using the documented schema.
- A3. **Leaderboard reader** — drive-by Spark owner (or interested observer) who scans the public page to answer "what model + config gives the best output per second on a Spark?"
- A4. **Bench runner** — the self-hosted GitHub Actions runner on the maintainer's Spark; executes scheduled bench jobs and produces canonical result files.

---

## Key Flows

- F1. **Scheduled canonical bench run**
  - **Trigger:** Weekly cron (e.g., Sunday early morning) as a freshness floor, plus `workflow_dispatch` by A1 on demand.
  - **Actors:** A4 (with A1 setting the schedule).
  - **Steps:** Runner starts the relevant slot, polls `/health` until ready, runs `llama-bench` for steady-state throughput, runs the quality eval against the same endpoint, writes a JSON result file to `results/`, commits to a results branch, opens (or updates) a PR back to main.
  - **Outcome:** A new canonical result is in `results/`; the leaderboard rebuilds on merge.
  - **Covered by:** R1, R2, R3, R4, R7, R10.

- F2. **Contributor result submission**
  - **Trigger:** A2 wants to publish numbers from their own Spark.
  - **Actors:** A2, A1.
  - **Steps:** A2 reads the contribution doc, runs the same bench harness locally on their hardware, produces a JSON result that validates against the schema, opens a PR adding their file under `results/contributors/`, A1 reviews for schema validity and obvious tampering, merges. The leaderboard rebuilds.
  - **Outcome:** A2's numbers appear in the labeled secondary table on the leaderboard with their metadata (hardware revision, driver, llama.cpp SHA, GGUF SHA, clock state, timestamp) visible.
  - **Covered by:** R5, R6, R8, R10, R11.

- F3. **Leaderboard read**
  - **Trigger:** A3 visits the published Pages URL or the README table.
  - **Actors:** A3.
  - **Steps:** A3 sees a primary section (canonical numbers from A1's Spark) and a clearly-labeled secondary section ("Community submissions, as-reported"). Both sections present rows sortable by model, quant, engine, t/s, and the quality-eval score; clicking a row shows the full metadata for that run.
  - **Outcome:** A3 can answer "for my model class and quality bar, which engine + quant + config gives me the most throughput on a Spark?"
  - **Covered by:** R7, R8, R9.

---

## Requirements

**Bench harness**
- R1. The project ships a single bench-runner entry point (script or container) that takes a model slot + engine config and produces a JSON result. The same entry point is used by A4 (scheduled CI) and A2 (contributor running locally) — there is one code path, not two.
- R2. The runner measures throughput (steady-state tokens/second) via `llama-bench` (or the engine's native equivalent for non-llama.cpp engines added later) and a quality score via a **named eval suite** per model class. For the initial coder-class slice, the eval suite is the union of **HumanEval, MBPP+/EvalPlus, LiveCodeBench, and BigCodeBench** — each contributes one score column to the leaderboard. The runner reports all four scores plus a combined view; readers can sort by any individual eval or the combined.
- R3. The runner captures and writes to the result file the metadata needed to reproduce and compare: engine name + commit SHA, GGUF file SHA-256, model alias, quant tag, runtime args used, hardware metadata (driver version, firmware version if accessible, clock state from `nvidia-smi`), and a UTC timestamp.
- R4. The runner produces deterministic output paths: one JSON file per (model × quant × engine × engine-commit) cell, named so PRs from different contributors do not collide.

**Result schema and versioning**
- R5. The JSON result schema is defined in a versioned file at the repo root or under a stable path. The schema carries a `schema_version` field at the top of every result file.
- R6. The schema is **additive-only within a major version**: new optional fields may be added, existing fields may not be renamed or repurposed. A major version bump is allowed but treated as a contribution-API break and announced in the changelog and on the leaderboard.
- R7. Result files validate against the schema in CI on every PR that touches `results/` or `results/contributors/`. PRs failing validation cannot merge.

**Leaderboard publication**
- R8. The public leaderboard renders two sections: a primary table of canonical results from A1's runner, and a clearly-labeled secondary table of community submissions. Both sections use the same column schema; the secondary table additionally surfaces the contributor's hardware metadata inline.
- R9. The leaderboard is sortable / filterable by model, quant, engine, throughput, and quality-eval score. The README contains a compact version (top rows per model class); the full leaderboard lives on GitHub Pages (or equivalent static publication — final choice deferred to planning).
- R10. The leaderboard is regenerated automatically on merge to main when any file under `results/` changes. There is no manually edited table.

**Contributor workflow**
- R11. The repo includes a `CONTRIBUTING-RESULTS.md` (exact filename deferred to planning) describing: how to run the bench harness locally, what the schema requires, how to open a PR, and what A1 reviews for. The doc names the secondary-table labeling explicitly so contributors know upfront that their numbers will be presented "as-reported."

**Decision gate**
- R12. A dated decision-gate note in the repo (in `STRATEGY.md` or a sibling doc — final placement deferred to planning) records the gate: if no contributor PRs are merged into `results/contributors/` within ~2–3 months of the leaderboard going live, the project folds the leaderboard back into the README and stops running the scheduled matrix. The bench harness remains useful for internal use either way.

---

## Acceptance Examples

- AE1. **Covers R2, R3, R5.** Given the bench runner has just finished a Qwen3.6-27B coder-slot run on llama.cpp MTP, when the result file is written, the JSON contains a `schema_version`, the llama.cpp commit SHA, the GGUF SHA-256, the runtime args verbatim, the driver and clock state, a UTC timestamp, the steady-state tokens/second, and a separate pass-rate score for each of HumanEval, MBPP+/EvalPlus, LiveCodeBench, and BigCodeBench.
- AE2. **Covers R6.** Given a planned schema change that renames `tokens_per_second` to `throughput_tok_s`, when the maintainer attempts to merge it within the v1 schema, the major-version-bump rule applies — the PR either keeps the old field as a deprecated alias (additive) or bumps the schema to v2.
- AE3. **Covers R7.** Given a contributor opens a PR adding a result file under `results/contributors/` that is missing the `gguf_sha256` field, when CI runs, schema validation fails and the PR is blocked from merge with a clear error message.
- AE4. **Covers R8.** Given the leaderboard has both maintainer canonical results and three contributor submissions for the same model+quant, when A3 visits the page, they see both sections with the same column schema and can immediately tell which numbers come from the canonical Spark vs. a contributor's hardware.
- AE5. **Covers R12.** Given the decision gate's ~3-month window has elapsed with zero contributor PRs merged, when A1 reviews status, the dated gate note triggers a deliberate decision: keep running, narrow scope, or fold the leaderboard back into the README.

---

## Success Criteria

- The maintainer can answer "what's my throughput on Qwen3.6-27B with the current llama.cpp HEAD?" from the leaderboard in under 30 seconds, without running anything manually.
- A contributor can produce a valid result file, open a PR, and get it merged into the secondary table without needing to read more than the contribution doc and the schema.
- A drive-by reader scanning the leaderboard can identify the best-throughput configuration for a given model class and quality bar within one minute, and can see which numbers come from which Spark.
- The decision gate has a clear, dated trigger — there is no ambiguity about when to evaluate whether the canonical-source bet fired.
- `ce-plan` can begin without inventing product behavior: the bench-runner shape, the schema versioning policy, the two-section leaderboard layout, the contributor workflow, and the decision gate are all defined.

---

## Scope Boundaries

- vLLM, the croll83 DGX fork, and any other engines beyond llama.cpp + MTP are out of the initial slice; added only if the decision gate fires positively.
- Non-coder model classes (vision, audio, image-gen / FLUX) are out of the initial slice; coder-class only.
- Quality evals for non-coder model classes (reasoning, vision, audio) are out of scope; only the coder-class four-eval suite ships in the initial slice.
- Cross-Spark result normalization (calibration profiles, normalized vs raw columns — Approach C from the brainstorm) is explicitly deferred until heterogeneity actually surfaces as a problem.
- Vendor-grade methodology rigor (error bars, statistical-significance testing, repeated-run aggregation policy) is out of scope. The schema captures enough metadata that this could be added later without breaking contributors.
- Auto-bisect of upstream llama.cpp commits on perf regression is out of scope; once the bench runs on a schedule, this is a thin layer on top and can be added later.
- The leaderboard is not a model registry, model card host, or general "best LLM" site — it is hardware-target-specific (GB10) and engine + config-specific.

---

## Key Decisions

- **Approach A (project-authoritative) over community-first or hybrid-normalized.** The maintainer's runner anchors the page from day 1 so the leaderboard has numbers immediately; contributors land in a clearly-labeled secondary table. Chosen over community-first for bootstrap dynamics (community-first has cold-start problem — asks contributors to seed an empty table). Chosen over hybrid-normalized because defining normalization credibly is its own research project and premature without observed heterogeneity.
- **One quality eval per model class, not a pareto.** Defers vendor-grade rigor until contributor PRs justify the investment. The schema is designed to accommodate multiple evals per row when the time comes.
- **Forward-compatible JSON schema with versioning discipline from day 1.** The schema is the project's contribution API. Schema breakage has higher cost than implementation churn because it asks every contributor to redo work.
- **Decision gate is contributor PRs landing within ~2–3 months.** Treats the canonical-source positioning as a falsifiable bet, not an open-ended commitment. If contributions don't appear, the bet didn't fire and the project trims back rather than carrying community-facing infrastructure indefinitely.
- **One bench-runner code path used by both CI and contributors.** Prevents "runs on my CI but not on your Spark" drift. A2 and A4 invoke the same entry point with the same configuration model.
- **Hybrid windowing: weekly cron + `workflow_dispatch` on demand.** Weekly cron provides a freshness floor for the canonical numbers without nightly contention; manual trigger lets the maintainer run ad-hoc checks after upstream changes without waiting for the cron. Picked over nightly (too much contention) and manual-only (no freshness guarantee).
- **Four-eval suite (HumanEval, MBPP+/EvalPlus, LiveCodeBench, BigCodeBench) for the initial coder-class slice.** Picked over single-eval because each eval has known weaknesses (HumanEval / MBPP+ are saturated and contamination-heavy; LiveCodeBench is contamination-aware but lighter than BigCodeBench; BigCodeBench is rigorous but slow), and presenting all four with their numbers exposed lets the contributor-facing audience apply their own weighting rather than trusting the project's. Cost: ~5–7 hours of eval per (model, config) cell, absorbed by the weekly window so long as the matrix stays small in the initial slice.

---

## Dependencies / Assumptions

- The DGX Spark can be configured as a GitHub Actions self-hosted runner with appropriate firewall / Tailscale considerations. *(Unverified — needs validation during planning.)*
- A reasonable open-source code-quality eval (HumanEval, MBPP, or LiveCodeBench) can be run against a `llama-server` OpenAI-compatible endpoint with modest setup. *(Standard assumption; final eval choice deferred to planning.)*
- The maintainer is willing to accept the Spark contention during scheduled bench runs — the inference work pauses during the window. Mitigation depends on the windowing strategy chosen.
- GitHub Pages (or an equivalent static-publication target) is acceptable for the public leaderboard. Custom hosting is not required for the initial slice.
- Contributor PRs are submitted in good faith. The schema-validation step in CI catches structural issues; deliberate tampering is treated as a community-management problem, not a software problem, in the initial slice.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1][Technical] Whether the single bench-runner entry point is a Python script, a Bash script, or a container image. Affects how A2 invokes it on hardware that may not match A4's exact environment.
- [Affects R5, R6][Technical][Needs research] Whether the schema lives as JSON Schema, Pydantic models, or a hand-rolled validator. JSON Schema is most contributor-friendly; the other options give better static-checking.
- [Affects R8, R9][Technical] Whether the leaderboard renders via a static-site generator (Jekyll, MkDocs, Astro), a single hand-rolled HTML page generated by a script, or just the auto-updated README table. Affects sortability and the contributor-onboarding experience.
- [Affects R10][Technical] How the leaderboard regeneration is triggered: a GitHub Action that runs a generator on every merge, or a build step in the Pages publish workflow. Both work; one is cleaner.
- [Affects F1][Technical] How the runner handles a failed bench (OOM, model load failure, eval timeout) — should it write a failure record to `results/`, retry, or skip silently? Default assumption: write a failure record with `status: failed` and the error reason, so the leaderboard can show "last attempt failed" without losing history.
- [Affects R2][Technical] Eval-suite subset choices: BigCodeBench has multiple subsets (Complete, Instruct, Hard); LiveCodeBench is windowed by problem release date; HumanEval and MBPP+ have plus / minus variants. Initial slice picks one canonical subset per eval; choices deferred to planning so each eval's setup can be validated against the runner first.
- [Affects R2, F1][Technical][Needs research] Whether to run the four evals sequentially per cell (simpler, ~5–7 hours per cell) or in parallel where possible (faster wall time but contention with each other for the model endpoint). Default assumption: sequential.
- [Affects R8, R9][Technical] How the leaderboard presents four eval scores per row without making the table illegible — a single combined-score column with the four individual scores in a popover, four separate sortable columns, or both. Affects contributor-doc explanation burden.
