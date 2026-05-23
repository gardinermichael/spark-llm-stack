# Docker smoke tests

This file is the **manual checklist** that has to pass on a real GB10
host before any change under `docker/` is shippable. Most of it is
automated by [`docker/tests/smoke.sh`](tests/smoke.sh) (see
[`docker/tests/README.md`](tests/README.md)); the steps below cover the
host-firmware and human-eye checks the script can't do on its own.

CI (`.github/workflows/docker.yml`) only does Dockerfile lint + a Scout
base-image scan — GitHub runners have no NVIDIA GPU, so the actual
binary cannot be exercised in CI.

Run from the repo root.

## TL;DR — run everything the runner can

```bash
docker/tests/smoke.sh all          # static + slots + prompts + hardening + flux + comfyui
docker/tests/smoke.sh bench coder  # optional: throughput numbers (stops the slot)
```

If `all` exits 0, the only remaining items below are the ones the
runner intentionally does not automate (host firmware, custom-node
persistence across rebuilds, boot-default daemon restart).

---

## 0. Host GPU setup (mandatory on every fresh boot)

GB10 firmware does **not** persist GPU clock or power settings across
reboots, and a power spike during a long workflow (LTX, FLUX, heavy
prefill) can hard-crash the host. Re-apply on every boot before
exercising any slot:

```bash
sudo nvidia-smi -lgc 3003,3003           # lock SM clocks to max (prevents throttling + spikes)
sudo nvidia-smi boost-slider --vboost 1  # core-clock boost for compute workloads
sudo nvidia-smi -pm 1                    # persistence mode (reduces driver load latency)
```

Verify (under load — idle clocks won't reach the lock):

```bash
# Locked range survives reboots only if -lgc was issued THIS boot.
nvidia-smi --query-gpu=clocks.gr,clocks.max.gr,clocks.applications.gr,persistence_mode \
           --format=csv,noheader

# Then start a slot and prefill something:
docker-llm-switch coder
curl -s http://127.0.0.1:8152/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-27b-coder","max_tokens":256,
       "messages":[{"role":"user","content":"Count to 256 in English."}]}' >/dev/null &

# In another terminal: clocks.gr should track clocks.applications.gr
watch -n 0.5 'nvidia-smi --query-gpu=clocks.gr,clocks.applications.gr --format=csv,noheader'
```

Expected: `clocks.gr` matches `clocks.applications.gr` during the
prefill burst; persistence mode is `Enabled`.

Source: NVIDIA Developer forum thread "Unlocking the Power of the Spark
In ComfyUI (No Crashes)". See `docs/architecture/DECISIONS.md` §"GPU
clock-lock as an ops step".

---

## 1. Static + bad-ref + slots + prompts + hardening + FLUX + ComfyUI

Automated:

```bash
docker/tests/smoke.sh all
```

What it covers — one PASS/FAIL line per check:

| Step | What's asserted |
|---|---|
| `static` | All shell scripts parse (`bash -n`); compose YAML validates. |
| `slots` | Switching to each slot leaves **exactly one** `spark-llm-*` container running; `off` leaves zero. |
| `prompt <slot>` | `/health` reaches 200; `/v1/models` advertises the slot's `--alias`; a real `/v1/chat/completions` call returns `.choices[0].message.content` with non-empty content. Runs per llama slot. |
| `hardening <slot>` | `NetworkMode=host`, `OomScoreAdj=200`, `Memory` byte count matches the per-slot `MEMCAP` in `docker-llm-switch`. |
| `flux` | Submits to `/sdcpp/v1/img_gen`, polls `/sdcpp/v1/jobs/<id>` until `completed`, decodes the base64 PNG, verifies non-empty bytes. |
| `comfyui` | `/system_stats` reachable; container logs contain the `aimdo`/`DynamicVRAM` banner (proves the GB10 unified-memory patch applied) and a SageAttention init line. |

Run individual subcommands when iterating — see [tests/README.md](tests/README.md).

---

## 2. Bad-ref regression (separate run; slow, no cache)

`smoke.sh bad-ref` is not in `all` because it kicks off three full
`docker build` runs that should each fail near the start (the `git
clone --branch ${REF}` step is hard-failing). Run it after any change
that touches `--build-arg` handling or the clone command:

```bash
docker/tests/smoke.sh bad-ref
```

Expected: all three subcommands report PASS by **failing** their docker
build (refute logic — `LLAMA_REF=no-such-ref` must not silently fall
through to `master`).

---

## 3. Tailscale reachability (manual — needs a peer)

The runner only hits `127.0.0.1`. Confirm that the same endpoints work
from another tailnet member, since `--network=host` is the only thing
making that work:

```bash
# On a different machine joined to the tailnet:
SPARK=spark                # MagicDNS shortname or 100.x.y.z

curl -sf "http://${SPARK}:8152/health"                          # coder llama
curl -sf "http://${SPARK}:8160/sdcpp/v1/capabilities"           # imagine
curl -sf "http://${SPARK}:8188/system_stats"                    # comfyui
```

Expected: all three return 200 from the peer. If any fails while
`127.0.0.1` works on the Spark, debug the host firewall / Tailscale ACL
before anything else.

---

## 4. Custom-node persistence across rebuild (manual — slow, destructive)

The `cp -n` seed in `docker/comfyui/entrypoint.sh` is supposed to
*never* clobber user-installed nodes. Verify across a full rebuild:

```bash
docker-llm-switch comfyui
ls ~/comfyui/custom_nodes/             # ComfyUI-Manager should be present
# Open http://<host>:8188 → Manager → install any test node
docker-llm-switch off
docker rmi spark-llm-comfyui
docker compose -f docker/docker-compose.yml build comfyui
docker-llm-switch comfyui
ls ~/comfyui/custom_nodes/             # the test node must still be there
```

Expected: user-installed nodes survive image rebuild. If they vanish,
the `cp -n` regressed to `cp` somewhere.

---

## 5. Boot-default daemon-restart survival (manual — bounces all containers)

Verifies the codex P1 fix (commit `4830f2c`) that ties one slot to
`--restart unless-stopped` so it auto-recovers when Docker bounces:

```bash
docker-llm-switch boot-default architect
docker inspect spark-llm-architect --format '{{.HostConfig.RestartPolicy.Name}}'
# expected: unless-stopped

sudo systemctl restart docker        # WILL bounce every container

# ~30 s later:
docker ps --format '{{.Names}}'      # spark-llm-architect should be back
```

Expected: `architect` is running again. If it isn't, the boot-default
policy isn't sticking to the slot the way `boot-default` intends.

### 5b. Boot-default survives off → start cycle

Codex P2 regression guard (commit history under `docker-llm-switch:
run_slot`):

```bash
docker-llm-switch boot-default architect
docker-llm-switch boot-status        # expected: architect enabled
docker-llm-switch off
docker-llm-switch architect          # must docker-start in place, not recreate with --rm
docker inspect spark-llm-architect --format \
  '{{.HostConfig.RestartPolicy.Name}} {{.HostConfig.AutoRemove}}'
# expected: unless-stopped false
docker-llm-switch boot-status        # expected: architect still enabled
```

Expected: stopping and restarting a boot-default slot preserves the
`--restart unless-stopped` policy. If `boot-status` loses the slot
after the first `off` → start cycle, `run_slot` recreated the
container with `--rm` instead of starting in place.

---

## When to re-run

- **Every PR** that touches `docker/**`, `tools/flux-gen`,
  `tools/install-user-cli.sh`, `systemd/install-*.sh`, or any
  `systemd/units/*.service` file → `smoke.sh all` minimum.
- **Base-image bumps** (`CUDA_VERSION`, `UBUNTU_VERSION`) → add
  `smoke.sh bad-ref` and verify `clocks.gr` under load (step 0
  hardware sanity).
- **PyTorch / SageAttention / ComfyUI ref bumps** → `smoke.sh comfyui`
  plus step 4 (custom-node persistence).
- **`docker-llm-switch` changes** → `smoke.sh slots` plus step 5
  (daemon-restart survival).

If a smoke step fails, file the breakage with the failing command's
output before retrying.
