#!/usr/bin/env python3
# capture_agent.py - Xylosome capture agent (consolidated, always-on).
# One service on the capture PC that owns the camera + grabber and does all three:
#   :5521  camera settings bus (COM3 TLC)          - HMI drives (line rate, stages, gain, dir)
#   :5520  live-focus stream    (board, free-run)  - Suite LIVE button (waterfall + focus)
#   :5510  xylod client         (pass events)      - per-pass TIFF capture -> CAPTURE_DIR
#
# Single grabber -> LIVE and CAPTURE are mutually exclusive via one board lock.
# By workflow they never overlap (focus, then scan), so the hand-off is clean:
# LIVE holds the board while streaming; a scan holds it for its duration; whoever
# asks while the other holds it is told "board busy".
#
# Deps:  pip install pyserial numpy pythonnet tifffile
# Env:   XYLOD_HOST (default 192.168.2.2), CAPTURE_DIR (default D:\capture)
# PREREQ: CamExpert closed (COM3 + board are single-occupant).

import os, sys, re, json, socket, threading, time, ctypes, tempfile
import numpy as np
import serial
import tifffile

from pythonnet import load
load("netfx")
import clr
SAP = r"C:\Program Files\Teledyne DALSA\Sapera"
os.add_dll_directory(SAP + r"\Bin")
sys.path.append(SAP + r"\Components\NET\Bin")
clr.AddReference("DALSA.SaperaLT.SapClassBasic")
from DALSA.SaperaLT.SapClassBasic import SapLocation, SapAcquisition, SapBuffer, SapAcqToBuf
from System.Runtime.InteropServices import Marshal

COM, BAUD   = "COM3", 9600
SERVER      = "Xtium-CL_MX4_1"
PORT_CAM, PORT_LIVE = 5521, 5520
XYLOD_HOST  = os.environ.get("XYLOD_HOST", "192.168.2.2")
XYLOD_PORT  = 5510
CAPTURE_DIR = os.environ.get("CAPTURE_DIR", r"D:\capture")

# --- grabber-side line count (vertical resolution = aspect; width is fixed 8192) ---
# NOT a camera setting: line count belongs to the motion/trigger domain
# (HMI aspect box -> xylod -> EL2521 line trigger -> EXSYNC -> grabber frame).
# Until the physical trigger/pulse is wired, the camera runs internal sync and
# the grabber captures a fixed frame height, which we set here as the stand-in.
# When the box drives it, this same value is what the aspect drag will set.
CAM_WIDTH   = 8192                       # sensor width (fixed)
LINE_MIN, LINE_MAX = 1, 65000
CAP_LINES   = max(LINE_MIN, min(LINE_MAX, int(os.environ.get("CAP_LINES", "8192"))))
LIVE_LINES = 64     # short live-focus frame: fast (~ms) grabs of consecutive
                    # lines so the waterfall flows smoothly (vs a full 8192 grab)
os.makedirs(CAPTURE_DIR, exist_ok=True)

# --- camera output format: bit depth, taps, and the rate ceiling that follows ---
# `clm` picks the Camera Link configuration, tap count AND bit depth together;
# `sot` picks the pixel strobe. Only these two rows of manual Table 14 (the
# HS-80-08k80 one) matter here — the model has no 12-bit mode that keeps 8 taps,
# so 12-bit costs half the line-rate ceiling. CAM_BITS switches the camera
# commands, the matching .ccf, the ssf clamp and RAW_SHIFT together; it does NOT
# retune xylod's `line_max_hz`, which lives on the C6920 (see max_hz below).
#
# Each mode needs its OWN .ccf: the grabber has to be told the same tap layout
# the camera is emitting. Both files are CamExpert-built and verified grabbing —
# do not hand-edit the depth/tap keys into one of them. That was tried on
# 2026-07-24 and hung the board: the miss was `Horizontal Active`, the PER-TAP
# line width (8192/8 = 1024 at 8 taps, 8192/4 = 2048 at 4), so the grabber waited
# for 4096 pixels a line while the camera sent 8192 and SapAcquisition never
# returned. Sapera's own stock reference files leave it at 1024 in both their
# 8-tap and 4-tap variants, which is what made it look like it did not matter.
CAM_BITS = 12
CAM_MODE = {                                          # clm  sot   max line rate
    8:  {"clm": 21, "sot": 640, "max_hz": 68610,      # Full mono, 8 taps
         "ccf": "HS-80-08K80_Full_8tap_8bit_WORKING.ccf"},
    12: {"clm": 16, "sot": 320, "max_hz": 38314,      # Full mono path, 4 taps
         "ccf": "T_HS-80-08K80-00-R_Linescan_HS-80-08K80_4tap_12bit_WORKING.ccf"},
}[CAM_BITS]
BASE_CCF = SAP + r"\CamFiles\User" + "\\" + CAM_MODE["ccf"]
# The board hands back uint16 with the data right-justified (an 8-bit camera gave
# values 0..255, a 12-bit one gives 0..4095), so a plain 16-bit reader renders the
# frame near-black. Shift once at the source instead: everything downstream — the
# saved TIFF, the live view, the suite — then sees an honest left-justified 16-bit
# image, which is what every TIFF viewer and `VipsEngine::to8()` already assume.
RAW_SHIFT = 16 - CAM_BITS

# --- line-trigger sync mode -------------------------------------------------
# 'exsync' (default, verified 2026-07-24): the EL2521 line trigger paces the
# camera via the grabber (EXSYNC on CC1) — every captured line is motion-locked,
# so no time-crop is needed. Camera runs external sync (sem 3) during a scan.
# 'freerun': the old fallback — camera internal-sync + a generous frame cropped
# to the sweep by time. LIVE focus always stays free-run regardless.
CAP_SYNC = os.environ.get("CAP_SYNC", "exsync").lower()
EXT_SYNC = CAP_SYNC == "exsync"
# WORKING.ccf -> ext-sync: 6-line diff captured from CamExpert. The grabber
# generates EXSYNC on CC1 from the shaft-encoder (EL2521 phase A) pulses.
# See memory el2521-cable-verified for the derivation.
EXTSYNC_EDITS = {
    "Shaft Encoder Enable":  "1",
    # Decode direction from the A/B phase pair and clock lines on the FORWARD
    # sweep only. The .ccf default is 0 = DIRECTION_IGNORE, which counts the
    # post-pass return exactly like the sweep — every scan came back as its
    # forward half plus a mirrored return half, always 50/50 because the return
    # retraces the identical arc. 1 = DIRECTION_FORWARD, 2 = DIRECTION_REVERSE;
    # which one is "forward" depends on the phase order, so if this yields an
    # empty frame, it's the other one.
    "Shaft Encoder Direction": "1",
    "Line Trigger Enable":   "1",
    "Line Trigger Method":   "1",
    "Line Trigger Duration": "340",
    "Line Integrate Input":  "0x1020001",   # CC1 = Pulse #1 (EXSYNC out)
}

# ---------- camera serial (COM3) ----------
ser_lock = threading.Lock()
ser = serial.Serial(COM, BAUD, timeout=0.3)

def cam_cmd(cmd):
    with ser_lock:
        ser.reset_input_buffer()
        ser.write((cmd + "\r").encode())
        buf = ""; deadline = time.time() + 3
        while time.time() < deadline:
            chunk = ser.read(4096).decode(errors="replace")
            if chunk:
                buf += chunk
                if buf.rstrip().endswith("OK>"): break
    return buf

def field(text, label):
    for line in text.splitlines():
        m = re.search(re.escape(label) + r"\s*:\s*(.+?)\s*$", line)
        if m: return m.group(1).strip()
    return None

def read_state():
    g = cam_cmd("gcp")
    sync = field(g, "SYNC Frequency"); gain = field(g, "Analog Gain (dB)"); st = field(g, "Stage Selection")
    return {"line.rate": float(re.sub(r"[^\d.]", "", sync)) if sync else None,
            "tdi.stages": int(st) if st else None,
            "gain": gain.split()[0] if gain else None,
            "scan.dir": field(g, "CCD Direction") or "",
            "model": field(g, "Camera Model No."),
            "clm": field(g, "Camera Link Mode")}

def set_cam_external(on):
    # Camera exposure mode over COM3: 3 = external EXSYNC (the grabber, paced by
    # the EL2521, triggers every line), 7 = internal free-run. Only used in
    # EXT_SYNC mode; the camera must return to sem 7 for LIVE focus / idle.
    # Volatile (not saved with wus), so we set it explicitly each scan.
    cam_cmd("sem 3" if on else "sem 7")

STAGES = {16, 32, 48, 64, 80, 96}
def apply_set(key, value):
    if key == "tdi.stages":
        v = int(value)
        if v not in STAGES: return False, "stages 16..96"
        cam_cmd("stg %d" % v); return True, "ok"
    if key == "line.rate":
        v = float(value)
        if not (3500 <= v <= CAM_MODE["max_hz"]):
            return False, "3500..%d Hz" % CAM_MODE["max_hz"]
        cam_cmd("ssf %d" % int(v)); return True, "ok"
    if key == "gain":
        v = float(value)
        if not (-10 <= v <= 10): return False, "-10..10 dB"
        cam_cmd("sag 0 %s" % v); return True, "ok"
    if key == "scan.dir":
        s = str(value).lower()
        if s in ("forward", "fwd", "0"): cam_cmd("scd 0"); return True, "ok"
        if s in ("reverse", "rev", "1"): cam_cmd("scd 1"); return True, "ok"
        return False, "forward|reverse"
    return False, "unknown key"

# Camera settings pushed on agent startup, overriding whatever the camera
# powered up with. Forward scan direction is markedly sharper on the bench;
# 48 TDI stages forward is the current best (supersedes the old 16-stage note).
# line.rate is not the old free-run 8500: under ext sync the camera's own rate no
# longer sets the scan geometry (the EL2521 emit does) — it is only the readout
# CEILING, and a trigger arriving before the previous line is read out is
# silently dropped. So it is set to xylod's `line_max_hz`, i.e. the fastest
# trigger it will ever emit: the camera can then service anything the curve asks
# for and no per-curve tuning is needed. Verified free: 20000 vs 50000 are
# indistinguishable in brightness, because under `sem 3` the EXSYNC period sets
# exposure, not ssf.
#
# 38000 (was 50000) since the move to 12-bit: the hard ceiling in clm 16 is
# 38314 Hz, half the 68610 of 8-bit 8-tap. The camera quantises this request down
# to 37986.7 (see _startup_ok), so **`line_max_hz` in the C6920's /etc/xylod.conf
# is 37000, not 38000** — below the ACHIEVED rate, with margin. Nothing enforces
# that across the two machines, and a trigger above what the camera can service
# is dropped with no error anywhere.
#
# gain -6 dB: the camera powers up at 0 and that is hotter than wanted, so it is
# asserted here rather than being re-dialled by hand every session.
STARTUP_CAM = [("scan.dir", "forward"), ("line.rate", "38000"), ("tdi.stages", "48"),
               ("gain", "-6")]

# STARTUP_CAM above is only the FACTORY position. Anything the artist changes
# from the pendant is remembered here and wins over it on the next start —
# otherwise every agent restart silently undid their tuning, which made the
# camera rows on the HMI feel like they had not taken.
CAM_STATE_FILE = os.path.join(CAPTURE_DIR, "camera_settings.json")

def load_saved_cam():
    try:
        with open(CAM_STATE_FILE) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}

def save_cam_setting(key, value):
    d = load_saved_cam()
    d[key] = value
    try:
        # write-then-rename: a half-written file would otherwise be read back as
        # "no saved settings" and quietly drop everything
        tmp = CAM_STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=1, sort_keys=True)
        os.replace(tmp, CAM_STATE_FILE)
    except Exception as e:
        print("  [warn] cannot persist camera settings: %s" % e)

def _startup_ok(key, want, got):
    if got is None: return False
    if key == "scan.dir":   return str(want).lower() in str(got).lower()
    if key == "tdi.stages": return str(got) == str(int(want))
    # ssf is quantised by the camera's own clock, and the step is not constant:
    # 8500 lands on 8499.79, 50000 lands exactly, 38000 lands on 37986.7. A flat
    # 5 Hz tolerance called that last one FAILED when it had taken fine, so scale
    # the tolerance with the requested rate.
    if key == "line.rate":  return abs(float(got) - float(want)) < max(5.0, float(want) * 0.001)
    # gain reads back with a decimal ("-6.0"), so compare as a number
    if key == "gain":       return abs(float(got) - float(want)) < 0.05
    return True

def apply_startup_defaults():
    # A freshly powered camera can swallow the first serial command(s) while it
    # boots — scan.dir (first in the list) was the one silently lost, so the
    # camera stayed reverse. apply_set never reads back, so it looked "ok".
    # Wait for the camera to answer, then read back each default and retry
    # until it actually took.
    for _ in range(20):
        if cam_cmd("gcp").rstrip().endswith("OK>"): break
        time.sleep(0.5)
    # Free-run BEFORE anything is written. If the previous run died mid-scan the
    # camera is still in sem 3, and there `ssf` writes are ignored while the
    # readback reports the *measured* external frequency — 0.0 with no EXSYNC. So
    # every startup default silently failed to take and the camera ended up
    # free-running with no line rate: no pixel clock, red CL2 on the grabber.
    # (This used to sit at the END of this function.)
    set_cam_external(False)
    # Output format next: clm/sot decide the tap layout and bit depth on the
    # wire, and CAM_MODE's .ccf has already told the grabber to expect that
    # layout. Asserting it here keeps the two ends in step no matter what the
    # camera powered up with (or what a CamExpert session last left saved).
    r_clm = cam_cmd("clm %d" % CAM_MODE["clm"])
    r_sot = cam_cmd("sot %d" % CAM_MODE["sot"])
    print("  startup output     = %d-bit (clm %d, sot %d) -> camera reports clm %s"
          % (CAM_BITS, CAM_MODE["clm"], CAM_MODE["sot"], read_state().get("clm")))
    # Print the camera's literal replies: a rejected clm/sot leaves the camera and
    # the grabber framing each other differently, which shows up as a red CL2 LED
    # (no pixel clock) rather than as any error here.
    print("    clm reply: %r" % (r_clm,))
    print("    sot reply: %r" % (r_sot,))
    saved = load_saved_cam()
    for key, factory in STARTUP_CAM:
        val = str(saved[key]) if key in saved else factory
        got = None
        for _ in range(3):
            apply_set(key, val)
            got = read_state().get(key)
            if _startup_ok(key, val, got): break
            time.sleep(0.3)
        print("  startup %-11s= %-8s -> %s%s%s"
              % (key, val, got,
                 "  (saved)" if key in saved else "",
                 "" if _startup_ok(key, val, got) else "  (FAILED)"))
    print("  startup sync       = %-8s (camera sem %s)"
          % (CAP_SYNC, "3 per-scan" if EXT_SYNC else "7 fixed"))

# ---------- board (Sapera) ----------
LIVE_STALE_S = 10.0   # a live session that has not shipped a frame this long is dead

class BoardLock:
    # Single grabber owner. A bare Lock told us nothing when it leaked: the
    # refusal could only guess ("scan running?") and there was no way to see who
    # actually held the board, so a stranded LIVE session meant every later LIVE
    # said "board busy" until the whole agent was restarted.
    #
    # Two changes: the holder is recorded, and a holder that has stopped making
    # progress can be asked to let go. We never STEAL the lock — two owners on
    # one grabber is the exact thing it exists to prevent. The stale holder's
    # socket is shut down instead, which unblocks it and lets its own finally
    # release the board through the normal path.
    def __init__(self):
        self._lk = threading.Lock()
        self.owner = None
        self.since = 0.0
        self.alive = None     # callable -> False once the holder has stalled
        self.evict = None     # callable that makes the holder let go by itself

    def acquire(self, who, alive=None, evict=None):
        if not self._lk.acquire(blocking=False): return False
        self.owner, self.since = who, time.time()
        self.alive, self.evict = alive, evict
        return True

    def release(self):
        self.owner = self.alive = self.evict = None
        self.since = 0.0
        try: self._lk.release()
        except RuntimeError: pass

    def status(self):
        if not self.owner: return "free"
        return "%s, held %.0fs" % (self.owner, time.time() - self.since)

    def reap(self):
        # Called by whoever was just refused: if the holder has stalled, poke it
        # so it releases. Returns True if a reap was attempted.
        if not self.owner or self.alive is None: return False
        try:
            if self.alive(): return False
        except Exception:
            pass
        print("board: reaping stalled holder (%s)" % self.status())
        if self.evict:
            try: self.evict()
            except Exception: pass
        return True

board_lock = BoardLock()

_ccf_cache = {}
def _ccf_for(lines, ext=EXT_SYNC):
    # Derive a .ccf whose grabber frame height (Crop Height / Scale Vertical) is
    # `lines`. When `ext`, also apply EXTSYNC_EDITS so the grabber is paced by the
    # EL2521 line trigger (EXSYNC). Bit depth and tap layout are NOT patched here
    # — they come from the mode's own CamExpert-built base file (see CAM_MODE).
    # The base .ccf is read-only under Program Files, so write the derived copy to
    # temp. Cached per (lines, ext).
    lines = max(LINE_MIN, min(LINE_MAX, int(lines)))
    key = (lines, ext)
    cached = _ccf_cache.get(key)
    if cached and os.path.exists(cached):
        return cached
    with open(BASE_CCF, "r", encoding="latin-1") as fh:
        txt = fh.read()
    # re.sub is a silent no-op when the key is absent, so a base .ccf that does
    # not carry one of these would drop that setting with no error — the EXSYNC
    # keys failing that way is exactly what puts the mirrored scans back. Count
    # the substitutions and shout if any key missed.
    missing = []
    def put(text, k, v):
        text, n = re.subn(r"(?m)^" + re.escape(k) + r"=.*$", "%s=%s" % (k, v), text)
        if n == 0: missing.append(k)
        return text

    txt = put(txt, "Crop Height",    lines)
    txt = put(txt, "Scale Vertical", lines)
    if ext:
        for k, v in EXTSYNC_EDITS.items():
            txt = put(txt, k, v)
    if missing:
        print("capture: WARNING - %s lacks these keys, settings NOT applied: %s"
              % (os.path.basename(BASE_CCF), ", ".join(missing)))
    out = os.path.join(tempfile.gettempdir(),
                       "xylosome_%s_%d.ccf" % ("ext" if ext else "free", lines))
    with open(out, "w", encoding="latin-1") as fh:
        fh.write(txt)
    _ccf_cache[key] = out
    return out

class Grabber:
    def __init__(self, lines=CAP_LINES, ext=EXT_SYNC):
        self.ext = ext
        self.loc = SapLocation(SERVER, 0)
        self.acq = SapAcquisition(self.loc, _ccf_for(lines, ext))
        self.buf = SapBuffer(1, self.acq, SapBuffer.MemoryType.ScatterGather)
        self.xfer = SapAcqToBuf(self.acq, self.buf)
        for o in (self.acq, self.buf, self.xfer):
            if not o.Create(): raise RuntimeError("Sapera Create failed: " + o.GetType().Name)
        self.w = int(self.buf.Width); self.h = int(self.buf.Height); self.n = self.w * self.h
        self.ptr = Marshal.AllocHGlobal(self.n * 2)
    def arm(self):
        # Start the transfer. Under ext sync the buffer only fills as EXSYNC pulses
        # arrive, so this can (and must) happen before the sweep starts emitting.
        # Clear first so the rows past the end of the sweep are deterministically
        # zero — that is what makes filled_lines() exact, and it stops a short pass
        # from showing the previous pass's tail. Only under ext sync: this runs in
        # the settle window there, whereas free-run arms at pass_start where
        # nothing slow may precede the Snap.
        # Reset the transfer FIRST, every time. Abort was only ever called on an
        # incomplete frame, so after a full pass the next Snap was issued on a
        # transfer that had completed and never been reset — and pass 0 is the
        # only pass that never inherits one. Passes after it receive nothing at
        # all, even given seconds to arrive, which is what a Snap that never
        # took looks like. Aborting an idle transfer is harmless.
        try: self.xfer.Abort()
        except Exception: pass
        if self.ext: self.buf.Clear()
        self.xfer.Snap(1)
    def collect(self, timeout_ms=None, abort=False):
        # allow enough time even for a tall frame at the slowest line rate
        if timeout_ms is None:
            timeout_ms = max(5000, int(self.h / 3500.0 * 1500) + 3000)
        self.full = bool(self.xfer.Wait(timeout_ms))
        if abort and not self.full:
            try: self.xfer.Abort()      # partial frame: stop it so the next arm is clean
            except Exception: pass
        self.buf.Read(0, 0, self.n, self.ptr)
        raw = ctypes.string_at(int(self.ptr.ToInt64()), self.n * 2)
        img = np.frombuffer(raw, dtype="<u2").reshape(self.h, self.w)
        return img << RAW_SHIFT      # right-justified board data -> true 16-bit
    def frame(self):
        self.arm(); return self.collect()
    def close(self):
        try: Marshal.FreeHGlobal(self.ptr)
        except Exception: pass
        for o in (self.xfer, self.buf, self.acq):
            try: o.Destroy()
            except Exception: pass

def filled_lines(img):
    # How many rows the sweep actually delivered. Under ext sync the grab fills one
    # row per EXSYNC pulse and stops when the sweep ends, leaving the rest of the
    # (cleared) buffer at zero — so the last non-zero row is the end of the scan.
    # 0 means nothing arrived at all, which is a trigger fault, not a short sweep.
    nz = np.flatnonzero(img.max(axis=1))
    return int(nz[-1]) + 1 if nz.size else 0

def focus_metric(l8):
    g = np.diff(l8.astype(np.float32)); return float(np.sqrt(np.mean(g * g)))

# ---------- :5520 live focus ----------
def live_server():
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT_LIVE)); srv.listen(4)
    print("live-focus on :%d" % PORT_LIVE)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=live_client, args=(conn, addr), daemon=True).start()

def live_client(conn, addr):
    conn.sendall((json.dumps({"ev": "welcome", "version": "1.0",
                              "camera": read_state().get("model"), "sim": False}) + "\n").encode())
    rx = b""; streaming = False; width = 1024; max_hz = 30.0; grab = None; peak = 1e-6; have = False
    last_ok = time.time()          # last frame actually shipped — the liveness signal
    conn.settimeout(0.005)
    try:
        while True:
            try:
                data = conn.recv(4096)
                if not data: break
                rx += data
                while b"\n" in rx:
                    line, rx = rx.split(b"\n", 1)
                    if not line.strip(): continue
                    m = json.loads(line); cmd = m.get("cmd")
                    if cmd == "live_start":
                        width = int(m.get("width", 1024)); max_hz = float(m.get("maxHz", 30))
                        if not streaming:
                            if not board_lock.acquire(
                                    "live %s:%s" % addr,
                                    alive=lambda: (time.time() - last_ok) < LIVE_STALE_S,
                                    evict=lambda: conn.shutdown(socket.SHUT_RDWR)):
                                # Say who has it — the old message could only guess.
                                reaped = board_lock.reap()
                                conn.sendall((json.dumps({"ev": "error", "text":
                                    "board busy (%s)%s" % (board_lock.status(),
                                    " - stalled holder reaped, press LIVE again" if reaped else "")
                                }) + "\n").encode())
                                continue
                            have = True
                            last_ok = time.time()
                            try: grab = Grabber(lines=LIVE_LINES, ext=False)  # live focus is always free-run
                            except Exception as e:
                                board_lock.release(); have = False
                                conn.sendall((json.dumps({"ev": "error", "text": str(e)}) + "\n").encode()); continue
                            streaming = True; peak = 1e-6; print("LIVE start", addr)
                    elif cmd == "live_stop":
                        if streaming:
                            streaming = False; grab.close(); grab = None
                            if have: board_lock.release(); have = False
                        conn.sendall(b'{"ev":"live_stopped"}\n'); print("LIVE stop", addr)
            except socket.timeout: pass
            except OSError: break
            if not streaming: time.sleep(0.03); continue
            # Bounded, and aborted on timeout: frame() leaves a timed-out transfer
            # running, which poisons the next arm. 64 free-run lines take ~2 ms, so
            # 2 s is already absurdly generous — it just has to end.
            try:
                grab.arm()
                img = grab.collect(timeout_ms=2000, abort=True)
            except Exception as e:
                conn.sendall((json.dumps({"ev": "error", "text": "grab: " + str(e)}) + "\n").encode()); break
            # send ALL the (consecutive) lines of the short live frame — a fast,
            # smooth waterfall. Downsample the sensor width + cast in one shot.
            h, w = img.shape
            step = max(1, w // width)
            ds = (img[:, ::step][:, :width] >> 8).astype(np.uint8)
            if ds.shape[1] < width:
                ds = np.pad(ds, ((0, 0), (0, width - ds.shape[1])))
            g = np.diff(ds.astype(np.float32), axis=1)
            lf = float(np.sqrt(np.mean(g * g)))          # focus over the whole block
            block = ds.tobytes()
            peak = max(peak, lf); fn = min(1.0, lf / peak)
            hdr = json.dumps({"ev": "lines", "count": h, "width": width,
                              "bytes": len(block), "focus": round(fn, 4), "tMs": int(time.time() * 1000)}) + "\n"
            try: conn.sendall(hdr.encode() + bytes(block))
            except OSError: break
            last_ok = time.time()          # progress: this session is not stalled
            time.sleep(1.0 / max_hz)
    finally:
        if grab: grab.close()
        if have:
            try: board_lock.release()
            except Exception: pass
        conn.close()

# ---------- :5521 settings ----------
_clients = set()
def _bcast(o):
    for c in list(_clients):
        try: c.sendall((json.dumps(o) + "\n").encode())
        except OSError: pass

def cam_server():
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT_CAM)); srv.listen(8)
    print("camera settings on :%d" % PORT_CAM)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=cam_client, args=(conn, addr), daemon=True).start()

def cam_client(conn, addr):
    _clients.add(conn)
    f = conn.makefile("r")
    try:
        for line in f:
            line = line.strip()
            if not line: continue
            try: m = json.loads(line)
            except ValueError: conn.sendall(b'{"ack":"?","ok":false}\n'); continue
            cmd = m.get("cmd")
            if cmd == "hello":
                conn.sendall((json.dumps({"ev": "welcome", "camera": read_state().get("model"), "version": "1.0"}) + "\n").encode())
            elif cmd == "get":
                conn.sendall((json.dumps(dict({"ev": "state"}, **read_state())) + "\n").encode())
            elif cmd == "set":
                key, val = m.get("key"), m.get("value")
                ok, note = apply_set(key, val)
                if ok: save_cam_setting(key, val)   # survives the next agent start
                print("  set %s=%s -> ok=%s (%s)" % (key, val, ok, note))
                conn.sendall((json.dumps({"ack": "set", "ok": ok, "key": key, "value": val, "note": note}) + "\n").encode())
                if ok: _bcast(dict({"ev": "state"}, **read_state()))
            else:
                conn.sendall((json.dumps({"ack": cmd, "ok": False}) + "\n").encode())
    except (OSError, ConnectionError): pass
    finally:
        _clients.discard(conn); conn.close()

# ---------- :5510 xylod client -> per-pass capture ----------
def _max_seq():
    # Continue numbering past whatever is already on disk so a restart never
    # reuses a filename (reused names get absorbed by old sidecars -> blank).
    mx = 0
    try:
        for fn in os.listdir(CAPTURE_DIR):
            if fn.startswith("scan_"):
                n = fn[5:].split("_", 1)[0]
                if n.isdigit(): mx = max(mx, int(n))
    except OSError: pass
    return mx

def xylod_client():
    seq = _max_seq(); pass_filter = {}; grab = None; have = False; scan_settings = {}
    ps_time = {}   # pass -> (recv_monotonic, pass_start tMs)
    pending = {}   # pass -> (full frame, filter) held between pass_start and pass_end
    ext_lines = {} # pass -> rows the sweep actually delivered (ext sync only)
    in_seq = False # a sequence is in flight (board opened, or the open was refused)
    armed = None   # pass index whose EXSYNC snap is running, awaiting collect
    planned = 0    # lines xylod last said a pass will deliver (status, 25 Hz)

    def open_board():
        nonlocal seq, grab, have
        seq += 1
        # Frame height = the lines xylod says this pass will deliver (the HMI aspect
        # bar, after xylod's rate clamp). Sizing to it is what makes the aspect real:
        # a wide image needs more lines than the old fixed 8192 could hold, and the
        # tail crop can only shorten a frame, never extend one. Fall back to
        # CAP_LINES when xylod is too old to report it, or in fixed-rate mode.
        # CLAMP an over-tall request, never collapse it: asking for more lines
        # than the board can hold should still deliver the TALLEST frame we can.
        # This used to fall back to CAP_LINES, so a 65536-line static scan (536
        # over LINE_MAX) came back as 8192 lines — and since CAP_LINES equals the
        # sensor width that reads as a deliberate square rather than an error.
        # Cost a whole 78 s scan on 2026-07-25. CAP_LINES is now only for the
        # genuine "xylod never told us" case.
        want  = planned if planned else CAP_LINES
        lines = min(LINE_MAX, max(LINE_MIN, want))
        lines = min(LINE_MAX, (lines + 3) & ~3)   # keep the buffer 4-line aligned;
                                                  # rounding UP is free, the tail crop
                                                  # drops the spare rows anyway
        # Say which of the three cases this is — a silent clamp is what hid the
        # bug above.
        note = ("" if planned else " (no plannedLines)") if planned <= LINE_MAX \
               else " (clamped from %d)" % planned
        # Log BEFORE the serial + Sapera calls below. Both can block (the camera
        # goes silent in sem 3 until EXSYNC arrives; creating the acquisition can
        # stall if the board cannot lock to the camera's Camera Link framing), and
        # with the only print at the far end a stall looked exactly like "the agent
        # never received the event" — which cost a whole diagnosis on 2026-07-24.
        print("CAPTURE seq %d opening (%s) %d lines%s" % (seq, CAP_SYNC, lines, note))
        if EXT_SYNC: set_cam_external(True)   # camera -> external EXSYNC for the scan
        # A scan outranks a focus session: if LIVE has stranded the board, ask the
        # stalled holder to let go and try once more, rather than silently
        # skipping the artist's scan.
        who = "capture seq %d" % seq
        have = board_lock.acquire(who)
        if not have and board_lock.reap():
            time.sleep(0.3)
            have = board_lock.acquire(who)
        if have:
            try:
                grab = Grabber(lines=lines)
                print("CAPTURE seq %d board open (%s) %d lines%s"
                      % (seq, CAP_SYNC, lines, note))
            except Exception as e:
                print("capture: board open failed:", e); board_lock.release(); have = False; grab = None
                if EXT_SYNC: set_cam_external(False)
        else:
            print("capture: board busy (%s), skipping seq %d" % (board_lock.status(), seq)); grab = None
            if EXT_SYNC: set_cam_external(False)

    def close_board():
        nonlocal grab, have, in_seq, armed
        if grab:
            try: grab.close()
            except Exception: pass
            grab = None
        if have:
            try: board_lock.release()
            except Exception: pass
            have = False
        if EXT_SYNC:   # never strand the camera in sem 3
            try: set_cam_external(False)
            except Exception: pass
        in_seq = False; armed = None

    while True:
        try:
            c = socket.create_connection((XYLOD_HOST, XYLOD_PORT)); f = c.makefile("r")
            c.sendall(b'{"cmd":"hello","client":"capture"}\n')
            print("xylod connected %s:%d" % (XYLOD_HOST, XYLOD_PORT))
            for line in f:
                line = line.strip()
                if not line: continue
                m = json.loads(line); ev = m.get("ev")
                if ev == "status":
                    # EXT_SYNC pre-roll (status is broadcast at 25 Hz). Every pre-pass
                    # state — filter -> reposition ("moving") -> settle — holds lineHz
                    # at 0, so the board can be opened and the snap armed there, before
                    # the first EXSYNC pulse. Arming at pass_start instead cost the
                    # first ~0.2 s of the sweep. `pass` is -1 outside a sequence, which
                    # is what separates a scan's reposition from a jog or a home move.
                    if not EXT_SYNC: continue
                    st = m.get("state"); p = int(m.get("pass", -1))
                    planned = int(m.get("plannedLines") or 0)
                    if p >= 0 and not in_seq:
                        in_seq = True; open_board()
                    if in_seq and grab and armed is None and st == "settle" and p >= 0:
                        # settle is 300ms; the arm (buffer clear + Snap) must fit inside
                        # it, so log what it cost — if this approaches 300 the clear has
                        # to go and the tail crop needs another source.
                        try:
                            t_arm = time.monotonic(); grab.arm(); armed = p
                            print("armed pass %d during settle (%dms)"
                                  % (p, (time.monotonic() - t_arm) * 1000))
                        except Exception as e: print("capture: arm failed:", e)
                    if in_seq and p < 0 and st in ("idle", "fault", "estop"):
                        close_board()   # stop / fault mid-scan: no seq_done ever comes
                elif ev == "pass_start":
                    p = int(m.get("pass", -1)); filt = m.get("filter", p)
                    pass_filter[p] = filt
                    t_ps = time.monotonic(); ps_time[p] = (t_ps, m.get("tMs"))
                    if EXT_SYNC:
                        # normally armed during settle already; arm here only if that
                        # window was missed (agent connected mid-sequence)
                        if not in_seq:
                            in_seq = True; open_board()
                        if grab and armed is None:
                            try: grab.arm(); armed = p; print("capture: late arm at pass_start (settle missed)")
                            except Exception as e: print("capture: arm failed:", e)
                        if p == 0 and grab:
                            scan_settings = read_state()
                    else:
                        # freerun fallback: grab a generous free-run frame at motion
                        # start, HOLD it to pass_end, crop to the sweep by time.
                        # Nothing slow may run before the Snap.
                        if p == 0: open_board()
                        if grab:
                            try:
                                t0 = time.monotonic()
                                img = grab.frame()
                                if p == 0:
                                    scan_settings = read_state()
                                pending[p] = (img, filt)
                                print("grabbed pass %d: %d lines, snap +%.0fms after pass_start"
                                      % (p, img.shape[0], (t0 - t_ps) * 1000))
                            except Exception as e:
                                print("capture grab failed:", e); pending.pop(p, None)
                elif ev == "pass_end":
                    p = int(m.get("pass", -1))
                    _t, ps_tMs = ps_time.get(p, (None, None))
                    pe_tMs = m.get("tMs")
                    if EXT_SYNC and grab and armed == p:
                        # the sweep is over, so no further EXSYNC pulse can arrive:
                        # a short grace, then take whatever filled
                        try:
                            # A short grace, then take whatever filled. Tried 4 s
                            # on 2026-08-09 in case lines were still in flight —
                            # recovered nothing, passes 1+ were still zero. They
                            # never arrive; waiting longer only slows the failure.
                            img = grab.collect(400, abort=True)
                            pending[p] = (img, pass_filter.get(p, p))
                            ext_lines[p] = filled_lines(img)
                            print("collected pass %d: %d lines%s"
                                  % (p, ext_lines[p], "" if grab.full else " (frame not filled)"))
                        except Exception as e:
                            print("capture collect failed:", e)
                        armed = None
                    if p in pending:
                        img, filt = pending.pop(p)
                        motion_ms = (pe_tMs - ps_tMs) if (ps_tMs is not None and pe_tMs is not None) else -1
                        if EXT_SYNC:
                            # EXSYNC: every delivered row is a motion-locked line, so keep
                            # exactly those and drop the unfilled tail. No lines at all is a
                            # trigger fault — save the whole frame so it stays diagnosable.
                            n = ext_lines.pop(p, 0)
                            lines = n or img.shape[0]
                            over = "" if n else "  (NO LINES — check the EL2521 emit)"
                        else:
                            rate = float(scan_settings.get("line.rate") or 0)
                            want = int(motion_ms / 1000.0 * rate) if (motion_ms > 0 and rate > 0) else img.shape[0]
                            lines = max(1, min(img.shape[0], want))
                            over = " (sweep exceeded frame — lower line rate)" if want > img.shape[0] else ""
                        name = "scan_%04d_p%d_%s.tif" % (seq, p, filt)
                        tmp = os.path.join(CAPTURE_DIR, "." + name + ".part")
                        try:
                            tifffile.imwrite(tmp, img[:lines],
                                             metadata={"camera": scan_settings, "bits": CAM_BITS})
                            os.replace(tmp, os.path.join(CAPTURE_DIR, name))
                            # peak is in left-justified 16-bit: full scale is 65535
                            # whatever CAM_BITS is. A peak stuck at/below 255 means the
                            # data never left the low byte — .ccf Pixel Mask or clm.
                            print("saved %s | motion %dms -> %d/%d lines | peak %d/65535%s"
                                  % (name, motion_ms, lines, img.shape[0],
                                     int(img[:lines].max()), over))
                        except Exception as e:
                            print("capture save failed:", e)
                elif ev == "seq_done":
                    close_board()
        except OSError as e:
            print("xylod conn error (%s) - retry" % e); time.sleep(2)
        finally:
            close_board()   # a dropped link mid-scan must not strand the board or sem 3

def main():
    print("capture agent starting | xylod=%s | capture_dir=%s" % (XYLOD_HOST, CAPTURE_DIR))
    print("frame: %d wide; height per scan = xylod plannedLines (HMI aspect bar), "
          "fallback %d" % (CAM_WIDTH, CAP_LINES))
    apply_startup_defaults()
    print("camera:", read_state())
    threading.Thread(target=cam_server, daemon=True).start()
    threading.Thread(target=live_server, daemon=True).start()
    threading.Thread(target=xylod_client, daemon=True).start()
    print("ready. (Ctrl+C to stop)")
    while True:
        time.sleep(3600)

if __name__ == "__main__":
    main()
