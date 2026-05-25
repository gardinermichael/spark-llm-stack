#!/usr/bin/env bash
# setup-imagine.sh — one-shot installer for the FLUX.2-klein "imagine" slot.
#
# Downloads the diffusion model, VAE, and text-encoder shards into
# $MODELS_DIR/flux2-klein/ using exactly the paths docker-llm-switch
# expects, merges the text-encoder shards into a single safetensors
# file, and removes the now-redundant shard files + the stray
# split_files/ directory the `hf download` step leaves behind.
#
# Idempotent: re-running skips any step whose output already exists.
#
# Requirements:
#   - uv      (https://docs.astral.sh/uv/) — bootstraps everything else.
#   - ~17 GB free in $MODELS_DIR (8 GB diffusion + 8 GB encoder shards + 335 MB VAE).
#
# Usage:
#   tools/setup-imagine.sh                  # FLUX files only
#   tools/setup-imagine.sh --with-comfyui   # also seed ComfyUI subdir layout
#                                             # and symlink FLUX into it
#   MODELS_DIR=/data/models tools/setup-imagine.sh
#
# After completion:
#   docker-llm-switch imagine    # FLUX async API on :8160
#   docker-llm-switch comfyui    # ComfyUI on :8188 (if --with-comfyui used)

set -euo pipefail

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
FLUX_DIR="$MODELS_DIR/flux2-klein"
TE_DIR="$FLUX_DIR/text_encoder"
WITH_COMFYUI=0

for arg in "$@"; do
  case "$arg" in
    --with-comfyui) WITH_COMFYUI=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v uv >/dev/null 2>&1 || die "'uv' not installed — see https://docs.astral.sh/uv/getting-started/installation/"

# hf CLI: use system binary if present, otherwise run via uv tool (cached).
hf_run() {
  if command -v hf >/dev/null 2>&1; then
    hf "$@"
  else
    uv tool run --quiet --from "huggingface_hub[cli]" hf "$@"
  fi
}

# Find a Python with safetensors+torch already importable. Empty string
# means none found — caller should fall back to `uv run --with`.
find_merge_python() {
  local candidates=(
    "${PYTHON:-}"
    "$HOME/jupyterlab/.venv/bin/python3"
    "python3"
  )
  for py in "${candidates[@]}"; do
    [[ -z "$py" ]] && continue
    command -v "$py" >/dev/null 2>&1 || continue
    if "$py" -c 'import safetensors.torch, torch' 2>/dev/null; then
      echo "$py"
      return
    fi
  done
}

mkdir -p "$FLUX_DIR"

# ── 1. diffusion model ────────────────────────────────────────────────────────
if [[ -s "$FLUX_DIR/flux-2-klein-4b.safetensors" ]]; then
  ok "diffusion model already present"
else
  log "downloading flux-2-klein-4b.safetensors (~8 GB, Apache 2.0)"
  hf_run download black-forest-labs/FLUX.2-klein-4B \
    flux-2-klein-4b.safetensors --local-dir "$FLUX_DIR"
fi

# ── 2. VAE ────────────────────────────────────────────────────────────────────
if [[ -s "$FLUX_DIR/ae.safetensors" ]]; then
  ok "VAE already present"
else
  log "downloading VAE (~335 MB)"
  hf_run download Comfy-Org/flux2-dev \
    split_files/vae/flux2-vae.safetensors --local-dir "$FLUX_DIR"
  mv "$FLUX_DIR/split_files/vae/flux2-vae.safetensors" "$FLUX_DIR/ae.safetensors"
  rm -rf "$FLUX_DIR/split_files"
  ok "VAE installed as ae.safetensors (split_files/ removed)"
fi

# ── 3. text encoder: download shards + merge + cleanup ───────────────────────
if [[ -s "$TE_DIR/qwen_3_4b.safetensors" ]]; then
  ok "text encoder already merged"
else
  shard1="$TE_DIR/model-00001-of-00002.safetensors"
  shard2="$TE_DIR/model-00002-of-00002.safetensors"
  if [[ ! -s "$shard1" || ! -s "$shard2" ]]; then
    log "downloading text encoder shards (~8 GB)"
    hf_run download black-forest-labs/FLUX.2-klein-4B \
      "text_encoder/*" --local-dir "$FLUX_DIR"
  fi

  merge_script="$(mktemp --tmpdir flux-merge-XXXX.py)"
  trap 'rm -f "$merge_script"' EXIT
  cat >"$merge_script" <<'PY'
import os, sys
from safetensors.torch import load_file, save_file
te_dir = os.environ["TE_DIR"]
out = os.path.join(te_dir, "qwen_3_4b.safetensors")
shards = [
    os.path.join(te_dir, "model-00001-of-00002.safetensors"),
    os.path.join(te_dir, "model-00002-of-00002.safetensors"),
]
merged = {}
for s in shards:
    merged.update(load_file(s))
save_file(merged, out)
print(f"merged {len(merged)} tensors -> {out}", file=sys.stderr)
PY

  py="$(find_merge_python)"
  export TE_DIR
  if [[ -n "$py" ]]; then
    log "merging shards using $py (safetensors+torch already installed)"
    "$py" "$merge_script"
  else
    log "merging shards via uv ephemeral env (safetensors+torch, cached after first run)"
    uv run --quiet --with safetensors --with torch -- python "$merge_script"
  fi

  log "removing redundant shard files"
  rm -f "$shard1" "$shard2" \
        "$TE_DIR/model.safetensors.index.json"
  ok "text encoder ready as qwen_3_4b.safetensors"
fi

# ── 4. optional ComfyUI layout + symlinks ─────────────────────────────────────
if [[ "$WITH_COMFYUI" == "1" ]]; then
  log "seeding ComfyUI subdirectory layout under $MODELS_DIR/"
  for sub in checkpoints diffusion_models vae text_encoders clip loras \
             controlnet upscale_models embeddings; do
    mkdir -p "$MODELS_DIR/$sub"
  done

  # Symlink FLUX into the ComfyUI-standard locations so a single set of
  # weights serves both the imagine slot (sd-server) and the comfyui
  # slot. ln -sfn = atomic replace, no error if it already points there.
  ln -sfn "$FLUX_DIR/flux-2-klein-4b.safetensors" \
          "$MODELS_DIR/diffusion_models/flux-2-klein-4b.safetensors"
  ln -sfn "$FLUX_DIR/ae.safetensors" \
          "$MODELS_DIR/vae/flux2-ae.safetensors"
  ln -sfn "$TE_DIR/qwen_3_4b.safetensors" \
          "$MODELS_DIR/text_encoders/qwen_3_4b.safetensors"
  ok "ComfyUI layout ready; FLUX symlinked into diffusion_models/, vae/, text_encoders/"
fi

echo
ok "FLUX.2-klein installed in $FLUX_DIR"
echo "    start FLUX API:  docker-llm-switch imagine    # :8160, use with flux-gen"
[[ "$WITH_COMFYUI" == "1" ]] && \
  echo "    start ComfyUI:   docker-llm-switch comfyui    # :8188"
