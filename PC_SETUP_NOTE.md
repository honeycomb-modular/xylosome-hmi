# PC — read this next time you sit down

**Goal:** work on the PC from a clean **local** clone, synced to the Mac via GitHub.
**Never** put this repo inside OneDrive / iCloud / any file-sync folder — that's what
corrupted the Mac copy (it spawned `main 2` conflict files and broke git).

---

## Already cloned it on the PC (outside OneDrive)?
Then you're set — just:
```
git pull
```
…before you start working, and `git commit && git push` when you stop.

## Not cloned yet?
1. Pick a normal local folder, e.g. `C:\dev` — **not** inside OneDrive or iCloud.
2. Clone:
   ```
   cd C:\dev
   git clone https://github.com/honeycomb-modular/xylosome-hmi.git
   ```
3. Work in `C:\dev\xylosome-hmi` from now on.

---

## The two-machine habit (PC + Mac)
- `git pull`  → when you sit down at a machine
- `git commit && git push`  → when you get up
- GitHub is the bridge between PC and Mac. Bounce between them freely.

Mac working copy is now `~/dev/xylosome-hmi` (also outside iCloud).
More detail in `garage_instructions.md`.
