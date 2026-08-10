# COOP.md — how to work on this rig without wasting Hoyte's time

**Read this before the first command of any session.** It exists because the
same handful of environment traps have burned entire sessions, repeatedly. None
of them are hard; all of them are already answered here.

Companion docs: `NETWORK.md` (full network reference), `SESSION_NOTES.md`
(garage-bench runbook), `PROJECT_OVERVIEW.md` (system map).

---

## 1. Working agreement

1. **Read the docs first.** Never guess network, build, deploy or launch steps —
   they are all written down. Guessing has cost multiple sessions.
2. **Verify live state before proposing a fix,** and check the *cheap* thing
   first. Confirm which setting is actually wrong before asking for a reboot or
   an irreversible change.
3. **One command at a time.** Give a single step, wait for the output, then the
   next. Do not dump a multi-step runbook and then ask whether it was run.
4. **If context was lost, say so and re-read these notes** — don't hand Hoyte a
   list of things he might have failed to do.
5. **Flag, don't silently fix.** Unrelated dead code or stale comments get
   mentioned, not rewritten (see `CLAUDE.md` §3).

---

## 2. Addresses and access

| Box | Address(es) | SSH |
|---|---|---|
| **Capture PC** (this dev box, camera + Xtium + `D:\capture`) | `192.168.10.1` + `192.168.2.50` (NIC **Ethernet 2**), Wi-Fi `192.168.4.30` | — |
| **Pi 5** `xylosome-pi` (HMI/pendant) | `192.168.10.3` **and** `192.168.2.3` — *same machine, one `eth0`* | `ssh -i ~/.ssh/id_ed25519 hoyte@192.168.10.3` |
| **Beckhoff C6920** (`xylod` motion daemon, `:5510`) | `192.168.2.2` | `ssh -i ~/.ssh/id_ed25519 hoyte@192.168.2.2` |

- **Use the existing key `~/.ssh/id_ed25519`** (comment `hoyte@grabber`). It is
  installed on both boxes. Check `ls ~/.ssh/*.pub` before ever asking for a
  password or minting a new key.
- **Pi `sudo` is NOPASSWD.** The **C6920's `sudo` is NOT** — root work there must
  go to Hoyte as `ssh -t hoyte@192.168.2.2 "sudo …"`.
- **Interactive password/sudo prompts do not work through the agent's `!`
  prompt** (no TTY — `ssh` submits empty and fails instantly, which looks like a
  wrong password but isn't). Anything needing typed input goes in a **real
  terminal window**, pasted without the leading `!`.
- The Pi 4 at `192.168.10.2` is retired. Ignore it everywhere.
- **The Pi's clock is badly skewed** (weeks behind). Compare Pi timestamps to
  each *other*, never to PC time.

---

## 3. Deploy PC → Pi (the Pi has no internet)

Never try to fix Pi internet or `git pull` from GitHub on the Pi. Push a bundle
over the `.10` link instead:

```bash
# on the PC
git bundle create <scratch>/xylosome.bundle main
python -m http.server 8099 --bind 192.168.10.1     # note the PID
```
```bash
# on the Pi
curl -fSL -o /tmp/xylo.bundle http://192.168.10.1:8099/xylosome.bundle
cd ~/xylosome-hmi && git stash push -u -m "pi-local $(date +%F)"
git pull /tmp/xylo.bundle main
cd pi/hmi && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(nproc)
```

- Build is **Unix Makefiles, not Ninja** — `deploy.sh`'s `-G Ninja` fails here.
- The Pi carries divergent local work; **always stash before pulling.**
- Kill only the bundle server's **PID** when done — never a broad `python` kill
  (the capture agent is python too).

### A deploy alone does NOT take effect

The HMI autostarts from `~/.config/labwc/autostart`, which only runs at session
start — so `pkill` does not respawn it and the **old binary keeps running**.
This is the #1 reason a "deployed" fix appears not to work.

```bash
ps -o pid,lstart,cmd -C xylosome_hmi     # started BEFORE the binary mtime? -> stale
date -r ~/xylosome-hmi/pi/hmi/build/xylosome_hmi
sudo systemctl reboot                    # Pi is back in ~15 s
pgrep -c -f xylosome_hmi                 # must be exactly 1 (two-instance trap)
```

---

## 3b. Deploy PC → C6920 (it has no internet either)

The C6920 has `origin` configured but **cannot reach GitHub** — its default route
is `192.168.2.1`, which does not route out. `git pull origin` there just fails.
Same answer as the Pi, but over the `.2` link and with `scp`, since the key is
installed (no http-server dance needed):

```bash
# on the PC — incremental from whatever the box already has
git bundle create <scratch>/xylo.bundle <boxHead>..<branch>
scp -i ~/.ssh/id_ed25519 <scratch>/xylo.bundle hoyte@192.168.2.2:/tmp/
```
```bash
# on the box — none of this needs sudo, so the agent can run it
cd ~/xylosome-hmi && git stash push -u -m "beckhoff-local $(date +%F)"
git fetch /tmp/xylo.bundle <branch> && git checkout -b <branch> FETCH_HEAD
cd beckhoff/xylod/build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j
```

### Build in the repo, never in a /tmp scratch tree

On 2026-08-09 a build was done in `/tmp/xylobuild` and installed from there
(`/usr/bin/install -m755 /tmp/xylobuild/.../xylod /usr/local/bin/xylod`, per
`journalctl`). The next reboot wiped `/tmp`, leaving the box running a daemon
**no source on the machine could rebuild** — and `~/xylosome-hmi` was 50 commits
stale on `main`, so a routine `make install` would have silently reverted it to
pre-`art-modes` xylod. Resynced onto `art-modes` 2026-08-10.

- The box's checkout is **CRLF**, so `git status` there reports whole-file
  rewrites that are mostly line-ending noise. Re-check with
  `git diff --ignore-cr-at-eol --stat` before believing it holds unsaved work.
- **Verify a sync:** `cmp build/xylod /usr/local/bin/xylod`. Nothing from the
  build path is baked into the binary, so a rebuild of matching source is
  byte-identical (proved 2026-08-10, sha256 `4136b989…`).

### Building does NOT deploy

The C6920's form of the §3 trap. `make -j` only fills `build/`; the service runs
`/usr/local/bin/xylod`. Installing needs **Hoyte's hands** — C6920 sudo has no
NOPASSWD and no TTY through the agent — and it restarts the daemon, dropping
every client (§5):

```bash
cd ~/xylosome-hmi/beckhoff/xylod/build && sudo make install && sudo systemctl restart xylod
```

---

## 4. Launching the Review Suite (capture PC)

```powershell
pwsh -File start-suite.ps1
```

Sets msys2 UCRT64 on `PATH` (libvips/Qt DLLs), `CAPTURE_DIR=D:/capture`,
`XYLOD_HOST=192.168.2.2`, and launches. Then verify it *actually* linked —
a window alone proves nothing:

```powershell
Get-NetTCPConnection -OwningProcess <pid>   # want 192.168.2.2:5510 AND 127.0.0.1:5521
```

- **Do not launch it from the agent's Bash tool** — the sandbox denies exec
  (`Permission denied`, exit 126), indistinguishable from a Smart App Control block.
- **Smart App Control** blocks this unsigned build. Check
  `(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy").VerifiedAndReputablePolicyState`
  → `0`=Off, `1`=On, `2`=Evaluation. Turned **off** on this box 2026-07-23.
  If it ever reads `1`: Windows Security → App & browser control → Smart App
  Control settings → **Off**. No reboot needed once the key reads `0`.
  Turning it off is **irreversible** without reinstalling Windows — say so first.
- VIPS-WARNING lines about heif/magick/poppler/openslide are harmless.
- After a force-kill, the next instance may fail to link to xylod for a few
  seconds (lingering socket) — relaunch once more.

---

## 4b. Known config drift — `/etc/xylod.conf` vs the repo

The C6920 runs `/etc/xylod.conf`, which is a **separate file** from
`beckhoff/xylod/config/xylod.conf` in this repo. Editing the repo copy does not
change the running daemon. As of 2026-07-23 they differ:

| setting | box (`/etc`) | repo |
|---|---|---|
| `line_blink_div` | **100** | 1000 |
| `line_blink_ms` | **10** | 30 |

Every other difference is inert — `jog_acc_degs2`, `do_line_blink`, `home_file`
are absent from the box's file but the compiled defaults in `Config.h:25-59`
already equal the repo values, so behaviour matches either way.

The two blink values are **on-box bench tuning that was never committed**, so
the box is the authority, not git. **Do not blind-copy the repo conf over
`/etc/xylod.conf`** — it would silently revert that tuning. Unresolved; decide
which direction to sync before touching either file. Installing to `/etc` needs
the C6920's sudo password (Hoyte) plus a `xylod` restart.

## 5. Things that must not be disturbed

- **The capture agent** (`capture/capture_agent.py`, SYSTEM scheduled task
  `XylosomeCaptureAgent`, log `C:\dev\capture_agent.log`). It owns the DALSA
  board and switches it between LIVE focus-waterfall and pass-triggered grab.
  Never restart it or toggle LIVE from code — that drops its links and breaks
  the working setup. Let Hoyte press LIVE / execute.
- **Restarting `xylod`** briefly drops every client (Pi HMI, suite, capture
  agent). They reconnect, but ask before doing it.
- **Never suggest LIVE as a diagnostic while capture is wedged.** The Suite's
  `LiveLink` blocks on the GUI thread, so a LIVE that can't get the board freezes
  the *entire* Suite (`Responding: False`, 0 s CPU, agent side `FinWait1`). It
  turns a bad-images problem into a frozen-Suite problem. Prove the grab path
  first — one scan with non-zero `collected` lines. Cost a session on 2026-08-09.

## 5b. Black frames — check the LEDs before anything else

`collected pass 0: 0 lines` / `peak 0/65535` is **never exposure** — zero lines
means the frame was never written, so you are seeing the empty buffer. Order:

1. **Grabber CL port LEDs.** Red = no pixel clock = camera or cabling. Both red
   on 2026-08-09 was a loose Camera Link contact.
2. **Restart the agent and read its startup block** (§5 caveats apply). All fields
   `None` with `clm reply: ''` = camera silent on serial too → power-cycle and
   reseat, *then* restart the agent so the defaults apply to a live camera.
   Healthy looks like `model HS-80-08K80-00-R`, `line.rate = 38000 -> 37986.7`.
3. Only then look at xylod/EL2521. Its `pass N end — emitted N lines` count is
   **computed, not measured** (`Sequencer.cpp:499`); it proves nothing arrived.
   The agent's `NO LINES - check the EL2521 emit` hint fires on any zero-line
   capture and misdirects.

Restarting the agent: `Stop-ScheduledTask` and `Start-ScheduledTask` **on one
line silently fails** (Stop returns before the task stops). Pause between them,
in an **elevated** window — the task is invisible from an unelevated session.

---

## 6. Homing — the short version

`home` always moves to `0°`; what used to drift was *where 0° is*. Zero comes
from the taught offset in `/var/lib/xylod/home_counts`; if that file is missing
xylod wake-zeroes to the current pose, giving a different home every start.

Teach it: jog to the spot, let the axis **stop** (`SetHome` is ignored unless
the sequencer is `Idle`), press **`[set home]`** on the HMI capture screen.

Verify:
```bash
ssh hoyte@192.168.2.2 'cat /var/lib/xylod/home_counts; \
  journalctl -u xylod --no-pager | grep -iE "absolute home|wake-zero|home taught" | tail'
```
Want `absolute home loaded (N counts)`, not `wake-zero to current pose`.
To test meaningfully, **jog well away from home before restarting** — restarting
while parked at home cannot tell the two branches apart.

Taught 2026-07-23: **8302582 counts**. Soft limits are ±180° *relative to zero*,
so re-teaching shifts the reachable envelope.
