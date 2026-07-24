# CLAUDE.md — XYLOSOME

Behavioral guidelines for AI coding sessions on this project.

## ⚠️ Architecture status (updated 2026-06-13)

**The motion stack moved from ClearCore to Beckhoff EtherCAT.**

- **ACTIVE:** the **Beckhoff** path — C6920 running headless Linux as a SOEM
  EtherCAT master (`beckhoff/`), driving a StepperOnline A6-EC servo (CiA-402
  CSP). The artist's speed curve has run on the real servo over EtherCAT
  (2026-06-12). The Pi HMI is retained and talks to the C6920 daemon (`xylod`).
- **STALE / FALLBACK:** the original **ClearCore** path (ClearCore + Minas A6
  pulse drive, commanded from the Pi over TCP). It is **deliberately kept, not
  deleted**, as a fallback in case the Beckhoff path doesn't pan out.

So: any document or code below that describes ClearCore as the live motion
controller is **legacy/fallback design**. Read it as such. Do not extend the
ClearCore path or delete it — leave it working and untouched unless asked.
For current motion work, start from `BECKHOFF_PORT.md` and `beckhoff/README.md`.

## Project context — read these first

Before touching any code, read:
- `COOP.md` — **READ THIS FIRST, EVERY SESSION. Working agreement, SSH/addresses, deploy, suite launch, and the environment traps that have repeatedly wasted Hoyte's time. Do not run a single command against the Pi, the C6920 or the suite before reading it.**
- `PROJECT_OVERVIEW.md` — **START HERE. Single source of truth for the whole system (motion, imaging, HMI, suite, hardware, workflow, open items) with a map to every other doc.**
- `WORKFLOW.md` — **how Hoyte works across his Mac + PC, and why GitHub (not iCloud) is the source of truth. Read this before moving any code between machines or to a Pi.**
- `BECKHOFF_PORT.md` — **ACTIVE motion stack: what the Beckhoff EtherCAT port built and what's left to verify on the bench.**
- `beckhoff/README.md` — C6920 daemon (`xylod`) bring-up: OS, network, build, first motion, service.
- `SESSION_NOTES.md` — Pi 4 vs Pi 5 targets, deploy sequences, SSH/build commands
- `DEVLOG.md` — session history, what's done, outstanding items
- `pi/hmi/METADATA_INFUSER.md` — metadata infuser spec and implementation notes
- `docs/concept/xylosome_ui_concept.docx` — full screen spec and pendant interaction model

**Active (and only) Pi is the Pi 5 `xylosome-pi` at 192.168.10.3 — labwc/Wayland,
Ninja. Reach it: `ssh -o PubkeyAuthentication=no hoyte@192.168.10.3` (password auth).
It also carries 192.168.2.3 to talk to the Beckhoff (192.168.2.2:5510).
The old Pi 4 at 192.168.10.2 has NOT been part of xylosome for a long time —
ignore every "Pi 4 = active dev unit" note below as stale.**

---

Behavioral guidelines to reduce common LLM coding mistakes.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

* State your assumptions explicitly. If uncertain, ask.
* If multiple interpretations exist, present them — don't pick silently.
* If a simpler approach exists, say so. Push back when warranted.
* If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

* No features beyond what was asked.
* No abstractions for single-use code.
* No "flexibility" or "configurability" that wasn't requested.
* No error handling for impossible scenarios.
* If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

* Don't "improve" adjacent code, comments, or formatting.
* Don't refactor things that aren't broken.
* Match existing style, even if you'd do it differently.
* If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

* Remove imports/variables/functions that YOUR changes made unused.
* Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

* "Add validation" → "Write tests for invalid inputs, then make them pass"
* "Fix the bug" → "Write a test that reproduces it, then make it pass"
* "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

*Karpathy guidelines via github.com/multica-ai/andrej-karpathy-skills*
