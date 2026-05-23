# docker/tests/

Lightweight, dependency-light smoke runner for the docker path. Single
shell entrypoint, no Python/Node/pytest baggage — just `bash`, `curl`,
`jq`, `docker`.

## Quick reference

```bash
docker/tests/smoke.sh all                    # run everything in order (slow; cycles slots)
docker/tests/smoke.sh static                 # bash -n + compose validate (no hardware needed)
docker/tests/smoke.sh slots                  # mutual exclusion across all slots
docker/tests/smoke.sh health <slot>          # bring slot up, wait until /health is 200
docker/tests/smoke.sh prompt <slot>          # send a real chat completion, verify response
docker/tests/smoke.sh hardening <slot>       # docker inspect parity (Memory, OomScoreAdj, NetworkMode)
docker/tests/smoke.sh flux                   # FLUX /img_gen submit-poll-decode end-to-end
docker/tests/smoke.sh comfyui                # ComfyUI /system_stats + GB10 patch banner check
docker/tests/smoke.sh bench <slot> [n_gen]   # llama-bench inside the running container
docker/tests/smoke.sh bad-ref                # ensure typo'd --build-arg refs fail builds
```

`<slot>` is one of `coder | architect | vision | gemma | gptoss |
imagine | comfyui`. Prompt and bench only work on llama slots
(coder/architect/vision/gemma/gptoss).

## Output

Every check prints one of:

- `PASS <description>` — assertion held
- `FAIL <description> (command)` — exit non-zero, summary at the end is non-zero
- `SKIP <reason>` — intentionally skipped (e.g. bench on gptoss, which has no GGUF path to read)

A summary line at the end gives counts. Script exits `0` iff `FAIL_COUNT == 0`.

## Typical pre-merge run

On the Spark host, from the repo root:

```bash
# 1. Free, fast checks first
docker/tests/smoke.sh static

# 2. Spin slots and verify they each respond
docker/tests/smoke.sh all

# 3. Optional: bench the slot you touched
docker/tests/smoke.sh bench coder
```

For changes that touch `--build-arg` plumbing or the clone step in any
Dockerfile, also run:

```bash
docker/tests/smoke.sh bad-ref     # ~3 docker builds, slow but cheap (fail-fast on first git clone)
```

## What this runner does *not* cover

- **Host firmware** — `nvidia-smi -lgc` / `-pm 1` / `--vboost` aren't
  persistent across reboots. See [`SMOKE-TESTS.md` §0](../SMOKE-TESTS.md#0-host-gpu-setup-mandatory-on-every-fresh-boot).
- **Custom-node persistence across `docker rmi` + rebuild** — manual,
  destructive, slow. See `SMOKE-TESTS.md` §4.
- **`sudo systemctl restart docker` daemon-restart survival** — bounces
  every container on the box; deliberately not in `all`. See `SMOKE-TESTS.md` §5.
- **Tailscale reachability from a peer** — `127.0.0.1` isn't a proxy for
  tailnet routing; verify from another tailnet member by hand. See
  `SMOKE-TESTS.md` §3.

## Adding a check

`smoke.sh` is intentionally one file. Add a new `cmd_<name>()` function
near its siblings and wire it into the `case` block in `main()`. Use
the existing helpers:

- `assert "<desc>" <cmd...>` — PASS on exit 0, FAIL otherwise
- `refute "<desc>" <cmd...>` — PASS on non-zero (for "must fail" checks)
- `wait_for_url <url> <timeout> <desc>` — polls until 200 or times out
- `pass <msg>` / `fail <msg>` / `skip <msg>` — direct counter updates

Keep checks idempotent: every command should be safe to re-run, and
nothing should leave the box in a worse state than it started.
