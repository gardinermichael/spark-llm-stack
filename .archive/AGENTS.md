# .archive/

Tracked graveyard for things that no longer belong in the live repo but are
worth keeping for history — resolved handoffs, snapshots of generated files,
old plans, etc.

## Recycling a HANDOFF when the work is done

When a `HANDOFF.md` at the repo root has been resolved (fix applied, PR
merged, or work otherwise finished), move it here instead of deleting it.
The reasoning, dead-ends, and "do not do this" gotchas in a handoff are
often more useful than the final fix once you're past the immediate
incident — keep them.

### Where

All archived handoffs live under [`.archive/handoffs/`](./handoffs/) — the
top of `.archive/` is reserved for non-handoff retired material (old plans,
snapshots, deprecated configs). The dedicated subdirectory means
`ls .archive/handoffs/` is a complete chronological index of every handoff
this repo has ever produced.

### Naming

```
.archive/handoffs/NNN_<branch-or-tag>_HANDOFF.md
```

- `NNN` — three-digit zero-padded sequence number, ascending. Look at the
  existing entries and use `next number + 1`. Never reuse a number.
- `<branch-or-tag>` — the branch the handoff was originally for (e.g.
  `nvidia-drivers`, `pr3`). Short and lowercase. If there was no branch,
  use a short tag describing the topic.
- Keep the `_HANDOFF.md` suffix — makes them grep-friendly.

### Steps

```bash
# 1. Pick the next number
ls .archive/handoffs/

# 2. Move + rename in one git step (preserves history)
git mv HANDOFF.md .archive/handoffs/NNN_<branch>_HANDOFF.md

# 3. If the handoff referenced future work that's now done, link the
#    follow-up artifact at the bottom of the archived file -- e.g. the
#    gremlins/ incident report, the merged PR URL, or the commit that
#    resolved it. Future readers should be able to land on the archived
#    handoff and immediately see how the story ended.

# 4. Commit
git commit -m "chore(archive): retire <branch> handoff (resolved by <thing>)"
```

### When NOT to archive

- The handoff is still in progress (don't pre-emptively archive working
  state — leave it at the repo root).
- The handoff is duplicated by a `gremlins/` incident report that already
  contains everything useful. In that case delete it instead — the gremlin
  is the durable record.

## Other archived material

Anything else that's retired but worth keeping (old plan docs, snapshots of
generated files, deprecated configs) can live here without the `_HANDOFF`
suffix. Use a descriptive directory or filename — no number prefix needed
unless ordering matters.
