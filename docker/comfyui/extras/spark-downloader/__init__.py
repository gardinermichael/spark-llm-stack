"""
spark-downloader — server-side model installs for the workflow Missing Models panel.

ComfyUI core's Missing Models panel renders a plain browser-download link
for each missing file. With remote browser access (Tailscale, LAN), that
file lands in the operator's local Downloads folder instead of the
server's models/ tree, which is rarely what anyone wants.

This extension adds:

  POST /spark/download_url   stream {url, filename, subdir} into
                             ComfyUI's models/<subdir>/<filename>.

A small frontend hook (see js/spark-downloader.js) attaches a click
handler to those Missing-Models anchors that POSTs here instead of
letting the browser handle the navigation. Subdir is inferred from
filename tokens (lora -> loras, vae -> vae, ...); unrecognized files
fall through to checkpoints/.

HuggingFace `resolve/main/<file>` URLs are routed through
huggingface_hub.hf_hub_download when available — that gives parallel
chunk downloads, which on a fast link is roughly 2x the throughput of
vanilla aiohttp on multi-GB safetensors files.

This is a custom node only in the ComfyUI registration sense (so
ComfyUI loads __init__.py and the WEB_DIRECTORY). It exposes no actual
graph nodes.
"""

from __future__ import annotations

import asyncio
import logging
import re
from pathlib import Path

import aiohttp
from aiohttp import web

import folder_paths
from server import PromptServer

logger = logging.getLogger("spark-downloader")

# Subdir guesses by filename token, first match wins. The order here is
# intentional: more specific tokens (clip_vision, text_encoder) come
# before their substrings (clip).
SUBDIR_HINTS = [
    ("lora", "loras"),
    ("controlnet", "controlnet"),
    ("upscale", "upscale_models"),
    ("esrgan", "upscale_models"),
    ("vae", "vae"),
    ("clip_vision", "clip_vision"),
    ("text_encoder", "text_encoders"),
    ("clip", "clip"),
    ("embed", "embeddings"),
]

# Match https://huggingface.co/<owner>/<repo>/resolve/<rev>/<path>
HF_URL_RE = re.compile(
    r"^https?://huggingface\.co/(?P<repo>[^/]+/[^/]+)/resolve/(?P<rev>[^/]+)/(?P<path>.+?)(?:\?.*)?$"
)


def _guess_subdir(filename: str) -> str:
    fn = filename.lower()
    for token, sub in SUBDIR_HINTS:
        if token in fn:
            return sub
    return "checkpoints"


def _resolve_dest(subdir: str, filename: str) -> Path:
    # Strip any path components from the caller-supplied filename to keep
    # everything anchored inside models/<subdir>/.
    safe_name = Path(filename).name
    paths = folder_paths.folder_names_and_paths.get(subdir)
    if paths and paths[0]:
        base = Path(paths[0][0])
    else:
        base = Path(folder_paths.models_dir) / subdir
    base.mkdir(parents=True, exist_ok=True)
    return base / safe_name


async def _download_huggingface(url: str, dest: Path) -> int:
    """Use huggingface_hub for HF resolve URLs (parallel chunks)."""
    m = HF_URL_RE.match(url)
    if not m:
        raise ValueError("not a huggingface resolve URL")
    repo, rev, path = m["repo"], m["rev"], m["path"]

    from huggingface_hub import hf_hub_download  # bundled with Manager deps

    def _sync():
        # local_dir places the file at <local_dir>/<path>; we want it at
        # dest.parent/dest.name. Easiest is to download into a scratch
        # dir, then move into place.
        scratch = dest.parent / ".spark-hf-cache"
        scratch.mkdir(exist_ok=True)
        local = hf_hub_download(
            repo_id=repo,
            filename=path,
            revision=rev,
            local_dir=str(scratch),
        )
        return Path(local)

    local = await asyncio.to_thread(_sync)
    # Move the resolved file to its final name, then clean up the scratch.
    local.rename(dest)
    return dest.stat().st_size


async def _download_streaming(url: str, dest: Path) -> int:
    tmp = dest.with_name(dest.name + ".partial")
    timeout = aiohttp.ClientTimeout(total=None, sock_read=300)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.get(url, allow_redirects=True) as resp:
            if resp.status != 200:
                raise RuntimeError(f"upstream HTTP {resp.status}")
            with open(tmp, "wb") as f:
                async for chunk in resp.content.iter_chunked(1 << 20):
                    f.write(chunk)
    tmp.rename(dest)
    return dest.stat().st_size


@PromptServer.instance.routes.post("/spark/download_url")
async def download_url(request):
    try:
        data = await request.json()
    except Exception:
        return web.json_response({"error": "invalid json"}, status=400)

    url = (data.get("url") or "").strip()
    filename = (data.get("filename") or "").strip()
    subdir = (data.get("subdir") or "").strip() or _guess_subdir(filename)

    if not url or not filename:
        return web.json_response({"error": "url and filename required"}, status=400)
    if not url.startswith(("http://", "https://")):
        return web.json_response({"error": "only http(s) URLs supported"}, status=400)

    dest = _resolve_dest(subdir, filename)
    if dest.exists() and dest.stat().st_size > 0:
        return web.json_response(
            {"status": "already-present", "path": str(dest), "subdir": subdir}
        )

    logger.info(f"spark-downloader: fetching {url} -> {dest}")

    is_hf = bool(HF_URL_RE.match(url))
    try:
        if is_hf:
            size = await _download_huggingface(url, dest)
        else:
            size = await _download_streaming(url, dest)
        logger.info(f"spark-downloader: ok ({size} bytes) -> {dest}")
        return web.json_response(
            {"status": "ok", "path": str(dest), "subdir": subdir, "bytes": size, "via": "hf" if is_hf else "stream"}
        )
    except Exception as e:
        # Clean up partial / scratch artifacts so a retry starts clean.
        for p in (dest.with_name(dest.name + ".partial"), dest.parent / ".spark-hf-cache"):
            try:
                if p.is_dir():
                    import shutil
                    shutil.rmtree(p, ignore_errors=True)
                elif p.exists():
                    p.unlink()
            except Exception:
                pass
        logger.exception("spark-downloader failed")
        return web.json_response({"error": str(e)}, status=500)


# ComfyUI looks for these at module-load time. No graph nodes — this
# extension is purely a backend route + frontend hook.
WEB_DIRECTORY = "./js"
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
