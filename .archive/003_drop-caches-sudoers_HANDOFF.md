# Handoff: sudoers drop_caches rule (advisory session)

**Generated**: 2026-05-23
**Branch**: dev
**Status**: No code changes — session was purely diagnostic

## Goal

User asked whether a specific sudoers rule for page-cache dropping works as written. No file edits were requested or made.

## Completed

- [x] Diagnosed why the original sudoers line is broken
- [x] Provided the correct pattern using `tee`

## Not Yet Done

- [ ] Apply the corrected sudoers rule to disk (if user wants it)

## Failed Approaches (Don't Repeat These)

None — no implementation attempted.

## The Broken Rule (Do Not Use)

```sudoers
# BROKEN — semicolon is a sudoers command delimiter, not a shell operator
m ALL=(root) NOPASSWD: /bin/sh -c sync; echo 3 > /proc/sys/vm/drop_caches
```

**Why it fails:**
1. Sudoers parses `;` as a separator between `Cmnd_Spec` entries. The `echo 3 > /proc/sys/vm/drop_caches` portion becomes a dangling, malformed entry (parse error or silently ignored).
2. Even if invoked as `sudo /bin/sh -c "sync; echo 3 > ..."`, sudo does exact argv matching — that string doesn't match `/bin/sh -c sync`, so sudo would deny it.

## The Correct Rule

```sudoers
# Add via: sudo visudo -f /etc/sudoers.d/drop-caches
m ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches
```

Call it as:

```bash
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
```

`sync` does not require root on modern Linux; only the write to `/proc/sys/vm/drop_caches` needs elevation. The `tee` pattern keeps the shell redirection on the user side and does the privileged write inside the elevated process — no shell interpretation in sudoers needed.

## Resume Instructions

1. Apply the rule: `sudo visudo -f /etc/sudoers.d/drop-caches`
2. Paste `m ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/vm/drop_caches`, save and quit.
3. Verify: `echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null && echo OK`
   - Expected: prints `3` to stdout then `OK`
   - If denied: run `sudo -l` to confirm the rule loaded

## Warnings

- Do not add the broken rule — the `;` makes the trailing portion a parse error.
- Unrelated but relevant: never add `--no-mmap` or `--mlock` to any llama.cpp service unit on this host (unified memory constraint — see `CLAUDE.md`).

---

## Resolution

Resolved in commit `1188808` on `dev`:

- Added `systemd/install-drop-caches-sudoers.sh` — installer that writes
  `/etc/sudoers.d/drop-caches` with the correct `tee` pattern, validates
  via `visudo -c -f` before landing the file, and offers `--check` for
  a live non-mutating verification.
- Fixed `docker/lib/spark-mem.sh:174` to call
  `echo 3 | sudo -n tee /proc/sys/vm/drop_caches` instead of the
  unauthorisable `sudo -n sh -c 'sync; echo 3 > …'` form.
- Updated `README.md` "Cross-stack memory failsafe" section to point at
  the installer and explain why the old `;`-form rule could never work.
