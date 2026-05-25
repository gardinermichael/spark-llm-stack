// spark-downloader frontend hook.
//
// ComfyUI core's Missing Models panel emits plain <a download href="...">
// anchors with model URLs. With a remote browser those land in the
// operator's local Downloads folder rather than ComfyUI's models/ tree.
//
// This script attaches a click handler to those anchors that POSTs to
// our /spark/download_url backend instead, dropping the file directly
// into models/<subdir>/. Subdir is inferred from filename tokens; the
// backend re-validates the inference.
//
// We use a MutationObserver because the Missing Models panel is a React
// component re-rendered on workflow load, and there's no public hook for
// "before the panel renders". The observer is scoped to anchors with a
// download attribute pointing at a model file extension, so the cost
// across the rest of the UI is essentially nil.

import { app } from "../../scripts/app.js";

const MODEL_EXT_RE = /\.(safetensors|ckpt|pth|pt|bin|gguf)(\?|$)/i;

const SUBDIR_HINTS = [
  ["lora", "loras"],
  ["controlnet", "controlnet"],
  ["upscale", "upscale_models"],
  ["esrgan", "upscale_models"],
  ["vae", "vae"],
  ["clip_vision", "clip_vision"],
  ["text_encoder", "text_encoders"],
  ["clip", "clip"],
  ["embed", "embeddings"],
];

function guessSubdir(filename) {
  const f = (filename || "").toLowerCase();
  for (const [token, sub] of SUBDIR_HINTS) if (f.includes(token)) return sub;
  return "checkpoints";
}

function basenameFromUrl(url) {
  try {
    const u = new URL(url);
    return decodeURIComponent(u.pathname.split("/").pop() || "");
  } catch {
    return "";
  }
}

async function installServerSide(anchor) {
  const url = anchor.href;
  const filename = anchor.getAttribute("download") || basenameFromUrl(url);
  const subdir = guessSubdir(filename);
  const original = anchor.textContent;
  anchor.dataset.sparkBusy = "1";
  anchor.style.pointerEvents = "none";
  anchor.textContent = `Installing -> ${subdir}/${filename} ...`;
  try {
    const r = await fetch("/spark/download_url", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, filename, subdir }),
    });
    const j = await r.json().catch(() => ({}));
    if (r.ok) {
      anchor.textContent =
        j.status === "already-present"
          ? `Already in ${subdir}/${filename}`
          : `Installed -> ${subdir}/${filename}`;
      anchor.style.color = "#7c7";
    } else {
      anchor.textContent = `Failed: ${j.error || r.status} (click to retry)`;
      anchor.style.color = "#e88";
      anchor.style.pointerEvents = "";
      delete anchor.dataset.sparkBusy;
    }
  } catch (err) {
    anchor.textContent = `Failed: ${err.message} (click to retry)`;
    anchor.style.color = "#e88";
    anchor.style.pointerEvents = "";
    delete anchor.dataset.sparkBusy;
  }
}

function hook(root) {
  if (!root || !root.querySelectorAll) return;
  const sel = "a[download][href]:not([data-spark-hooked])";
  root.querySelectorAll(sel).forEach((a) => {
    if (!MODEL_EXT_RE.test(a.href || "")) return;
    a.dataset.sparkHooked = "1";
    a.addEventListener(
      "click",
      async (e) => {
        if (a.dataset.sparkBusy) return;
        e.preventDefault();
        e.stopPropagation();
        await installServerSide(a);
      },
      true,
    );
  });
}

app.registerExtension({
  name: "spark.downloader",
  async setup() {
    hook(document.body);
    const observer = new MutationObserver((muts) => {
      for (const m of muts) {
        for (const n of m.addedNodes) {
          if (n.nodeType === 1) hook(n);
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
    // eslint-disable-next-line no-console
    console.log("[spark-downloader] active — Missing Models anchors will install server-side");
  },
});
