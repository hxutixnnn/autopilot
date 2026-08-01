---
name: updateautopilot
description: Self-update a running Autopilot and its copilots from the canonical hxutixnnn/autopilot repository. Use when the pilot invokes /updateautopilot (e.g. "/updateautopilot", "update autopilot", "pull the latest autopilot"). Fast-forwards this Autopilot repo's default branch and every copilot home from the validated canonical origin (fast-forward only, never forced, never disruptive), then re-reads AGENTS.md and nudges each updated copilot to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updateautopilot

Self-update autopilot in place.
Autopilot is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running autopilot pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running autopilot instruction surface; public `skills/` is installer-facing and is not loaded by autopilot.
This skill performs that pull for the running main autopilot and every copilot, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync autopilot already runs.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a copilot's in-flight work is never disrupted.
This touches only the autopilot repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/ap-update.sh
   ```
   It validates each target's actual origin as `hxutixnnn/autopilot` before fetching, never falls back to another remote, then fast-forwards this Autopilot repo and every registered copilot home to the canonical default branch.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-autopilot: yes|no`
   - `nudge-copilots: ap-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-autopilot: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-autopilot: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live copilot.**
   For every target listed on the `nudge-copilots:` line (do nothing when it says `none`), send a one-line re-read nudge so that copilot picks up its new instructions too:
   ```sh
   AP_HOME=<this-autopilot-home> bin/ap-send.sh <id> 'autopilot was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `AP_HOME=<this-autopilot-home>` unless `AP_HOME` is already set to the active autopilot home.
   This is a gentle steer, not an interruption: the copilot already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A copilot that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the pilot in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without autopilot's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Pilot, autopilot and both copilots are now on the latest."
   Surface any skipped target whose reason needs the pilot's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the autopilot repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Copilots are never disrupted.**
  A copilot gets a tracked-files fast-forward (safe while it is mid-task, since its work lives in gitignored operational dirs and separate project worktrees) plus a gentle re-read nudge.
  It is never torn down, interrupted, or forced.
