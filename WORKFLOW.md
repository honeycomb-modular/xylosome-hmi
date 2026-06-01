# WORKFLOW — how Hoyte works across machines (read this first)

This file exists because the same mistake keeps happening: one machine/session does
work, assumes it reached the other machine, and it hadn't. Read this before doing
anything that moves code or files between machines or onto a Pi.

---

## The setup

Hoyte works on this project from **two computers**, moving between them:

| Machine | Role | Project folder |
|---|---|---|
| **Portable Mac** | mobile / couch / away-from-bench dev (used to develop the UI on the Pi 4 remotely) | `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/projects/xylosome_pi/` |
| **Windows PC** ("garage / bench PC") | at the bench, near the hardware (Pi 5, display, soldering) | `C:\Users\Hoyte\iCloudDrive\Documents\projects\xylosome_pi\` |

Both point at the **same iCloud Drive folder**. The two Raspberry Pis are separate
again (Pi 4 dev @ 192.168.10.2, Pi 5 final @ 192.168.2.2) — see `SESSION_NOTES.md`.

## The core problem to never repeat

1. **Every AI session is blind to every other session.** The me on the Mac and the
   me on the PC share *no* memory. Nothing carries over except **files in the repo**.
   → So: for any cross-machine work, **write a handoff document** (like
   `docs/workshop_pi5_bringup.md`). The documents ARE the bridge. Keep them current.

2. **A git repo living inside iCloud Drive does not sync reliably across machines.**
   iCloud copies the `.git` directory piece by piece and can evict ("dataless") loose
   objects, so a second machine may open a half-synced/broken repo. Convenient for
   editing, unreliable as the sync mechanism.
   → **GitHub is the single source of truth for moving code between machines and to
   the Pis**, NOT the iCloud folder.

3. **"I pushed it" must be verified, not assumed.** The incident that created this
   file: the Mac had ~15 commits that were never actually pushed; GitHub still held a
   stale 1-commit snapshot; a Mac session then wrote garage instructions that assumed
   the push was done. It wasn't. Hours of confusion followed.

## Golden rules

- **GitHub = source of truth.** Every machine and every Pi gets code by cloning/pulling
  from `github.com/honeycomb-modular/xylosome-hmi` — never by copying the iCloud folder.
- **`git pull` before you start, `git commit` + `git push` after you finish.** Every session.
- For ongoing work on a machine, **clone to a normal local folder** (`C:\dev`,
  `~/projects`) — do **not** run the live git repo from inside iCloud Drive on multiple
  machines. The iCloud copy is fine to read; don't make it the working repo on two
  machines at once.
- **Pushes need Hoyte's GitHub credentials**, which live in his machine accounts (Mac,
  or PC via GitHub Desktop). An AI session can read/edit files but **cannot authenticate
  a push** — it must hand the push to whichever machine Hoyte is on.

## Notes for the AI session (whichever machine you're on)

- **Ask / detect which machine you're on before giving terminal commands.** Don't hand a
  Mac `~/Library/...` command to a PC session. Prefer **machine-agnostic** steps or a GUI
  (GitHub Desktop's **Push origin** / **Pull** buttons — no terminal, works on both).
- **Verify GitHub state with uncached URLs.** The repo browse page
  (`github.com/.../xylosome-hmi`) can serve a *cached* copy that shows stale commit
  counts. To check what's really on `main`, fetch a **raw** file that only exists in the
  current tree, e.g.
  `https://raw.githubusercontent.com/honeycomb-modular/xylosome-hmi/main/CLAUDE.md` —
  raw.githubusercontent is not HTML-cached.
- **The `.claude/memory/` file is write-protected** in the Cowork session. Persist
  durable project knowledge **here in the repo** (this file, `DEVLOG.md`,
  `SESSION_NOTES.md`) instead — it syncs to GitHub and every clone.

## Status as of 2026-06-01

Resolved: the Mac pushed; GitHub `main` is now current through `ecaf0fc` (full tree —
`pi/`, `firmware/`, `electronics/`, `docs/`, etc.). Garage PC and Pi 5 can now clone/pull
real code. Next actual task: the Pi 5 transfer per `docs/workshop_pi5_bringup.md` §1→§3.
