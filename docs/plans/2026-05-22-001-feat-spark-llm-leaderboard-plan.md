---
date: 2026-05-22
status: active
type: feat
topic: spark-llm-leaderboard
origin: docs/brainstorms/2026-05-22-spark-llm-leaderboard-requirements.md
---

# feat: Spark LLM Leaderboard (Public Benchmark CI)

## Summary

A self-hosted GitHub Actions runner on the maintainer's DGX Spark runs a weekly canonical bench (throughput + four code-quality evals) and publishes a two-section leaderboard. Contributors submit JSON result files via PR using a versioned schema that doubles as the project's contribution API. Decision gate at ~2-3 months: if no contributor PRs land, fold back to README and stop the scheduled matrix.

---

## Problem Frame

`STRATEGY.md` names two metrics unaddressed today: "Working recipes count" and "Perf gap vs best published Spark numbers". Spark owners (the persona) rely on scattered forum threads, GitHub forks, and Discord posts to know whether their throughput is normal or which engine + quant + config wins. The maintainer has the same gap — no canonical answer to "is my t/s normal for this hardware?" without running `llama-bench` and eyeballing it against a months-old forum post.

See origin: `docs/brainstorms/2026-05-22-spark-llm-leaderboard-requirements.md`.

---

## Scope and Requirements Trace

**In scope (this plan):**

- Bench-runner container (R1, R3, R4) — single hermetic entry point shared by CI and contributors
- Throughput measurement via `llama-bench` (R2)
- Four-eval coder-class quality suite: HumanEval+, MBPP+, LiveCodeBench (rolling 6-month window), BigCodeBench Complete + Hard (R2)
- JSON Schema Draft 2020-12 result schema with `schema_version` and additive-only versioning within v1 (R5, R6)
- CI schema validation on PRs touching `results/` or `results/contributors/` (R7)
- Two-section leaderboard: primary (canonical) and secondary (community), same column schema (R8)
- Sortable/filterable leaderboard via static HTML; compact README rows (R9)
- Auto-regeneration on merge to main when `results/**` changes (R10)
- Contributor doc (`CONTRIBUTING-RESULTS.md`) (R11)
- Dated decision-gate note (R12)

**Carried forward from origin (Actors / Flows / AEs):**

- Actors A1 (maintainer), A2 (contributor), A3 (reader), A4 (bench runner) — preserved as constraints on R1's "one code path" and R8's two-section layout
- Flows F1 (scheduled bench), F2 (contributor submission), F3 (leaderboard read) — covered by U-mapping in §Implementation Units
- AE1-AE5 — covered by per-unit test scenarios

---

## Approach

**Containerized bench runner.** A `Dockerfile.bench` produces an image (`spark-llm-bench`) separate from the inference image. It bundles: a Python entry-point (`bench/run.py`), the four eval harnesses, `llama-bench`, and the schema validator. A4 (CI) and A2 (contributors) both `docker run` this image with a config file naming the model slot, engine commit, and which evals to run. There is one code path; the container is the contract.

**JSON Schema as the contribution API.** The schema file lives at the repo root (`schema/result.v1.schema.json`) and is the source of truth. CI validates every JSON in `results/` and `results/contributors/` against it. The schema is additive-only within v1; renaming a field requires a v2 bump and a changelog entry on the leaderboard.

**Static HTML + README dual publication.** A Python generator (`leaderboard/generate.py`) walks `results/**/*.json`, builds two sortable tables (primary + secondary), and writes:

1. `site/index.html` — full sortable table (model, quant, engine, t/s, four eval scores, combined, metadata-on-click), published to a `gh-pages` branch
2. README rows — compact view (model, quant, engine, t/s, combined) injected between markers

Two GitHub Actions workflows:

- `bench.yml` — `schedule: cron(weekly)` + `workflow_dispatch`. Runs on the self-hosted Spark runner; produces canonical results.
- `leaderboard-publish.yml` — `push` to main, `paths: [results/**]`. Regenerates HTML, updates README, deploys Pages.
- `validate-results.yml` — `pull_request`, `paths: [results/**, schema/**]`. Runs schema validation.

**Failure handling.** Bench failures (OOM, model-load failure, eval timeout) write a result file with `status: "failed"` and `error: <reason>`. The leaderboard shows "last attempt failed" badge but retains the previous successful row. No auto-retry; A1 reruns via `workflow_dispatch`.

---

## High-Level Technical Design

*Directional sketch for review — not implementation specification. The implementer should treat it as context, not code to reproduce.*

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions (self-hosted runner on DGX Spark)               │
│                                                                  │
│  bench.yml ──┐                                                  │
│  (cron+wd)   │                                                  │
│              ▼                                                  │
│   ┌─────────────────────────┐                                   │
│   │ docker run              │   ┌──────────────────┐            │
│   │ spark-llm-bench         │──▶│ llama-server     │            │
│   │   --config canonical/   │   │ (host: --gpus)   │            │
│   │           qwen27.yaml   │   └──────────────────┘            │
│   │                         │            ▲                      │
│   │  1. start llama-server  │            │ OpenAI-compat        │
│   │  2. poll /health        │            │                      │
│   │  3. llama-bench         │────────────┘                      │
│   │  4. eval harnesses ×4   │                                   │
│   │     (sequential)        │                                   │
│   │  5. write result.json   │                                   │
│   │  6. validate vs schema  │                                   │
│   │  7. commit + open PR    │                                   │
│   └─────────────────────────┘                                   │
└─────────────────────────────────────────────────────────────────┘
              │
              ▼ (merge to main, results/** changed)
┌─────────────────────────────────────────────────────────────────┐
│  leaderboard-publish.yml (ubuntu-latest)                        │
│                                                                  │
│  python leaderboard/generate.py                                 │
│    ├─ walk results/*.json (primary)                             │
│    ├─ walk results/contributors/*.json (secondary)              │
│    ├─ render site/index.html (sortable.js, client-side sort)    │
│    └─ inject README rows between <!-- LEADERBOARD --> markers   │
│                                                                  │
│  Deploy site/ → gh-pages branch                                 │
└─────────────────────────────────────────────────────────────────┘

Result file naming (R4):
  results/<model_alias>__<quant>__<engine>__<engine_sha7>.json
  results/contributors/<contributor_handle>__<model_alias>__<quant>__<engine>__<engine_sha7>.json
```

---

## Output Structure

The plan creates a new directory hierarchy. Expected layout after all units land:

```
spark-llm-stack/
├── Dockerfile.bench                       # U2
├── bench/
│   ├── run.py                             # U2 entry point
│   ├── config/
│   │   ├── canonical/
│   │   │   ├── qwen27-mtp.yaml            # U2
│   │   │   └── qwen35-mtp.yaml            # U2
│   │   └── schema.yaml                    # U2 config-file schema
│   ├── throughput.py                      # U4 llama-bench wrapper
│   ├── metadata.py                        # U5 hardware/engine metadata capture
│   ├── result_writer.py                   # U5
│   └── evals/
│       ├── humaneval_plus.py              # U3
│       ├── mbpp_plus.py                   # U3
│       ├── livecodebench.py               # U3
│       └── bigcodebench.py                # U3
├── schema/
│   ├── result.v1.schema.json              # U1
│   └── CHANGELOG.md                       # U1
├── results/
│   └── (canonical result files — created at runtime by U6)
│   └── contributors/
│       └── .gitkeep                       # U10
├── leaderboard/
│   ├── generate.py                        # U8
│   ├── templates/
│   │   └── index.html.j2                  # U8
│   └── static/
│       └── sortable.js                    # U8
├── site/                                  # build output, gitignored
├── .github/
│   └── workflows/
│       ├── bench.yml                      # U6
│       ├── validate-results.yml           # U7
│       └── leaderboard-publish.yml        # U9
├── CONTRIBUTING-RESULTS.md                # U10
├── STRATEGY.md                            # U11 amends in place
└── README.md                              # U8 injects leaderboard markers
```

The tree shows the expected output shape; per-unit `**Files:**` sections remain authoritative.

---

## Key Technical Decisions

- **Bench-runner is a containerized Python entry point.** Resolves origin Deferred-to-Planning Q1. Chosen over Bash/Python scripts because R1 "one code path used by CI and contributors" is materially weakened by host-environment surface area; a hermetic container is the only artifact that survives heterogeneous contributor setups.
- **JSON Schema Draft 2020-12, validated by `check-jsonschema`.** Resolves Q2. Chosen over Pydantic (Python-coupled — forces contributors into a Python toolchain) and hand-rolled (poor error messages). JSON Schema has the widest tooling and IDE support.
- **Hand-rolled Python generator producing static HTML + README rows.** Resolves Q3. Chosen over MkDocs / Astro / Jekyll because the use case is a single sortable table with two sections; an SSG's directory model, theming, and navigation are unused overhead. If scope grows to multi-page docs, switching to MkDocs Material is a one-time port.
- **Dedicated `leaderboard-publish.yml` workflow with `paths: [results/**]` trigger.** Resolves Q4. Cleaner separation: bench-runner produces results; publisher consumes them. Avoids coupling generator cadence to bench cadence.
- **Failure → write `{status: "failed", error: ...}` record; no auto-retry.** Resolves Q5. Confirms the origin default. History preservation matters more than silent retry; A1 can `workflow_dispatch` rerun.
- **Eval-suite subset choices.** Resolves Q6. HumanEval+ and MBPP+ (EvalPlus extended test sets, supersede vanilla); LiveCodeBench rolling 6-month problem window (contamination mitigation per the harness's `release_v` filter); BigCodeBench Complete + Hard (Complete is the canonical number, Hard is reported as a separate column to expose the difficulty ceiling).
- **Sequential eval execution.** Resolves Q7. Confirms the origin default. Single `llama-server` endpoint means parallel evals contend on the same GPU; weekly window absorbs the ~5-7h cost.
- **Four sortable columns + one combined column.** Resolves Q8. Combined = mean of the four eval scores after each is normalized to 0-100. Honors origin Key Decision "readers apply their own weighting" — column sort is the weighting mechanism. README compact rows show combined only; full page shows all five.
- **Bench container is separate from `spark-llm-stack` inference image.** Keeps the contribution-API artifact minimal (no model serving, no `llm-switch`). Cost: two images to maintain.
- **Bench container calls `llama-server` over HTTP on the host network, not in-container.** Reuses the existing `spark-llm-stack` image as the serving runtime (one image per concern). Bench container is a thin client.

---

## Implementation Units

### U1. Result schema (JSON Schema Draft 2020-12)

**Goal:** Define the v1 result-file schema and a schema CHANGELOG. This is the contribution API.

**Requirements:** R5, R6, R7. Origin AE1, AE2, AE3.

**Dependencies:** None — first unit.

**Files:**
- `schema/result.v1.schema.json` (create)
- `schema/CHANGELOG.md` (create)
- `schema/examples/canonical-success.json` (create — example for AE1)
- `schema/examples/canonical-failed.json` (create — failure record example)
- `schema/examples/contributor-success.json` (create)
- `tests/schema/test_schema.py` (create — Python `check-jsonschema` driven)

**Approach:**

Schema top-level fields (v1):

- `schema_version` (const "1")
- `result_kind` (enum: "canonical" | "contributor")
- `status` (enum: "success" | "failed")
- `timestamp_utc` (RFC 3339)
- `model` (object: `alias`, `gguf_sha256`, `quant`)
- `engine` (object: `name`, `commit_sha`, `runtime_args` — array of strings, verbatim)
- `hardware` (object: `gb_name` const "GB10", `driver_version`, `firmware_version` nullable, `clock_state` — captured from `nvidia-smi`)
- `throughput` (object: `tokens_per_second_steady`, `llama_bench_raw` — verbatim text block)
- `quality` (object: `humaneval_plus`, `mbpp_plus`, `livecodebench`, `bigcodebench_complete`, `bigcodebench_hard`, `combined`)
- `contributor` (object — required only when `result_kind: "contributor"`: `handle`, `hardware_notes` free-form)
- `error` (object — required only when `status: "failed"`: `phase`, `message`)

`additionalProperties: false` at every level to enforce the additive-only discipline mechanically; a new field requires a schema PR.

**Patterns to follow:** None in repo; new convention. Mirror naming style of existing service unit env vars (snake_case, descriptive).

**Test scenarios:**
- Covers AE1. Given a canonical-success JSON with all required fields populated, when validated against `result.v1.schema.json`, validation passes.
- Covers AE3. Given a contributor JSON missing `model.gguf_sha256`, when validated, validation fails with an error naming the missing field.
- Given a JSON with `additionalProperties` at the top level (e.g., `experimental_field: true`), when validated, validation fails (enforces additive-only-via-schema-PR).
- Given a failure-record JSON with `status: "failed"` but no `error` object, when validated, validation fails.
- Given a contributor JSON with `result_kind: "contributor"` but no `contributor.handle`, when validated, validation fails.
- Given a JSON with `schema_version: "2"`, when validated against v1 schema, validation fails (forward-incompat detection).

**Verification:** All schema examples in `schema/examples/` validate cleanly; the four negative-test JSONs fail with clear error messages naming the missing/forbidden field.

---

### U2. Bench-runner container and config

**Goal:** Single hermetic entry point (`docker run spark-llm-bench --config <path>`) usable by CI and contributors.

**Requirements:** R1, R4. Origin F1, F2 (shared entry point).

**Dependencies:** U1 (writer needs schema awareness for early validation).

**Files:**
- `Dockerfile.bench` (create)
- `bench/run.py` (create — CLI entry point)
- `bench/config/canonical/qwen27-mtp.yaml` (create)
- `bench/config/canonical/qwen35-mtp.yaml` (create)
- `bench/config/schema.yaml` (create — JSON Schema for the *config* file, separate from result schema)
- `bench/requirements.txt` (create)
- `tests/bench/test_run_cli.py` (create)

**Approach:**

`bench/run.py` is the single entry point. CLI: `run.py --config <yaml> --output-dir <path> [--evals humaneval_plus,mbpp_plus,livecodebench,bigcodebench] [--llama-server-url http://host:8152]`. Default evals = all four.

Config file (YAML) names: model alias, quant, llama-server URL or slot name, engine commit SHA (looked up from a running server's `/v1/models`), runtime-args capture method (read from systemd unit or container CMD).

The container does **not** start `llama-server` itself — it expects a running endpoint reachable at `--llama-server-url`. For canonical CI runs, the runner script (U6) calls `llm-switch <slot>` on the host before invoking `docker run --network=host`. For contributors, the doc (U10) instructs them to start the relevant slot first.

Result file naming (R4): `<model_alias>__<quant>__<engine>__<engine_sha7>.json`. For contributors, additionally prefixed with `<contributor_handle>__` and placed under `results/contributors/`. Stable naming avoids PR collisions.

**Patterns to follow:** Dockerfile multi-stage build pattern from existing `Dockerfile` (builder + runtime). Bench image is much thinner — no CUDA, just Python + eval-harness deps + `llama-bench` binary (copied from inference image build artifact, or built standalone). Decision: copy `llama-bench` from a pinned tag of llama.cpp mainline during image build; eval harnesses do not need GB10-tuned binaries.

**Test scenarios:**
- Given a valid config YAML, when `run.py --config x.yaml --dry-run` is invoked, it prints the resolved plan (which evals, output path, target server URL) without making network calls.
- Given a config YAML missing the required `model.alias` field, when `run.py` is invoked, it exits non-zero with a config-validation error naming the missing field.
- Given `--llama-server-url` pointing at an unreachable host, when `run.py` is invoked, it exits non-zero within 30s with a "server unreachable" error and writes a `status: failed` result file.
- Given a successful end-to-end mock run (mocked throughput + mocked eval scores), when complete, the output JSON validates against `schema/result.v1.schema.json`.
- Given the produced result filename, when checked against R4, it matches `<model_alias>__<quant>__<engine>__<engine_sha7>.json`.

**Verification:** `docker build -f Dockerfile.bench -t spark-llm-bench .` produces an image ≤2 GB. `docker run --rm spark-llm-bench --help` prints the CLI usage. `--dry-run` against a canonical config emits a valid plan.

---

### U3. Eval harness adapters

**Goal:** Four eval adapters that target an OpenAI-compatible endpoint and return a normalized 0-100 pass-rate score.

**Requirements:** R2. Origin AE1.

**Dependencies:** U2 (run inside the bench container; share its Python env).

**Files:**
- `bench/evals/__init__.py` (create — common adapter interface)
- `bench/evals/humaneval_plus.py` (create)
- `bench/evals/mbpp_plus.py` (create)
- `bench/evals/livecodebench.py` (create)
- `bench/evals/bigcodebench.py` (create — runs Complete and Hard, returns both scores)
- `bench/evals/_endpoint.py` (create — shared OpenAI-compat HTTP client used by all four)
- `tests/bench/test_eval_adapters.py` (create)

**Approach:**

Common adapter interface:

```python
# directional, not implementation:
class EvalAdapter(Protocol):
    name: str
    def run(self, endpoint_url: str, model_name: str, subset: str | None) -> EvalResult: ...

@dataclass
class EvalResult:
    raw_score: float            # eval-native units (e.g., pass@1)
    normalized_0_100: float     # for combined-score averaging
    subset: str                 # which subset was run
    n_problems: int             # for transparency in result file
    raw_logs_path: Path | None  # optional eval-harness stdout dump
```

EvalPlus (HumanEval+, MBPP+) — upstream package supports OpenAI-compatible endpoints out of the box. Pin a version in `bench/requirements.txt`.

LiveCodeBench — uses the upstream `livecodebench` harness with `--release_version release_v5` or whatever is the rolling 6-month-old release at run time. Adapter computes the right release tag from today's date.

BigCodeBench — runs both Complete and Hard subsets, returns two scores. Adapter wraps `bigcodebench.evaluate` CLI.

Combined score = arithmetic mean of [humaneval_plus, mbpp_plus, livecodebench, bigcodebench_complete] (excludes Hard — Hard is for ceiling visibility, not combined).

**Patterns to follow:** None in repo; new code.

**Test scenarios:**
- Given a mocked endpoint returning a fixed completion for HumanEval problem 0, when `humaneval_plus.run()` is invoked with a 1-problem subset, the adapter returns an `EvalResult` with `n_problems=1` and a score reflecting whether the canned completion passes.
- Given a `bigcodebench.run()` call, when complete, the result includes both `complete` and `hard` scores in the output.
- Given the four adapters return scores [85.0, 78.0, 42.0, 33.0] for Complete (and 18.0 for Hard), when the combined score is computed, it equals 59.5 and excludes Hard.
- Given an endpoint that times out, when an adapter is invoked, it raises a structured exception that U2 converts to a `status: failed` record with `error.phase = "eval"`.

**Verification:** Each adapter runs end-to-end against a real `llama-server` on a tiny model (e.g., the existing `vision` slot's E4B) for smoke validation. Numbers do not need to be production-meaningful — only the integration shape is verified here.

---

### U4. Throughput measurement wrapper

**Goal:** Run `llama-bench` against the configured model and parse steady-state tokens/second.

**Requirements:** R2. Origin AE1.

**Dependencies:** U2.

**Files:**
- `bench/throughput.py` (create)
- `tests/bench/test_throughput_parsing.py` (create)

**Approach:**

Invoke `llama-bench -m <gguf_path> -p <prompt_tokens> -n <gen_tokens> -t <threads>` with parameters from the config file. Parse the markdown-table stdout to extract the `tg128` (token-generation, batch 128) row's t/s value as the headline `tokens_per_second_steady`. Also capture the full stdout as `llama_bench_raw` (verbatim text block in the result file — required by R3 for reproducibility).

The wrapper does *not* start `llama-server` — `llama-bench` runs against the GGUF directly, bypassing the server. This gives a cleaner throughput number (no HTTP overhead) at the cost of not measuring the actual serving path. Documented tradeoff in the README leaderboard section.

**Patterns to follow:** Existing diagnostics commands in `CLAUDE.md` use `journalctl` and `systemctl --user show` — same shell-out-and-parse shape.

**Test scenarios:**
- Given a sample `llama-bench` stdout (captured fixture), when parsed, the `tg128` row's t/s value is extracted as the steady-state number.
- Given a malformed `llama-bench` stdout (truncated, no `tg128` row), when parsed, the wrapper raises a structured exception that U2 converts to `status: failed`.
- Given a real `llama-bench` invocation on a tiny model on the Spark, when complete, the wrapper returns a positive float and the raw text contains the expected table.

**Verification:** Parses captured fixtures correctly; live run on a tiny model on the Spark returns a sensible number.

---

### U5. Result-file writer with metadata capture

**Goal:** Capture all R3 metadata and emit a schema-valid result JSON.

**Requirements:** R3, R5. Origin AE1.

**Dependencies:** U1, U2.

**Files:**
- `bench/metadata.py` (create — hardware/engine/runtime-args capture)
- `bench/result_writer.py` (create)
- `tests/bench/test_result_writer.py` (create)

**Approach:**

`metadata.py` captures:

- `driver_version` — parse `nvidia-smi --query-gpu=driver_version --format=csv,noheader`
- `firmware_version` — parse `nvidia-smi -q | grep "VBIOS"` (nullable on permission failure)
- `clock_state` — parse `nvidia-smi --query-gpu=clocks.current.sm,clocks.current.memory --format=csv,noheader`
- `engine.commit_sha` — query `llama-server`'s startup log or `/v1/models` if exposed; fall back to reading from the systemd unit's `ExecStart` path's git metadata
- `engine.runtime_args` — capture verbatim from the config file or the systemd unit's `ExecStart`
- `model.gguf_sha256` — computed from the GGUF file path declared in the config

`result_writer.py` composes the final JSON, validates against `schema/result.v1.schema.json` before writing, and refuses to write on validation failure (fail loud, not silently corrupt the leaderboard).

**Patterns to follow:** Existing `harden-llm-stack.sh` reads systemd unit files with `systemctl --user show`; reuse that pattern for engine args capture.

**Test scenarios:**
- Given metadata-capture mocks returning canned values, when `result_writer.write(...)` is called with a successful bench result, the output JSON contains every R3-required field and validates against the schema.
- Given a metadata-capture call where `nvidia-smi` is unavailable, when invoked, the writer captures `null` for the unavailable fields (only `firmware_version` is nullable; driver_version absence is fatal).
- Given a result that would fail schema validation (e.g., a quality score outside 0-100), when `write()` is called, it raises before touching disk.
- Given a failure-mode invocation (`status: "failed"`, `error.phase: "model_load"`, `error.message: "..."`), when validated, the result JSON validates and writes successfully.

**Verification:** End-to-end mock run produces a JSON file at the R4 path that validates against the v1 schema.

---

### U6. GitHub Actions workflow — scheduled canonical bench

**Goal:** Weekly cron + `workflow_dispatch` runs the canonical bench on the self-hosted Spark runner, commits results to a branch, opens a PR.

**Requirements:** R1, R7 (via the validate workflow). Origin F1, Key Decision "Hybrid windowing".

**Dependencies:** U2, U5. Requires self-hosted runner already registered on the Spark (operational prereq, not code).

**Files:**
- `.github/workflows/bench.yml` (create)
- `.github/scripts/start-slot.sh` (create — wraps `llm-switch <slot>` + health-poll)
- `.github/scripts/open-result-pr.sh` (create — gh CLI wrapper)

**Approach:**

Workflow steps:

1. `on: schedule: cron('0 7 * * SUN')` (Sunday 07:00 UTC) + `workflow_dispatch` (with optional `slot` and `evals` inputs)
2. `runs-on: [self-hosted, dgx-spark]`
3. Matrix over canonical configs (initial slice: qwen27-mtp, qwen35-mtp) — sequential, not parallel (single GPU; per the Key Technical Decision "Sequential eval execution")
4. For each config:
   - `bash .github/scripts/start-slot.sh <slot>` (calls `llm-switch <slot>`, polls `/health` until ready, fails after timeout)
   - `docker run --rm --network=host -v $PWD/results:/out spark-llm-bench --config bench/config/canonical/<config>.yaml --output-dir /out`
   - `llm-switch off`
5. `git add results/ && git commit -m "bench: weekly canonical run <date>"` on a new branch `bench/canonical-YYYY-MM-DD`
6. `bash .github/scripts/open-result-pr.sh` opens (or updates) a PR

Reuse for `workflow_dispatch`: same steps, optional inputs override the slot list and eval list.

**Patterns to follow:** Existing `llm-switch` health-poll pattern (`curl -f http://localhost:<port>/health`).

**Execution note:** This is the highest-risk unit (CI surface, self-hosted runner, secrets). Implement after U2/U5 are smoke-tested standalone via `docker run` from a developer shell.

**Test scenarios:**
- Given a `workflow_dispatch` event with `slot: coder, evals: humaneval_plus`, when the workflow runs end-to-end on a local `act` invocation (or against a test branch), it produces a result file under `results/` and opens a PR.
- Given the runner is healthy but `llm-switch coder` fails (port already in use), when the workflow runs, the failing step exits non-zero, no result file is committed, and the workflow surfaces the error in the run log.
- Given the bench completes but `llama-server` did not stop afterward, when the next matrix entry tries to start a different slot, `llm-switch <other>` succeeds (mutual exclusion handles cleanup) — verifies the existing `Conflicts=` drop-in covers the CI path.
- Given the cron-triggered run, when complete, the opened PR title and body include the date, slot list, and a summary of pass/fail per matrix cell.

**Verification:** A manual `workflow_dispatch` run on a feature branch produces results, opens a PR, and the resulting PR passes the validate workflow (U7).

---

### U7. GitHub Actions workflow — schema validation on PRs

**Goal:** Block PRs that add invalid result JSON files.

**Requirements:** R7. Origin AE3.

**Dependencies:** U1.

**Files:**
- `.github/workflows/validate-results.yml` (create)

**Approach:**

Workflow:

1. `on: pull_request: paths: [results/**, schema/**, bench/**]`
2. `runs-on: ubuntu-latest` (cheap, no self-hosted dependency)
3. Steps:
   - Checkout
   - Install `check-jsonschema` (pip)
   - `check-jsonschema --schemafile schema/result.v1.schema.json results/**/*.json results/contributors/**/*.json`
   - On failure, the workflow prints the offending file + JSON path + reason

If `schema/` changed in the PR, additionally re-validate all existing `results/**/*.json` against the new schema. This is the mechanism that enforces R6 (additive-only): a schema change that breaks existing results blocks the PR, forcing either a v2 bump or an additive correction.

**Patterns to follow:** None in repo; new convention.

**Test scenarios:**
- Covers AE3. Given a PR adding `results/contributors/contributor1__qwen27__llamacpp__abc1234.json` with `gguf_sha256` missing, when validate-results runs, the workflow fails and the run log identifies the missing field by JSON path.
- Given a PR that modifies `schema/result.v1.schema.json` to rename `tokens_per_second_steady` → `throughput_tok_s` (R6 violation), when validate-results runs, validation of existing canonical results fails, blocking the PR.
- Given a valid contributor result, when validate-results runs, the workflow passes.
- Given a PR that adds a *new optional* field to the schema and a result file using it, when validate-results runs, validation passes (additive change accepted).

**Verification:** Test the four scenarios above on a sacrificial PR before relying on the workflow in production.

---

### U8. Leaderboard generator

**Goal:** Walk results, render `site/index.html` (sortable, two sections), inject compact rows into README.

**Requirements:** R8, R9. Origin F3, AE4.

**Dependencies:** U1.

**Files:**
- `leaderboard/generate.py` (create)
- `leaderboard/templates/index.html.j2` (create — Jinja2 template with embedded sortable.js)
- `leaderboard/static/sortable.js` (create or vendor — client-side table sort; vendor a single small file like `tablesort` ~3KB)
- `README.md` (modify — add `<!-- LEADERBOARD:START -->` and `<!-- LEADERBOARD:END -->` markers in the appropriate section)
- `tests/leaderboard/test_generator.py` (create)
- `tests/leaderboard/fixtures/` (create — sample result JSONs)

**Approach:**

`generate.py`:

1. Walk `results/*.json` → primary rows
2. Walk `results/contributors/*.json` → secondary rows
3. For each result with `status: "success"`, emit a row: `model.alias | model.quant | engine.name + engine.commit_sha[:7] | throughput.tokens_per_second_steady | quality.humaneval_plus | quality.mbpp_plus | quality.livecodebench | quality.bigcodebench_complete | quality.bigcodebench_hard | quality.combined`. For `status: "failed"`, emit a "last attempt failed" placeholder if a previous successful run exists for the same cell (lookup by `<model_alias>__<quant>__<engine>` key); otherwise emit a failed-only row with the error reason inline.
4. Render two HTML tables (primary, secondary) with `<th>` sortable headers. Secondary table additionally shows `contributor.handle` and `contributor.hardware_notes` columns; same column schema otherwise (per R8).
5. Write to `site/index.html`.
6. Build the README compact view: top-N rows per model class (model, quant, engine, t/s, combined), inject between markers.

**Patterns to follow:** README already has a `Docker attribution` section near the top — leaderboard section goes higher (above features, below the title) per typical "show value first" convention.

**Test scenarios:**
- Covers AE4. Given fixtures with 2 canonical results and 3 contributor results for the same model+quant, when `generate.py` runs, the output `site/index.html` contains two tables with the same column schema and visibly distinct section headings ("Canonical (DGX Spark — maintainer)" vs "Community submissions (as-reported)").
- Given a failed result with no prior success for that cell, when the generator runs, the row shows "last attempt failed" + error reason and is sortable to the bottom by t/s (failed rows treated as t/s=0 for sort).
- Given a failed result *with* a prior success for that cell, when the generator runs, the row shows the prior successful values + a "last attempt failed (date)" badge.
- Given the generator runs, when README markers are present, the compact rows are injected between them and any pre-existing content between markers is replaced.
- Given the generator runs against an empty `results/` directory, when complete, both tables show "no results yet" placeholder rows without crashing.

**Verification:** Run `python leaderboard/generate.py` against the fixtures and open `site/index.html` in a browser; verify sortability by clicking each header. Confirm README markers update in place.

---

### U9. GitHub Actions workflow — publish leaderboard

**Goal:** On merge to main when `results/**` changes, regenerate the leaderboard and deploy to GitHub Pages.

**Requirements:** R10.

**Dependencies:** U8.

**Files:**
- `.github/workflows/leaderboard-publish.yml` (create)
- `.gitignore` (modify — add `site/`)

**Approach:**

Workflow:

1. `on: push: branches: [main], paths: [results/**, leaderboard/**, schema/**, README.md]`
2. `runs-on: ubuntu-latest`
3. Steps:
   - Checkout
   - Setup Python, install `leaderboard/requirements.txt`
   - `python leaderboard/generate.py --out site/ --update-readme`
   - If README changed, commit + push back to main on a dedicated bot branch and open auto-merge PR (or directly commit with `[skip ci]` to avoid loops — decision: use a bot PR for visibility)
   - Deploy `site/` to `gh-pages` branch via `peaceiris/actions-gh-pages@v3` or the official `actions/deploy-pages@v4`

**Patterns to follow:** None in repo.

**Test scenarios:**
- Given a PR merging a new canonical result, when the workflow runs, `gh-pages` branch updates with the new HTML and a README-update PR opens (or the README is updated directly, depending on the chosen sub-pattern).
- Given a push that only touches `bench/` (no result changes), when the path filter evaluates, the workflow does not run.
- Given the workflow runs but `generate.py` fails (e.g., a result file has a `status` value the generator doesn't know how to render), when the workflow fails, the published Pages site is *not* updated (no half-broken deploy).

**Verification:** Manually merge a sacrificial result file on a test branch with Pages configured; confirm `gh-pages` updates and the public URL renders.

---

### U10. Contributor doc

**Goal:** `CONTRIBUTING-RESULTS.md` explaining how to produce, validate, and submit a result.

**Requirements:** R11. Origin F2.

**Dependencies:** U1, U2, U7.

**Files:**
- `CONTRIBUTING-RESULTS.md` (create)
- `results/contributors/.gitkeep` (create)
- `results/contributors/EXAMPLE.json` (create — annotated example)

**Approach:**

Doc sections:

1. **What this leaderboard accepts** — coder-class models on llama.cpp + MTP, scheduled to expand if the decision gate fires
2. **What you'll need** — DGX Spark, Docker, the relevant model file, ~5-7 hours
3. **Quickstart** — three commands: `llm-switch <slot>`, `docker run --network=host -v ./results/contributors:/out spark-llm-bench --config <your-config.yaml>`, `git checkout -b results/<handle>/<model>-<quant> && git add results/contributors/*.json && git commit && gh pr create`
4. **What the maintainer reviews for** — schema validity (automated), no obvious tampering (signed metadata, sensible numbers), filename collisions
5. **What "as-reported" means** — secondary-table labeling explicit upfront
6. **FAQ** — eval cost, retries, partial submissions (allowed: a PR with only HumanEval+ if BigCodeBench timed out, as long as `status` reflects the partial state — TBD: schema may need a `partial_results` flag; if so, that's a v1.1 additive change)

**Patterns to follow:** Existing README style — direct, command-first, no preamble bloat.

**Test scenarios:** None — documentation only. Verification is reader-comprehension.

**Verification:** A second person (or the maintainer 6 months later) can follow the doc from a fresh shell and produce a mergeable PR. If `partial_results` turns out to be needed, that's a v1.1 schema additive change (U1 follow-up).

---

### U11. Decision-gate note

**Goal:** Dated note recording the ~2-3 month decision gate.

**Requirements:** R12. Origin AE5.

**Dependencies:** None.

**Files:**
- `STRATEGY.md` (modify — add a `## Decision gates` section at the bottom)

**Approach:**

Add a new section to `STRATEGY.md`:

```markdown
## Decision gates

### Leaderboard contribution gate
- **Set:** YYYY-MM-DD (date the leaderboard first goes live with a public URL)
- **Trigger:** No contributor PRs merged into `results/contributors/` within ~3 months of the set date
- **Action options if triggered:** (1) fold the leaderboard back into the README, stop the scheduled matrix, keep the bench harness for internal use; (2) narrow the matrix scope; (3) extend the gate by another window with a recorded reason
- **Action options if not triggered (≥1 contributor PR landed):** continue the scheduled matrix, evaluate whether to widen to additional model classes or engines
- **Review:** On or before YYYY-MM-DD + 3 months, A1 writes a dated note recording the outcome and the chosen action
```

`set` date is filled in when U9 first publishes a public Pages URL (manual edit, not automated — keeps the gate honest by requiring a human acknowledgement that the leaderboard is actually live).

**Patterns to follow:** Match `STRATEGY.md` existing section style (kebab-cased anchors, dated metadata at top of subsection).

**Test scenarios:** None — documentation only.

**Verification:** Section reads clearly and `STRATEGY.md` frontmatter `last_updated` is bumped.

---

## Phasing and Sequencing

Group units into phases for execution clarity. Each phase produces a meaningfully-testable artifact.

**Phase A — Schema foundation** (U1)
Output: the contribution API exists and is enforced by CI design (validation workflow lands in Phase C).

**Phase B — Bench runner** (U2, U3, U4, U5)
Output: a developer can `docker run spark-llm-bench --config qwen27-mtp.yaml` from a shell on the Spark and get a schema-valid result file. No CI yet.

**Phase C — CI workflows** (U6, U7)
Output: weekly canonical bench produces PRs; schema validation blocks bad PRs. Self-hosted runner registered on Spark (operational prereq).

**Phase D — Publication** (U8, U9)
Output: leaderboard generates and publishes on every result-file merge. Public URL live.

**Phase E — Contributor surface + decision gate** (U10, U11)
Output: external contributors have a documented path; gate is set with a date.

Phases A, B, D are independent of CI infra and can be developed entirely on a dev branch. Phases C, E require operational setup (runner registration, Pages configuration).

---

## System-Wide Impact

- **CI surface (new):** Three GitHub Actions workflows. The bench workflow consumes Spark wall-time during runs (paused inference). Documented mitigation: weekly Sunday-morning window.
- **Repo root (new top-level entries):** `schema/`, `bench/`, `leaderboard/`, `results/`, `site/` (gitignored), `Dockerfile.bench`, `CONTRIBUTING-RESULTS.md`. Adds ~6 top-level directories — flagged for review; alternative would be folding under a single `leaderboard/` umbrella, but the four directories have distinct concerns and contributor visibility favors top-level placement.
- **`STRATEGY.md`:** new Decision-gates section.
- **`README.md`:** new leaderboard section between markers; auto-updated by CI.
- **Docker registry pressure:** new `spark-llm-bench` image. Decision: build on-demand in the bench workflow, do not push to a registry until the decision gate fires positively (avoids registry hosting cost while the bet is unproven).
- **Self-hosted runner security:** the runner has write access to the repo via the workflow's `GITHUB_TOKEN`. Standard GitHub-managed scoping applies; documented in U6 as an operational note.

---

## Risk Analysis & Mitigation

- **Self-hosted runner brick risk.** Misconfigured workflow could OOM the Spark and trigger the brick loop documented in `POSTMORTEM.md`. Mitigation: the existing `harden-llm-stack.sh` drop-ins (MemoryMax, OOMPolicy=stop) apply to bench-time slot starts; bench container runs with `--ulimit memlock=-1:-1` already in `docker-llm-switch`; workflow exits cleanly on slot-start failure rather than retrying.
- **Schema lock-in pain.** Getting the v1 schema slightly wrong forces an early v2 bump, which breaks contributors. Mitigation: U1 spends the time to enumerate AE1's exhaustive field list before merging; `additionalProperties: false` enforces additive-only mechanically; the `CHANGELOG.md` discipline starts from day 1.
- **Eval harness brittleness.** EvalPlus / LiveCodeBench / BigCodeBench upstream evolve; a harness update could change scoring rules and silently shift leaderboard numbers. Mitigation: pin exact versions in `bench/requirements.txt`; record the harness version in the result file (schema additive in v1.1 if not in v1.0 — add `quality.harness_versions` as optional v1 field now to avoid the v1.1 ceremony).
- **Pages CSP / sortable.js vendor risk.** GitHub Pages enforces CSP that may reject inline scripts. Mitigation: ship the sortable.js as a separate static file under `leaderboard/static/`, referenced via `<script src=...>`. Tested manually before relying on it.
- **Contributor tampering.** Schema validation can't detect a contributor who fabricated their numbers. Mitigation: deferred to community-management per origin's Dependencies/Assumptions — schema validation catches structural problems only. The `as-reported` labeling makes the trust model visible.
- **Decision-gate ambiguity.** Without a hard date, "~2-3 months" drifts. Mitigation: U11's note demands an explicit `set` date entered at Pages-go-live and a `review` date computed from it.

---

## Scope Boundaries

### Deferred for later

- **vLLM, croll83 fork, other engines beyond llama.cpp+MTP.** Schema and bench-runner are designed engine-agnostic (`engine.name` is a free-form string); harness adapters are llama.cpp-specific. Adding an engine = adding throughput + eval shims, no schema break.
- **Non-coder model classes (vision, audio, image-gen).** Schema's `quality` object is coder-specific in v1; adding a vision-class column set is a v1.x additive change (new optional fields) or a v2 split depending on how the keys land.
- **Cross-Spark result normalization (Approach C from origin).** Deferred until heterogeneity surfaces; schema captures enough metadata (driver, firmware, clock state) to add a normalization layer non-destructively later.
- **Vendor-grade methodology rigor.** Error bars, statistical significance, repeated-run aggregation — none in v1. Schema has space for additive `quality.runs[]` array later.
- **Auto-bisect of upstream llama.cpp regressions.** Thin layer on top of the scheduled bench; defer until a regression actually happens.
- **Authenticated contributor identity.** No signed commits, no GPG, no contributor-ID verification beyond GitHub handle. Trust model = "as-reported" labeling + community management.

### Outside this product's identity

- **General "best LLM" leaderboard.** This is hardware-target-specific (GB10) and engine+config-specific. Not Open LLM Leaderboard, not LiveBench, not LMSYS Chatbot Arena.
- **Model registry / model card host.** Not what this is.
- **Cloud-hosted SaaS leaderboard.** Static GitHub Pages only.

### Deferred to Follow-Up Work

- **Schema v1.1 — `quality.harness_versions` field as optional.** If U3 doesn't include it in v1.0 frontmatter (e.g., if `requirements.txt` pinning feels sufficient at first), add as v1.1 additive — but preferred path is to land it in v1.0 to avoid the version churn.
- **`partial_results` schema flag.** If U10's FAQ surfaces the partial-submission question as common, add as v1.x additive.
- **Internal agent-knowledge-base layer (separate idea, surfaced during planning).** EveryInc/proof-sdk as a central documentation point for agents/etc. to save project information into. Distinct from this public benchmark leaderboard — belongs in its own `/ce-ideate` or `/ce-brainstorm` pass once the leaderboard ships.

---

## Dependencies / Assumptions

- DGX Spark can be configured as a self-hosted GitHub Actions runner. *Unverified — Phase C operational prerequisite. If runner registration is blocked by Tailscale-only networking or firewall constraints, fall back to a self-managed cron + git push from the Spark with `gh` CLI; functionally equivalent at the cost of more bespoke setup.*
- The four eval harnesses (EvalPlus for HumanEval+/MBPP+, official LiveCodeBench, official BigCodeBench) all support OpenAI-compatible endpoints. *Standard assumption — Phase B verifies during U3 implementation.*
- GitHub Pages is acceptable as the publication target. *Origin assumption preserved.*
- The maintainer accepts ~5-7h of inference downtime per week during the bench window. *Origin assumption preserved.*
- `llama-bench` exists in the existing `~/src/llama.cpp-mtp/build/bin/` or can be built standalone in the bench container. *Verified in CLAUDE.md.*

---

## Outstanding Questions (Deferred to Implementation)

- Exact pinned versions of EvalPlus, LiveCodeBench, BigCodeBench packages — resolve during U3 by installing latest stable and checking compatibility against a running `llama-server`.
- Exact sortable.js library or vendored script — resolve during U8 by picking the smallest single-file MIT-licensed option that handles numeric+string sort columns.
- README leaderboard-section placement (above or below the existing "What this is" section) — resolve during U8.
- Whether U9's README update commits directly to `main` with `[skip ci]` or opens an auto-merge PR — resolve during U9 based on whether the auto-update creates noise in the commit log.
- Per-eval timeout values — resolve during U3 by measuring eval wall time on the canonical Spark setup and setting timeouts to 1.5× observed time.

---

## Success Criteria

- The maintainer can answer "what's my throughput on Qwen3.6-27B with current llama.cpp HEAD?" from the leaderboard URL in under 30 seconds, without running anything manually.
- A contributor can produce a valid result file, open a PR, and get it merged into the secondary table by reading only `CONTRIBUTING-RESULTS.md` and `schema/result.v1.schema.json`.
- A drive-by reader scanning the leaderboard identifies the best-throughput configuration for their model class within one minute and can tell which numbers come from which Spark.
- The decision gate has a clear `set` and `review` date in `STRATEGY.md` — no ambiguity about when the canonical-source bet's outcome is evaluated.
- `ce-work` (the next skill) can execute this plan unit-by-unit without needing to invent product behavior or resolve schema-design questions.
