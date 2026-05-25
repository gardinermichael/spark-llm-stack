// spark-downloader frontend hook.
//
// ComfyUI core's Missing Models panel doesn't render anchors into the
// document tree — it creates a transient <a> in a local variable, sets
// href/download/target, calls .click() synchronously, then drops the
// reference (see missingModelDownload-*.js -> downloadModel). The
// browser handles the download via that synchronous click; the anchor
// is never inserted, so a MutationObserver on document.body never sees
// it.
//
// To intercept this we patch HTMLAnchorElement.prototype.click() once
// at load time. The patch checks for an anchor with `download` set and
// a model file extension on its href; if both match, it suppresses the
// real click and POSTs to /spark/download_url instead. All other
// clicks pass through untouched.
//
// A small bottom-right toast surfaces progress because the React
// button has no awareness that we hijacked it — its own state won't
// reflect what happened.

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
    return decodeURIComponent(new URL(url).pathname.split("/").pop() || "");
  } catch {
    return "";
  }
}

// ── toast container ─────────────────────────────────────────────────
let toastBox = null;
function ensureToastBox() {
  if (toastBox && toastBox.isConnected) return toastBox;
  toastBox = document.createElement("div");
  toastBox.id = "spark-downloader-toasts";
  Object.assign(toastBox.style, {
    position: "fixed",
    bottom: "16px",
    right: "16px",
    display: "flex",
    flexDirection: "column",
    gap: "8px",
    zIndex: "999999",
    pointerEvents: "none",
    fontFamily: "system-ui, sans-serif",
    fontSize: "13px",
  });
  document.body.appendChild(toastBox);
  return toastBox;
}

function makeToast(text) {
  const t = document.createElement("div");
  Object.assign(t.style, {
    background: "#1f2937",
    color: "#e5e7eb",
    padding: "10px 14px",
    borderRadius: "8px",
    boxShadow: "0 6px 20px rgba(0,0,0,0.4)",
    maxWidth: "440px",
    wordBreak: "break-all",
    pointerEvents: "auto",
    borderLeft: "3px solid #6b7280",
  });
  t.textContent = text;
  ensureToastBox().appendChild(t);
  return {
    update(newText, color = null, border = null) {
      t.textContent = newText;
      if (color) t.style.color = color;
      if (border) t.style.borderLeft = `3px solid ${border}`;
    },
    dismiss(after = 4000) {
      setTimeout(() => t.remove(), after);
    },
  };
}

// ── installer ───────────────────────────────────────────────────────
async function installServerSide(url, filename) {
  const subdir = guessSubdir(filename);
  const toast = makeToast(`Installing → ${subdir}/${filename} …`);
  try {
    const r = await fetch("/spark/download_url", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, filename, subdir }),
    });
    const j = await r.json().catch(() => ({}));
    if (r.ok) {
      // The server may have reclassified the file by sniffing the
      // safetensors header — surface the *final* subdir and note when
      // it differed from the initial guess so the user sees the
      // correction.
      const finalSubdir = j.subdir || subdir;
      let done;
      if (j.status === "already-present") {
        done = `Already in ${finalSubdir}/${filename}`;
      } else if (j.reclassified) {
        done = `Installed → ${finalSubdir}/${filename} (was guessed ${subdir})`;
      } else {
        done = `Installed → ${finalSubdir}/${filename}`;
      }
      toast.update(done, "#bbf7d0", "#22c55e");
      toast.dismiss(5000);
    } else {
      toast.update(`Failed: ${j.error || r.status} — ${filename}`, "#fecaca", "#ef4444");
      toast.dismiss(8000);
    }
  } catch (err) {
    toast.update(`Failed: ${err.message} — ${filename}`, "#fecaca", "#ef4444");
    toast.dismiss(8000);
  }
}

// ── click hook on HTMLAnchorElement ─────────────────────────────────
const origClick = HTMLAnchorElement.prototype.click;
HTMLAnchorElement.prototype.click = function patchedClick(...args) {
  try {
    const href = this.href || "";
    const download = this.getAttribute("download") || this.download || "";
    if (download && MODEL_EXT_RE.test(href)) {
      const filename = download || basenameFromUrl(href);
      installServerSide(href, filename);
      return; // suppress the real navigation/download
    }
  } catch (e) {
    // If anything goes wrong in the hook, fall through to native behavior
    // rather than swallowing the user's click.
    // eslint-disable-next-line no-console
    console.warn("[spark-downloader] hook error, falling through", e);
  }
  return origClick.apply(this, args);
};

app.registerExtension({
  name: "spark.downloader",
  async setup() {
    // eslint-disable-next-line no-console
    console.log(
      "[spark-downloader] active — anchor.click() patched; Missing Models downloads go server-side",
    );
  },
});
