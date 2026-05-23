# docker/

Docker path for spark-llm-stack. Same seven-slot model roster as the systemd
path, containerized. Three images: `spark-llm-stack` (llama slots),
`spark-llm-imagine` (FLUX via sd-server), `spark-llm-comfyui` (ComfyUI).

For the autoresearch launcher see [`autoresearch/README.md`](autoresearch/README.md).

---

## Before you begin (read — it prevents a brick)

- **Single-slot rule**: running more than one heavyweight slot exhausts the
  128 GB unified memory pool and triggers an OOM respawn brick loop. Always
  use `docker-llm-switch` or `./run.sh` — never raw `docker run`. See
  [gremlins/00_POSTMORTEM.md](../gremlins/00_POSTMORTEM.md).
- **Requirements**: NVIDIA driver 580+, CUDA 13.0+, NVIDIA Container Toolkit,
  Docker with `--gpus=all` working (`docker run --rm --gpus=all nvidia/cuda:13.2.0-base-ubuntu24.04 nvidia-smi`).
- **Disk**: ~20 GB for all three images + model weights (~80 GB full roster).

---

## Model downloads (one-time, before first run)

Models live on the host at `~/models/` and are bind-mounted into containers at `/models`.

### Download all llama models at once (~61 GB total)

```bash
mkdir -p ~/models

# NOTE: "MTP" appears in HuggingFace repo names but NOT in the filenames inside.
hf download unsloth/Qwen3.6-27B-MTP-GGUF  Qwen3.6-27B-UD-Q4_K_XL.gguf      --local-dir ~/models  # coder     ~17 GB
hf download unsloth/Qwen3.6-35B-A3B-MTP-GGUF Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf --local-dir ~/models  # architect ~22 GB
hf download unsloth/gemma-4-31B-it-GGUF    gemma-4-31B-it-UD-Q4_K_XL.gguf   --local-dir ~/models  # gemma     ~19 GB
hf download unsloth/gemma-4-E4B-it-GGUF    gemma-4-E4B-it-UD-Q4_K_XL.gguf   --local-dir ~/models  # vision    ~3 GB
```

Notes:
- `gptoss` uses `--gpt-oss-20b-default` — a built-in flag in the MTP llama.cpp
  binary; no GGUF download needed.
- `hf` is the HuggingFace CLI (`huggingface-cli` is deprecated). Install with: `pip install huggingface_hub[cli]`
- For FLUX/imagine model files (~17 GB) see the [FLUX section](#flux2-klein-model-files) below.

---

## Quickstart (build → first response)

Run everything from the **repo root** unless a step says otherwise.

### 1. Build the three images

```bash
# Build context is the repo root so tools/flux-gen is reachable.
# Override LLAMA_REF / COMFYUI_REF / SD_REF via --build-arg to pin a commit.
docker compose -f docker/docker-compose.yml build

# Build a single image:
# docker compose -f docker/docker-compose.yml build comfyui
# docker compose -f docker/docker-compose.yml build imagine
# docker compose -f docker/docker-compose.yml build llama
```

The `llama` builder stage compiles llama.cpp with GB10-tuned cmake flags
(`-DCMAKE_CUDA_ARCHITECTURES=121a-real`, `-DGGML_CPU_KLEIDIAI=ON`, flash
attention + matmul-quant kernels). The `comfyui` build compiles
SageAttention from source against `sm_121a` and is the slowest stage
(~15–25 min on first run, cached afterwards).

### 2. Install the user-shell CLI tools (one-time)

```bash
tools/install-user-cli.sh        # symlinks docker-llm-switch, llm-switch, flux-gen into ~/.local/bin/
tools/install-user-cli.sh --check
```

Symlinks (not copies) — these are dev tools, and `git pull` should refresh
them immediately. The opposite policy applies to the OOM failsafe below,
which is installed by copy because it's a root system service.

### 3. Install the OOM failsafe (recommended, one-time, root)

```bash
sudo systemd/install-earlyoom-failsafe.sh    # earlyoom + spark-panic + spark-mem.sh
sudo systemd/install-drop-caches-sudoers.sh  # NOPASSWD rule for page-cache flush
systemd/install-earlyoom-failsafe.sh --check
```

Without these, two heavyweight slots running simultaneously can brick the
box via OOM respawn — see [gremlins/00_POSTMORTEM.md](../gremlins/00_POSTMORTEM.md).

### 4. Verify the model files are present

Containers bind-mount `~/models` → `/models`. The slot you start needs the
matching GGUF on disk (`gptoss` is the exception — it uses a built-in flag
in the MTP binary and downloads nothing).

```bash
ls ~/models/
```

Missing files? See the [Model downloads](#model-downloads-one-time-before-first-run)
section above (llama GGUFs) or [FLUX.2-klein model files](#flux2-klein-model-files)
(imagine/comfyui weights).

### 5. Start a slot

`docker/run.sh` calls `docker-llm-switch` under the hood — it stops every
other `spark-llm-*` container first (mutual exclusion is enforced), then
starts the requested slot.

```bash
./docker/run.sh                  # coder (Qwen3.6-27B, :8152) — default
./docker/run.sh architect        # architect (Qwen3.6-35B MoE, :8154)
./docker/run.sh gemma            # gemma 31B (:8156)
./docker/run.sh vision           # gemma vision 4B (:8155)
./docker/run.sh gptoss           # GPT-OSS-20B (:8157)
./docker/run.sh imagine          # FLUX.2-klein via sd-server (:8160)
./docker/run.sh comfyui          # ComfyUI (:8188)
```

First load takes 30–90 s depending on slot. Watch logs with
`docker logs -f spark-llm-<slot>` if you want progress.

### 6. Proof of life

```bash
# Llama slots — returns {"status":"ok"} once the model is fully loaded
curl -s http://127.0.0.1:8152/health          # coder
curl -s http://127.0.0.1:8154/health          # architect
curl -s http://127.0.0.1:8155/health          # vision
curl -s http://127.0.0.1:8156/health          # gemma
curl -s http://127.0.0.1:8157/health          # gptoss

# /v1/models confirms the alias the server is advertising
curl -s http://127.0.0.1:8152/v1/models | jq

# Imagine + ComfyUI use their own endpoints
curl -s http://127.0.0.1:8160/health          # imagine — FLUX sd-server
curl -s http://127.0.0.1:8188/system_stats    # comfyui
```

### 7. Send your first prompt

Llama slots speak the **OpenAI chat-completions API** on `/v1/chat/completions`.
Auth is disabled — no API key needed. The `model` field is matched loosely
against the slot's `--alias` but is recorded in server logs, so use the
correct alias for legibility.

**Coder slot (default):**

```bash
curl -s http://127.0.0.1:8152/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b-coder",
    "messages": [{"role": "user", "content": "Write a Python function that reverses a string."}]
  }' | jq -r '.choices[0].message.content'
```

**Architect slot** (deeper reasoning, slower):

```bash
curl -s http://127.0.0.1:8154/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-35b-architect",
    "messages": [{"role": "user", "content": "Design a rate-limiting strategy for a multi-tenant API."}]
  }' | jq -r '.choices[0].message.content'
```

**Gemma slot:**

```bash
curl -s http://127.0.0.1:8156/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-31b",
    "messages": [{"role": "user", "content": "Summarise the differences between TCP and QUIC."}]
  }' | jq -r '.choices[0].message.content'
```

**Vision slot** (multimodal — accepts images via `image_url`):

```bash
# Text only
curl -s http://127.0.0.1:8155/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-vision",
    "messages": [{"role": "user", "content": "What can you do?"}]
  }' | jq -r '.choices[0].message.content'

# Image + text (base64-inlined; URL form also works)
IMG_B64=$(base64 -w 0 < /path/to/image.png)
curl -s http://127.0.0.1:8155/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gemma4-vision\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\",      \"text\": \"Describe this image.\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,${IMG_B64}\"}}
      ]
    }]
  }" | jq -r '.choices[0].message.content'
```

**GPT-OSS slot:**

```bash
curl -s http://127.0.0.1:8157/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss-20b",
    "messages": [{"role": "user", "content": "Explain how speculative decoding works."}]
  }' | jq -r '.choices[0].message.content'
```

**Streaming** (token-by-token via SSE) — works on every llama slot:

```bash
curl -N http://127.0.0.1:8152/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b-coder",
    "stream": true,
    "messages": [{"role": "user", "content": "Count from 1 to 10."}]
  }'
```

**One-liner pattern** (escape-free, takes prompt from a pipe):

```bash
echo "Explain the GB10 unified memory model" | \
  jq -Rs '{model:"qwen3.6-27b-coder", messages:[{role:"user", content:.}]}' | \
  curl -s http://127.0.0.1:8152/v1/chat/completions \
    -H "Content-Type: application/json" -d @- | \
  jq -r '.choices[0].message.content'
```

**Imagine slot** — FLUX async API. The `flux-gen` CLI wraps the
submit-then-poll dance and is the easiest path:

```bash
flux-gen "a pixel art sword icon, white background"             # defaults: 512x512, 4 steps
flux-gen "moody cyberpunk alley at night" 1024 1024 8 42        # w h steps seed
FLUX_HOST=http://<spark-tailscale-ip>:8160 flux-gen "remote"    # remote server
```

Output PNGs land in `~/flux-output/`.

<details><summary>Raw HTTP (for non-bash callers)</summary>

Three endpoints under `/sdcpp/v1/`:

```bash
# 0. Server up?
curl -s http://127.0.0.1:8160/sdcpp/v1/capabilities | jq

# 1. Submit a job — returns {"id": "<job-id>"}
JOB=$(curl -s http://127.0.0.1:8160/sdcpp/v1/img_gen \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "pixel art sword icon, white background",
    "width": 512,
    "height": 512,
    "batch_count": 1,
    "seed": -1,
    "sample_params": {
      "sample_steps": 4,
      "sample_method": "euler",
      "guidance": {"txt_cfg": 1.0, "distilled_guidance": 3.5}
    }
  }' | jq -r .id)
echo "job=$JOB"

# 2. Poll until status flips out of "running"/"queued"
while :; do
  STATUS=$(curl -s "http://127.0.0.1:8160/sdcpp/v1/jobs/$JOB" | jq -r .status)
  echo "  status=$STATUS"
  case "$STATUS" in completed|failed|cancelled) break;; esac
  sleep 0.5
done

# 3. Pull the base64-encoded PNG out of the result and decode it
curl -s "http://127.0.0.1:8160/sdcpp/v1/jobs/$JOB" \
  | jq -r '.result.images[0].b64_json' \
  | base64 -d > out.png
```

`seed: -1` means random. `sample_method` accepts `euler`, `euler_a`, `heun`,
etc. (sd.cpp samplers). `guidance.distilled_guidance` is the FLUX-specific
distilled CFG — `3.5` is a sane default for klein; bump for sharper
prompt-adherence, lower for more creative drift.

</details>

**ComfyUI slot** — graph-based, not chat. Open `http://localhost:8188/` in
a browser and use the node editor for interactive work. For programmatic
calls, ComfyUI exposes a JSON workflow API:

```bash
# 0. Server up?
curl -s http://127.0.0.1:8188/system_stats | jq

# 1. Build a client_id (any UUID-ish string) and submit a workflow.
#    Export your graph from the UI: Settings -> "Enable Dev mode Options",
#    then "Save (API Format)" — that JSON is what goes in `prompt` below.
CLIENT_ID=$(uuidgen)
PROMPT_ID=$(curl -s http://127.0.0.1:8188/prompt \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg cid "$CLIENT_ID" --slurpfile wf workflow.api.json \
        '{client_id: $cid, prompt: $wf[0]}')" \
  | jq -r .prompt_id)
echo "prompt=$PROMPT_ID"

# 2. Poll history until the job appears (it lands once execution finishes)
while :; do
  RESULT=$(curl -s "http://127.0.0.1:8188/history/$PROMPT_ID")
  [[ "$RESULT" != "{}" ]] && break
  sleep 1
done

# 3. Pull the output filenames out of the history and download via /view
echo "$RESULT" \
  | jq -r --arg id "$PROMPT_ID" '
      .[$id].outputs[] | .images[]? |
      "\(.filename)\t\(.subfolder // "")\t\(.type // "output")"' \
  | while IFS=$'\t' read -r fname subfolder type; do
      curl -s -G "http://127.0.0.1:8188/view" \
        --data-urlencode "filename=$fname" \
        --data-urlencode "subfolder=$subfolder" \
        --data-urlencode "type=$type" \
        -o "$fname"
      echo "saved: $fname"
    done
```

The official endpoint catalogue (`/prompt`, `/history`, `/queue`, `/view`,
`/object_info`, the WebSocket progress feed) is documented at
[docs.comfy.org/development/comfyui-server/comms_overview](https://docs.comfy.org/development/comfyui-server/comms_overview).
For interactive token-by-token progress, connect to `ws://localhost:8188/ws?clientId=$CLIENT_ID`
and watch for `executing` / `progress` / `executed` messages.

### 8. From other tools

Any OpenAI-compatible client works — point its base URL at
`http://<spark-tailscale-ip>:<slot-port>/v1` and leave the API key blank
(or set it to a dummy string; the server ignores it). Examples: Continue,
Aider, Hermes, Open WebUI, Cline, LiteLLM as a fan-out gateway.

---

## Slot roster

| Slot | Model | Port | Image | Model alias (for the `model` field) |
|---|---|---|---|---|
| `coder` | Qwen3.6-27B dense (MTP) | 8152 | `spark-llm-stack` | `qwen3.6-27b-coder` |
| `architect` | Qwen3.6-35B-A3B MoE | 8154 | `spark-llm-stack` | `qwen3.6-35b-architect` |
| `vision` | Gemma-4-E4B (multimodal) | 8155 | `spark-llm-stack` | `gemma4-vision` |
| `gemma` | Gemma-4-31B | 8156 | `spark-llm-stack` | `gemma4-31b` |
| `gptoss` | GPT-OSS-20B (built-in) | 8157 | `spark-llm-stack` | `gpt-oss-20b` |
| `imagine` | FLUX.2-klein-4B | 8160 | `spark-llm-imagine` | (use `flux-gen` CLI) |
| `comfyui` | ComfyUI | 8188 | `spark-llm-comfyui` | (graph API, not chat) |

---

## Managing state

```bash
docker-llm-switch status                    # slot table: port, memory bar, color-coded fit
docker-llm-switch memory                    # live memory monitor (Ctrl+C to exit)
docker-llm-switch <slot>                    # switch to <slot> (stops others first)
docker-llm-switch off                       # stop everything
docker-llm-switch panic                     # emergency: stop everything + drop caches

# Auto-start one slot when the Docker daemon starts
docker-llm-switch boot-default architect    # only one slot ever has a restart policy
docker-llm-switch boot-status               # show what starts at daemon boot
docker-llm-switch boot-safe                 # clear all restart policies
```

### Status color coding

`status` shows each slot with a 10-char memory bar and the container port.
When a slot is running, idle slots are colored by whether they'd fit alongside it:

| Color | Meaning |
|-------|---------|
| cyan  | currently running |
| green | fits alongside with ≥8 G headroom |
| yellow | fits raw but cuts into the safety margin |
| red   | too large to run in parallel |

Example with `coder` running (80 G cap): `architect`, `gemma` → red; `vision`, `gptoss`, `imagine`, `comfyui` → green.

### Live memory monitor

`docker-llm-switch memory` opens a live two-section display that refreshes every 2 s:

```
  spark-llm memory  03:45:12  (Ctrl+C to exit)

  LLM CONTAINERS
  ──────────────────────────────────────────────────────────────────────────────
  slot          :port   cap           used / bar                              state
  coder         :8152   80G           52.1GiB / 80GiB   ██████████████░░░░░░  65%  ● running
  architect     :8154   80G                                                         absent
  ...

  HOST PROCESSES  (top 10 by RSS, excl. Docker shims)
  ──────────────────────────────────────────────────────────────────────────────
  PID        %MEM    RSS         COMMAND
  12345      12.3%   15.8G       python3
  ...

  SYSTEM
  ──────────────────────────────────────────────────────────────────────────────
  ram:    67.4G used / 128G total / 60.6G available
```

The container bar tracks fill relative to its cap: green < 60 %, yellow 60–85 %, red > 85 %.
The host processes section shows the top-10 resident-set consumers on the host (Docker shims
are excluded so model memory shows up in the container section, not here).

### Runtime overrides

Persist llama.cpp flags across container restarts without editing the script:

```bash
docker-llm-switch coder config              # list 15 tunable flags + active overrides
docker-llm-switch coder config -c 65536     # halve context window (takes effect on next start)
docker-llm-switch coder config --temp 0.4   # lower temperature
docker-llm-switch coder config --reset      # clear all coder overrides
docker-llm-switch coder config --reset -c   # clear just the -c override
```

Overrides are stored in `~/.config/docker-llm-switch/overrides/<slot>` as `flag=value` lines.
Any flag in the slot's built-in command can be overridden; unknown flags are appended with a warning.

---

## ComfyUI installation (Docker path)

Everything is already wired up. The image builds from `docker/comfyui/Dockerfile`.

**1. Build the image**

```bash
# From repo root
docker compose -f docker/docker-compose.yml build comfyui
```

This takes a while — it compiles SageAttention from source with `sm_121a` SASS.

**2. Put your models in `~/models/`**

ComfyUI expects the standard subdirectory layout inside its `models/` folder.
The container bind-mounts `~/models` → `/opt/ComfyUI/models`:

```
~/models/
  checkpoints/   ← diffusion models (.safetensors)
  vae/
  clip/
  loras/
  ...
```

**3. Start it**

```bash
docker-llm-switch comfyui
# or: ./docker/run.sh comfyui
```

First model load takes 60–90 s — the `wait_ready` loop polls `/system_stats`
and prints dots until ready. Access at `http://localhost:8188`.

**4. Custom nodes persist automatically**

The entrypoint seeds ComfyUI-Manager into `~/comfyui/custom_nodes/` on first
run (using `cp -n` so existing nodes are never clobbered). Three bind-mounts
survive image rebuilds:

```
~/comfyui/custom_nodes/  ↔  /opt/ComfyUI/custom_nodes
~/comfyui/output/        ↔  /opt/ComfyUI/output
~/comfyui/user/          ↔  /opt/ComfyUI/user
```

Install new nodes through the Manager web UI or by `git clone`-ing into
`~/comfyui/custom_nodes/` and restarting the container.

**GB10-specific notes**

- The `model_management.py` patch in the Dockerfile replaces `cudaMemGetInfo()`
  with `psutil.virtual_memory().available`. On GB10's unified memory, CUDA's
  query can report ~6 GB free when 40+ GB are actually available (it sees
  another process's reservation, not the physical pool). Without the patch,
  ComfyUI would partially offload models unnecessarily.
- SageAttention is pinned to v2.2.0 (not v3) — v3 produces mosaic artifacts
  on GB10 (thu-ml/SageAttention#321). FlashAttention 2/3 has no working
  aarch64 wheel for SM 12.1 at all.

**Env overrides**

`COMFY_DIR` defaults to `~/comfyui`, `MODELS_DIR` to `~/models`. Both can be
overridden if your layout differs.

---

## FLUX.2-klein model files

```bash
mkdir -p ~/models/flux2-klein

# Main model (~8 GB, Apache 2.0)
hf download black-forest-labs/FLUX.2-klein-4B \
  flux-2-klein-4b.safetensors --local-dir ~/models/flux2-klein

# VAE (~335 MB) — rename to ae.safetensors (path expected by docker-llm-switch)
hf download Comfy-Org/flux2-dev \
  split_files/vae/flux2-vae.safetensors --local-dir ~/models/flux2-klein && \
  mv ~/models/flux2-klein/split_files/vae/flux2-vae.safetensors ~/models/flux2-klein/ae.safetensors

# Text encoder shards (~8 GB total)
hf download black-forest-labs/FLUX.2-klein-4B \
  text_encoder/ --local-dir ~/models/flux2-klein

# Merge shards into single file (required once; run from ~/models/flux2-klein).
# Set PYTHON to any interpreter with safetensors+torch installed
# (e.g. PYTHON=~/jupyterlab/.venv/bin/python3, or your own venv).
cd ~/models/flux2-klein && "${PYTHON:-python3}" -c "
from safetensors.torch import save_file, load_file
base = 'text_encoder'
s1 = load_file(f'{base}/model-00001-of-00002.safetensors')
s2 = load_file(f'{base}/model-00002-of-00002.safetensors')
save_file({**s1, **s2}, f'{base}/qwen_3_4b.safetensors')
print('Done')
"
```

Notes:
- `hf` replaces the deprecated `huggingface-cli`; both come from `pip install huggingface_hub[cli]` but older installs may still have only the old name.
- `--local-dir-use-symlinks` was removed in newer `huggingface_hub` releases — `--local-dir` now always copies files directly.
- The merge step needs `safetensors` + `torch`. Point `PYTHON` at any interpreter that has them installed, or set up a dedicated venv: `python3 -m venv ~/.venvs/flux && ~/.venvs/flux/bin/pip install safetensors torch && export PYTHON=~/.venvs/flux/bin/python3`.

---

## Smoke tests

See [`SMOKE-TESTS.md`](SMOKE-TESTS.md) for the manual checklist required before
changes under `docker/` are considered shippable (build, mutual exclusion,
Tailscale reachability, hardening parity, end-to-end FLUX gen, custom-node
persistence, daemon-restart survival).

---

## What came from where

`Dockerfile`, `run.sh`, and `docker-llm-switch` were built by synthesising
three sources:

**[eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker)** —
confirmed `nvidia/cuda:13.2.0-devel-ubuntu24.04` as the right base for GB10
aarch64; contributed the multi-stage build pattern and `BUILD_JOBS` parallelism
arg.

**This repo's `.service` files + gremlins/00_POSTMORTEM.md** — every llama.cpp flag, env
var, and memory limit was translated line-for-line from `ExecStart` blocks.
`--host 0.0.0.0` is the only deliberate delta (needed for Tailscale access).

**[AEON-7/comfyui-aeon-spark](https://github.com/AEON-7/comfyui-aeon-spark)**,
**[luix93/DGX-Spark-ComfyUI](https://github.com/luix93/DGX-Spark-ComfyUI)**,
**[mmartial/ComfyUI-Nvidia-Docker](https://github.com/mmartial/ComfyUI-Nvidia-Docker)**
— Blackwell-specific tuning for ComfyUI: `TORCH_CUDA_ARCH_LIST=12.1a`,
SageAttention `compute_121a` flags, `TORCH_COMPILE_DISABLE=1`, unified-memory
env vars, ComfyUI-Manager auto-bootstrap pattern. See the root README for full
provenance detail.
