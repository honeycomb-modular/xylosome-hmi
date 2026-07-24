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
