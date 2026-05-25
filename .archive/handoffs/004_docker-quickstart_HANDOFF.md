# Handoff: Docker quickstart, Tailscale docs, smoke-test suite, benchmarking docs

**Generated**: 2026-05-23
**Branch**: `dev` (clean, in sync with `origin/dev`)
**Status**: Ready for Review — all session work committed and pushed

## Goal

Over the session, the user asked for a sequence of improvements to the
`spark-llm-stack` docker path: review the advisory `HANDOFF.md` (sudoers
drop_caches), wrap install steps in scripts, fix the Docker build
failures introduced by switching to `cmake --install`, expand the docker
README into a real start-to-finish quickstart (build → prompt → FLUX →
ComfyUI → Tailscale), then refine the smoke tests into an automated
runner and document benchmarking + tunable knobs.

## Completed

- [x] Reviewed prior advisory HANDOFF.md and archived it to `.archive/003_drop-caches-sudoers_HANDOFF.md` with a resolution footer
- [x] `systemd/install-drop-caches-sudoers.sh` — NOPASSWD sudoers rule using the canonical `tee` pattern (the `sh -c "sync; echo 3 > …"` form documented previously could never have worked — sudoers parses `;`)
- [x] `systemd/install-earlyoom-failsafe.sh` — copy-based installer for spark-mem.sh + spark-panic + the unit file (intentional opposite policy from the user-CLI installer)
- [x] `tools/install-user-cli.sh` — symlink-based installer for `docker-llm-switch`, `llm-switch`, `flux-gen` (symlinks here because they're user-shell dev tools that should track HEAD)
- [x] Fixed Docker build chain: `cmake --component Runtime` → drop component, then `-DLLAMA_BUILD_TESTS=OFF` + `-DLLAMA_BUILD_EXAMPLES=OFF` + drop `--target` so build-set and install-set stay in sync
- [x] `docker/BUILD-TUNING.md` — separates GB10 perf flags (Group 1, untouchable) from build/install bookkeeping (Group 2). Includes a self-contained prompt that drives a future model through narrowing the filter further if rebuild time becomes a bottleneck
- [x] `docker/README.md` quickstart rewritten as 9-step build → prompt walkthrough with worked examples for every llama slot (correct aliases from `docker-llm-switch`), FLUX raw-HTTP submit-poll under `<details>`, ComfyUI `/prompt`→`/history`→`/view` round-trip, and a Tailscale section
- [x] `docker/tests/smoke.sh` + `docker/tests/README.md` — single-file dependency-light test runner with subcommands `static / bad-ref / slots / health / prompt / flux / comfyui / hardening / bench / all`
- [x] `docker/SMOKE-TESTS.md` rewritten as manual companion to the runner; fixed three real inaccuracies in the old version
- [x] `README.md` gains "Reproducing the numbers (llama-bench)" and "Tunable knobs — what's safe to change vs what's load-bearing" sections
- [x] Code-reviewer agent review pass; three issues caught and fixed in commit `38686e5`

## Not Yet Done

- [ ] Actually run `docker/tests/smoke.sh all` on the live Spark host — has only been syntax-checked + reviewed, never executed end-to-end against real containers
- [ ] Verify the `.timings` field name for MTP accept-rate on the binary actually running on the host (README hedges on this; the user could pin it down with one curl call)
- [ ] Decide whether `docker/docker-compose.yml` should default `LLAMA_REF` to the MTP branch instead of `master` — currently a documented footgun (build → mainline → 20% slower than systemd path)
- [ ] Tailscale ACL examples — left out deliberately because the JSON shape changes frequently; user can request if needed

## Failed Approaches (Don't Repeat These)

- **`cmake --install build --component Runtime`** (commit `0cc8457`'s original fix) — llama.cpp upstream's `install()` rules aren't tagged with a `Runtime` component, so the filter installed nothing. `/install` was never created and the runtime stage's `COPY --from=builder /install /usr/local` failed with a cryptic buildkit cache-key error. Fix: drop `--component`.
- **`cmake --install build` with `--target llama-server llama-bench` filter** — the install rules llama.cpp generates apply to whatever subdirectories cmake configured, not whatever targets `--build` produced. `cmake --install` then tries to install `test-tokenizer-0` (and later `llama-batched`) which weren't built. Fix: disable subdirs at *configure* time (`-DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF`) and drop `--target` so the built set matches the installed set.
- **Per-file `COPY --from=builder /build/llama.cpp/build/bin/<binary>`** (pre-commit `0cc8457`) — misses shared libraries like `libllama-server-impl.so`. Don't revert to this; the comment block above the COPY in `docker/Dockerfile` documents why.
- **Symlinks under `/usr/local/` for the OOM failsafe** — earlyoom runs as a root system service and invokes spark-panic at OOM pressure; reading through a symlink into `$HOME/Dev/...` is fragile (home not mounted, encrypted, automount lag) and lets a `git checkout` mutate the live failsafe code under the running service. Install-by-copy is the correct policy *for system services*. The opposite policy (symlinks) is correct for `~/.local/bin/` user tools.
- **`trap 'rm -f "$tmp"' EXIT` inside a function that declared `tmp` as `local`** — when the trap fires at script exit, the function has returned and `$tmp` is unbound, so `set -u` errors *after* the install otherwise succeeded. Use `${tmp:-}` defensively.
- **Bare `[[ $FAIL_COUNT -gt 0 ]] && return` guard** in `smoke.sh`'s `cmd_prompt` — globally short-circuits on any prior failure anywhere in the run. Snapshot `FAIL_COUNT` *before* the dependent call and compare against the snapshot.
- **`.data[]?.id == "$alias"` for jq existence check** — only passes if the *last* element matches (`jq -e` tests the last emitted value). Use `any(.data[]?; .id == $a)` for order-independence.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| Two installer scripts with opposite policies (copy for failsafe, symlink for user CLIs) | System services vs dev tools have different blast radii — see installer header comments for the full reasoning |
| Drop `--target` from cmake build; disable subdirs at configure time | Keeps built-set and installed-set in sync automatically; immune to upstream adding new examples/tests |
| Build/install bookkeeping documented separately from GB10 perf tuning | Easy to conflate because they live in the same `RUN` block. `docker/BUILD-TUNING.md` makes the split explicit |
| Smoke runner is single-file shell, not pytest | Repo has no Python test infra; shell+curl+jq+docker is already required by the rest of the project |
| Runner exits non-zero on any FAIL but doesn't `set -e` | FAIL is a counted state — we want every check to run even if earlier ones failed; final exit is `[[ $FAIL_COUNT -eq 0 ]]` |
| `--reasoning` knob in README documented as `on`/`off` only | Actual configs in `docker-llm-switch` only use those two values; "low/medium/high" was a hallucination during review |
| Tailscale Funnel called out as *do not enable* on these ports | Funnel exposes a service to the public internet — would publish an unauthenticated llama-server. Serve stays inside the tailnet and is fine |

## Current State

**Working**: All commits on `dev`. Repo clean. Last 4 commits in this session:

```
38686e5 test(docker): fix smoke runner issues caught in review
588179a test(docker): automated smoke runner + refined manual checklist; benchmarking docs
[earlier commits in this session: Dockerfile fixes, installer scripts, docker README, README knobs]
```

**Broken**: Nothing known. Smoke runner has not been executed against a live host — only `bash -n` syntax check + code-reviewer pass.

**Uncommitted Changes**: None.

## Files to Know

| File | Why It Matters |
|------|----------------|
| `docker/tests/smoke.sh` | Main automated test runner — subcommand-based, single file |
| `docker/tests/README.md` | How to use the runner; lists what it does NOT cover |
| `docker/SMOKE-TESTS.md` | Manual checklist; companion to the runner (firmware lock, custom-node persistence, daemon-restart survival) |
| `docker/BUILD-TUNING.md` | GB10 perf flags vs build-set bookkeeping; includes auto-narrow LLM prompt |
| `docker/Dockerfile` | Top comment block documents the two gotchas: don't add `--component Runtime`, must keep `LLAMA_BUILD_TESTS=OFF` + `LLAMA_BUILD_EXAMPLES=OFF` |
| `docker/README.md` | 9-step end-to-end quickstart, per-slot prompt examples, FLUX/ComfyUI raw HTTP, Tailscale section |
| `README.md` | "Reproducing the numbers (llama-bench)" + "Tunable knobs" sections |
| `systemd/install-earlyoom-failsafe.sh` | Copy-based installer (root system service) |
| `systemd/install-drop-caches-sudoers.sh` | NOPASSWD rule with `tee` pattern + `visudo -c -f` validation |
| `tools/install-user-cli.sh` | Symlink-based installer (user-shell dev tools) |
| `docker/docker-llm-switch` lines 68-92 | Canonical PORTS / ROLES / MEMCAP table — `smoke.sh` mirrors `MEMCAP_GB` from here |

## Code Context

**smoke.sh assertion helpers** — single source of truth for PASS/FAIL accounting:

```bash
assert "<desc>" <cmd...>      # PASS if cmd exits 0
refute "<desc>" <cmd...>      # PASS if cmd exits non-zero (for must-fail checks)
wait_for_url <url> <timeout> <desc>   # poll-until-200
pass / fail / skip <msg>      # direct counter updates
```

**Per-slot canonical values** (mirror docker-llm-switch):

```bash
PORTS=( [coder]=8152 [architect]=8154 [vision]=8155 [gemma]=8156
        [gptoss]=8157 [imagine]=8160 [comfyui]=8188 )
ALIAS=( [coder]="qwen3.6-27b-coder" [architect]="qwen3.6-35b-architect"
        [vision]="gemma4-vision" [gemma]="gemma4-31b" [gptoss]="gpt-oss-20b" )
MEMCAP_GB=( [coder]=80 [architect]=80 [gemma]=80 [vision]=20 [gptoss]=40
            [imagine]=16 [comfyui]=40 )
```

If these ever drift from `docker/docker-llm-switch` lines 68-92, the
hardening parity check produces false failures — update both.

## Resume Instructions

1. **Smoke-test the runner on the live Spark host:**
   ```bash
   cd ~/Dev/spark-llm-stack
   git pull
   docker/tests/smoke.sh static     # zero-hardware, runs anywhere
   docker/tests/smoke.sh all        # spins each slot in turn — slow
   ```
   - Expected: every PASS, summary `N passed, 0 failed, 0 skipped`, exit 0
   - If FAIL on hardening parity: check `MEMCAP` in `docker-llm-switch:89` matches `MEMCAP_GB` in `smoke.sh:25`
   - If FAIL on prompt round-trip: the slot might be slow to load — bump `READY_TIMEOUT_DEFAULT` (currently 180s)
   - If FAIL on ComfyUI banner: GB10 unified-memory patch may not have applied; check `docker logs spark-llm-comfyui | grep -iE 'aimdo|sageattention'`

2. **Confirm the MTP timings field name once a slot is running:**
   ```bash
   docker-llm-switch coder
   curl -s http://127.0.0.1:8152/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"qwen3.6-27b-coder","max_tokens":32,
          "messages":[{"role":"user","content":"hi"}]}' \
     | jq '.timings'
   ```
   - Look for the draft-acceptance field — likely `draft_accept_n` / `draft_total` or `n_draft_accept`
   - Update `README.md`'s "Reproducing the numbers" section to name it precisely instead of hedging

3. **Decide MTP default:** if `llama-bench tg128` on mainline is still <26 t/s, flip `docker/docker-compose.yml`'s `LLAMA_REF` default to the MTP branch ref (and document the opt-out for whoever wants mainline)

4. **Optional follow-ups flagged in the BUILD-TUNING.md prompt:** if rebuild time is a bottleneck, paste that prompt into a coding-capable model with the repo mounted and let it narrow the build/install filter

## Warnings

- **Mainline llama.cpp build is the current default** — `docker compose build llama` produces a binary ~20% slower than the systemd path's pre-merge MTP branch. Documented but not fixed. See `docker/Dockerfile` lines 8-13 + README.md "Binary note".
- **`smoke.sh bench <slot>` stops the server while llama-bench runs** — the slot is unavailable for chat during the bench. Don't run it while users are connected.
- **`smoke.sh bad-ref`** kicks off three full `docker build` runs that should each fail at the `git clone --branch` step (~10s each). Don't run it under time pressure.
- **`tools/install-user-cli.sh` refuses to clobber a regular file** at `~/.local/bin/llm-switch` etc. — if a previous install used `cp`, manually `rm` the file first.
- **`--no-mmap` and `--mlock` must never appear** in any llama service unit or `CMD_<slot>=()` block on this host. Unified-memory constraint. Documented in `CLAUDE.md` and the new "Frozen knobs" table.
- **Don't enable Tailscale Funnel** on slot ports — would publish an unauthenticated llama-server to the public internet. Tailscale Serve is fine (stays inside the tailnet).

---

## Resolution (2026-05-25)

The session's deliverables (`docker/tests/smoke.sh`, `docker/BUILD-TUNING.md`,
`docker/README.md` quickstart, `tools/install-user-cli.sh`,
`systemd/install-earlyoom-failsafe.sh`,
`systemd/install-drop-caches-sudoers.sh`) all shipped to `dev` and are in use.

Outstanding items from "Not Yet Done" in this handoff that were carried into
later sessions:

- `docker/tests/smoke.sh all` — has now been run live on the Spark host
  (see follow-up commits on `dev`).
- `.timings` field name for MTP draft-accept — pinned down when the coder
  slot was instrumented in the `docker-llm-switch usage` subcommand
  (see `docker/docker-llm-switch:show_usage_watch`).
- `LLAMA_REF` default in `docker/docker-compose.yml` — mainline MTP merged
  upstream on 2026-05-16, but Qwen3.6 MTP has a known crash bug documented
  in [`gremlins/02_QWEN36-27B-MTP-CUDA-CRASH.md`](../../gremlins/02_QWEN36-27B-MTP-CUDA-CRASH.md).
  The branch-vs-mainline distinction is now moot for that bug.
- Tailscale ACL examples — still deliberately omitted.
