#!/bin/sh
# Seed default custom nodes (ComfyUI-Manager etc.) into the bind-mounted
# /opt/ComfyUI/custom_nodes/ on first run. `cp -n` is no-clobber so
# anything the user installed via the Manager UI is preserved across
# container restarts and image rebuilds.
set -e

if [ -d /opt/comfy-defaults/custom_nodes ]; then
  cp -rn /opt/comfy-defaults/custom_nodes/. /opt/ComfyUI/custom_nodes/ 2>/dev/null || true
fi

# Seed ComfyUI-Manager security level on first run.
# `middle` is required for "Install Missing Models" to fetch off-registry
# safetensors URLs — the workflow's missing-models panel is otherwise
# blocked because we listen on 0.0.0.0 (Tailscale access) and the default
# `normal` only allows registry-listed URLs. `middle` keeps pickle-format
# (.ckpt/.pt) downloads and arbitrary-git custom nodes restricted. See
# https://github.com/ltdrdata/ComfyUI-Manager#security-policy.
MANAGER_CONFIG=/opt/ComfyUI/user/__manager/config.ini
if [ ! -f "$MANAGER_CONFIG" ]; then
  mkdir -p "$(dirname "$MANAGER_CONFIG")"
  printf '[default]\nsecurity_level = middle\n' > "$MANAGER_CONFIG"
fi

exec python /opt/ComfyUI/main.py "$@"
