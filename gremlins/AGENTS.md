# Gremlins — Incident Reports

This folder collects post-mortems and incident reports for production-affecting
problems on the DGX Spark LLM Stack. Each entry exists so the next person (or
the next agent) hitting the same symptom finds the diagnosis, the fix, and the
upstream sources without having to redo the investigation.

## File naming

```
NN_SHORT-KEBAB-TITLE.md
```

- `NN` — two-digit ordinal, monotonically increasing (`00`, `01`, `02`, …).
  Pick the next unused number; do not reuse.
- `SHORT-KEBAB-TITLE` — uppercase kebab-case summary of the issue (≤ 6 words).
  Examples: `OOM-BRICK-LOOP`, `NVIDIA-DRIVER-ABI-MISMATCH`,
  `QWEN36-27B-MTP-CUDA-CRASH`.
- Extension is always `.md`.

## Required structure

Every report must contain — at minimum — these three things:

1. **The issue** — what broke, on what hardware, with what symptom. Include
   exact error messages and exit codes verbatim. Future-you searches by
   error string.
2. **The fix** — concrete, copy-pasteable steps or config changes. If there is
   no permanent fix, document every known workaround in rank order with
   trade-offs.
3. **Sources** — links to upstream issues, PRs, commits, vendor docs, or
   community threads where the diagnosis came from. Cite by URL so the reader
   can verify and check for newer information.

Use this skeleton (extend as needed; omit sections that don't apply):

```markdown
# DGX Spark LLM Stack — Incident Report

**Incident:** <one-line title>
**Hardware:** <relevant hw/sw versions>
**Severity:** <Low | Medium | High>  — <one-line user-visible impact>
**Status:** <Open | Mitigated | Resolved, hardened>

---

## Summary

<2–4 paragraphs: what happened, why it matters, current state.>

---

## Root cause

<Mechanism. If multi-factor, use the factor table below.>

```
factor                                category         severity
────────────────────────────────────  ───────────────  ────────
1. …                                  …                …
```

---

## How the failure looked

```
<verbatim error output, journalctl lines, exit codes>
```

---

## Remediations / Workarounds

<Rank-ordered. For each: what to change, expected effect, trade-off.>

---

## Lessons learned

<Optional. Generalizable rules — e.g. "Runtime exclusion ≠ boot-time exclusion".>

---

## Useful diagnostic commands

```bash
<commands that confirm the diagnosis or verify the fix>
```

---

## Sources

- [Title of upstream issue](https://…)
- [Vendor doc / commit / thread](https://…)
```

## Document the troubleshooting journey

Reports should record **what was tried, in what order, and why each step was
abandoned or kept** — not just the final fix. Future readers (human or agent)
hitting the same gremlin need to know which dead ends to skip and which
mitigations were already proven insufficient on this hardware.

Add a `## Troubleshooting log` section (or extend `## Remediations`) with a
chronological walk-through:

```markdown
## Troubleshooting log

1. **First hypothesis: OOM.** Checked `journalctl -k` and `earlyoom` —
   96 GiB free at crash. Ruled out.
2. **Second hypothesis: stale llama.cpp build.** Rebuilt from mainline-master
   (post the 2026-05-21 VRAM-leak fix). Crashed identically. Ruled out.
3. **Tried: lowering `--ctx-checkpoints` to 8.** Crash still occurred at the
   same ~30k boundary. Insufficient on its own.
4. **Applied: FP16 KV + `--spec-draft-n-max 2`** (2026-05-25). Stable through
   a 45k-context session. Current mitigation.
5. **Next if this fails:** drop `--cache-reuse` and `--kv-unified`.
```

Include both the things that **didn't work** (with the evidence that ruled
them out) and the things that **did**. A workaround that helped on a sibling
report but didn't help here is still valuable to record — it tells the next
reader the bug surface is different from the sibling's.

## Style rules

- **Verbatim error messages.** Don't paraphrase. The error string is the
  search key.
- **Cite everything.** If a claim came from a GitHub issue, link it. If from a
  community report, link it. No uncited fixes.
- **Date upstream state.** Upstream bugs move — note the date you last checked
  ("vLLM #40756 open as of 2026-05-25") so a future reader knows when to
  recheck.
- **Rank workarounds.** If there are multiple, order them by `(safety,
  effectiveness, simplicity)` and note the trade-off of each.
- **Update in place when status changes.** When an upstream fix lands, edit
  the report — add a "Resolution" section and flip `Status:` to
  `Resolved, hardened`. Do not delete the workaround history; future readers
  on older versions still need it.
- **Cross-reference.** If a new gremlin interacts with an existing one
  (e.g. memory caps from `00_POSTMORTEM.md` shaped the workaround), link it.

## When to add a report

Add one when:

- An incident caused (or nearly caused) data loss, host instability, or a
  service outage.
- A bug has no upstream fix and the workaround is non-obvious.
- A diagnosis took more than ~30 minutes and is likely to recur.

Don't add one for transient/single-shot issues with obvious fixes already
documented in the main `README.md` or `CLAUDE.md`.
