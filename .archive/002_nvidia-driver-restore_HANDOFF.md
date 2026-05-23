# Handoff: docker-llm-switch UX Enhancements

**Generated**: 2026-05-23  
**Branch**: dev  
**Status**: Complete — all committed and pushed

## Goal

Enhance `docker/docker-llm-switch` with color-coded memory status, per-slot runtime config overrides, a live memory monitor, an OOM health check subcommand, and update `docker/README.md` to match.

## Completed

- [x] `status` — color-coded slot rows with memory bars (cyan=running, green/yellow/red based on remaining headroom); `:port` column restored; compact one-line health summary appended
- [x] `<slot> config` — show/set/reset per-slot runtime flag overrides; 15 tunable flags with ranges and KV-cache footprint warning at bottom
- [x] `memory` — live monitor loop: docker stats for spark containers (top), ps for host processes (bottom), free -h for system totals; cursor hidden during loop
- [x] `check` / `doctor` — two-section diagnostic: OOM failsafe components (earlyoom, spark-panic, spark-mem.sh, drop-caches sudoers) and CLI tools (docker-llm-switch, llm-switch, flux-gen)
- [x] README §5 "Start a slot" — `docker-llm-switch` commands on the left, `./docker/run.sh` noted as alias on the right
- [x] README "Managing state" section — full reference: status color coding table, memory monitor output example, runtime overrides usage
- [x] `~/.claude/hooks/suggest-compact.js` — copied from plugin cache
- [x] `~/.claude/settings.json` — PreToolUse hook on `Edit|Write` added, running `node ~/.claude/hooks/suggest-compact.js`

## Not Yet Done

- [ ] None — session goals fully delivered

## Failed Approaches (Don't Repeat These)

**Worktree cherry-pick conflicts**: Every worktree in this session branched from `origin/main` (not `dev`, per `baseRef: fresh` in settings). Cherry-picking back to dev always conflicted on README sections added by earlier doc commits. Resolved with `sed -i '/^<<<<<<< HEAD$/,/^=======$/d; /^>>>>>>> .*/d'` to strip conflict markers. This is expected and the established workflow.

**ANSI color codes inside `printf %-*s` width fields**: Mixing color escape sequences inside format-width fields breaks column alignment because `printf` counts escape chars as visible characters. Fix: build plain-text column strings first (`col_x=$(printf "%-Ns" "$val")`), then wrap the already-padded string with color codes outside the printf call.

**`declare -A` reset inside loop**: `arr=()` does NOT reset an associative array — it silently does nothing on a re-used name. Must `unset arr; declare -A arr=()` on each iteration of the memory watch loop.

**Python regex ate README sections**: In commit `118c9cb`, a `python3 -c` inline replacement used a regex that consumed from `### 2. Install CLI tools` through `### 5. Start a slot`, deleting §4 "Verify model files". Manually restored in the same commit. Avoid broad multi-line regex replacements in README — use precise anchor strings.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| `-c 131072` (128K) default for all llama slots | Halves KV-cache vs 256K; `-c 262144 + --parallel 2` would consume ~96G KV alone, busting the 80G MemoryMax cap |
| Config overrides stored in `~/.config/docker-llm-switch/overrides/<slot>` | XDG-compliant, one `flag=value` line per override, easy to hand-edit |
| `TUNABLE_RANGE` assoc array for config display | Shows upper/lower bounds in `<slot> config` without hard-coding them in display logic |
| Memory bar uses `safe_remaining = total_gb - running_gb` | Colors idle slots relative to actual headroom, not an arbitrary threshold |

## Current State

**Working**: All subcommands functional. Branch `dev` is clean and pushed to `gardinermichael/spark-llm-stack`.

**Broken**: Nothing known.

**Uncommitted Changes**: None.

## Files to Know

| File | Why It Matters |
|------|----------------|
| `docker/docker-llm-switch` | Main script — all new features live here |
| `docker/README.md` | Documentation — "Managing state" section covers all new features |
| `~/.claude/settings.json` | Has the strategic-compact PreToolUse hook for Edit\|Write |
| `~/.claude/hooks/suggest-compact.js` | Hook script that fires on Edit\|Write |

## Code Context

**Slot definition pattern** — four parallel places that must stay in sync when adding or changing a slot:

```
systemd/units/*.service          → ExecStart (authoritative args)
systemd/llm-switch               → SVCS[], PORTS[], ROLES[]
docker/docker-llm-switch         → CMD_<slot>[] array, IMAGE[<slot>]
systemd/harden-llm-stack.sh      → SERVICES=() with MemoryHigh/Max
```

**Config override CRUD in docker-llm-switch**:
```bash
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/docker-llm-switch"
_override_file()   # returns path ~/.config/docker-llm-switch/overrides/<slot>
_load_overrides()  # reads file into assoc array
_save_overrides()  # writes assoc array back to file
_apply_overrides() # patches CMD_ array before docker run
```

**Tunable flags** (15 total, defined in `TUNABLE_KEYS` / `TUNABLE_DESC` / `TUNABLE_RANGE`):
`-c`, `--parallel`, `--threads`, `--threads-batch`, `--batch-size`, `--ubatch-size`, `--mla-attn`, `--flash-attn`, `--temp`, `--top-k`, `--top-p`, `--repeat-penalty`, `--min-p`, `--n-predict`, `--slots`

**KV-cache warning** in `show_slot_config()`:
```bash
[[ "$flag" == "-c" || "$flag" == "--parallel" ]] && warn=1
# shown if either is overridden; approx: kv_gb ≈ (c × parallel × 2 × num_layers × head_dim) / 1e9
```

## Resume Instructions

If picking up new feature work:

1. Check `free -h` before starting any model service (128 GB unified pool)
2. When adding a new slot, update all four parallel locations (see "Slot definition pattern" above)
3. Run `docker-llm-switch check` to verify OOM failsafe health before testing
4. Test the memory monitor with `docker-llm-switch memory` while a container is running

If fixing a README issue:
- Use narrow, exact anchor strings in any programmatic edit — the §4 deletion incident was caused by a too-broad regex

## Warnings

- `baseRef: fresh` in `~/.claude/settings.json` means worktrees always branch from `origin/main`. Cherry-pick conflicts with `dev` are expected — strip markers with sed.
- Never add `--no-mmap` or `--mlock` to any service or CMD_ array — destroys evictability on unified memory.
- Always use `--repo gardinermichael/spark-llm-stack` with `gh pr create`.
- The `imagine` and `comfyui` slots use their own images (`spark-llm-imagine`, `spark-llm-comfyui`); all llama slots share `spark-llm-stack`. Set in `IMAGE[]` in `docker-llm-switch`.
