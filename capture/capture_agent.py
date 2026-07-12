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
BASE_CCF    = SAP + r"\CamFiles\User\HS-80-08K80_Full_8tap_8bit_WORKING.ccf"
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

STAGES = {16, 32, 48, 64, 80, 96}
def apply_set(key, value):
    if key == "tdi.stages":
        v = int(value)
        if v not in STAGES: return False, "stages 16..96"
        cam_cmd("stg %d" % v); return True, "ok"
    if key == "line.rate":
        v = float(value)
        if not (3500 <= v <= 68610): return False, "3500..68610 Hz"
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

# ---------- board (Sapera) ----------
board_lock = threading.Lock()   # single grabber owner

_ccf_cache = {}
def _ccf_for(lines):
    # Derive a .ccf whose grabber frame height (Crop Height / Scale Vertical) is
    # `lines`. The base .ccf is read-only under Program Files, so write the
    # derived copy to temp. Cached per line count. This is the one place the
    # aspect box will feed once the trigger is wired.
    lines = max(LINE_MIN, min(LINE_MAX, int(lines)))
    cached = _ccf_cache.get(lines)
    if cached and os.path.exists(cached):
        return cached
    with open(BASE_CCF, "r", encoding="latin-1") as fh:
        txt = fh.read()
    txt = re.sub(r"(?m)^Crop Height=.*$",    "Crop Height=%d" % lines, txt)
    txt = re.sub(r"(?m)^Scale Vertical=.*$", "Scale Vertical=%d" % lines, txt)
    out = os.path.join(tempfile.gettempdir(), "xylosome_lines_%d.ccf" % lines)
    with open(out, "w", encoding="latin-1") as fh:
        fh.write(txt)
    _ccf_cache[lines] = out
    return out

class Grabber:
    def __init__(self, lines=CAP_LINES):
        self.loc = SapLocation(SERVER, 0)
        self.acq = SapAcquisition(self.loc, _ccf_for(lines))
        self.buf = SapBuffer(1, self.acq, SapBuffer.MemoryType.ScatterGather)
        self.xfer = SapAcqToBuf(self.acq, self.buf)
        for o in (self.acq, self.buf, self.xfer):
            if not o.Create(): raise RuntimeError("Sapera Create failed: " + o.GetType().Name)
        self.w = int(self.buf.Width); self.h = int(self.buf.Height); self.n = self.w * self.h
        self.ptr = Marshal.AllocHGlobal(self.n * 2)
    def frame(self):
        # allow enough time even for a tall frame at the slowest line rate
        timeout_ms = max(5000, int(self.h / 3500.0 * 1500) + 3000)
        self.xfer.Snap(1); self.xfer.Wait(timeout_ms)
        self.buf.Read(0, 0, self.n, self.ptr)
        raw = ctypes.string_at(int(self.ptr.ToInt64()), self.n * 2)
        return np.frombuffer(raw, dtype="<u2").reshape(self.h, self.w)
    def close(self):
        try: Marshal.FreeHGlobal(self.ptr)
        except Exception: pass
        for o in (self.xfer, self.buf, self.acq):
            try: o.Destroy()
            except Exception: pass

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
                            if not board_lock.acquire(blocking=False):
                                conn.sendall(b'{"ev":"error","text":"board busy (scan running?)"}\n'); continue
                            have = True
                            try: grab = Grabber(lines=LIVE_LINES)
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
            try: img = grab.frame()
            except Exception as e:
                conn.sendall((json.dumps({"ev": "error", "text": "grab: " + str(e)}) + "\n").encode()); break
            # send ALL the (consecutive) lines of the short live frame — a fast,
            # smooth waterfall. Downsample the sensor width + cast in one shot.
            h, w = img.shape
            step = max(1, w // width)
            ds = np.clip(img[:, ::step][:, :width], 0, 255).astype(np.uint8)
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
    while True:
        try:
            c = socket.create_connection((XYLOD_HOST, XYLOD_PORT)); f = c.makefile("r")
            c.sendall(b'{"cmd":"hello","client":"capture"}\n')
            print("xylod connected %s:%d" % (XYLOD_HOST, XYLOD_PORT))
            for line in f:
                line = line.strip()
                if not line: continue
                m = json.loads(line); ev = m.get("ev")
                if ev == "pass_start":
                    p = int(m.get("pass", -1)); filt = m.get("filter", p)
                    pass_filter[p] = filt
                    t_ps = time.monotonic(); ps_time[p] = (t_ps, m.get("tMs"))
                    if p == 0:
                        seq += 1
                        if board_lock.acquire(blocking=False):
                            have = True
                            try: grab = Grabber(); print("CAPTURE seq %d armed" % seq)
                            except Exception as e:
                                print("capture: board open failed:", e); board_lock.release(); have = False; grab = None
                        else:
                            print("capture: board busy (live?), skipping seq %d" % seq); grab = None
                    # FREERUN, GATED TO THE MOTION (no EXSYNC cable yet): grab a
                    # generous frame starting at motion start, then HOLD it until
                    # pass_end and crop to just the sweep — the reset/return after
                    # the axis stops is dropped. Keep line_rate low enough that
                    # 8192 lines (8192/line_rate s) covers the sweep; the crop
                    # trims the rest. Nothing slow may run before the Snap
                    # (settings are read after it). Reverts to EXSYNC when wired.
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
                    if p in pending:
                        img, filt = pending.pop(p)
                        rate = float(scan_settings.get("line.rate") or 0)
                        motion_ms = (pe_tMs - ps_tMs) if (ps_tMs is not None and pe_tMs is not None) else -1
                        want = int(motion_ms / 1000.0 * rate) if (motion_ms > 0 and rate > 0) else img.shape[0]
                        lines = max(1, min(img.shape[0], want))
                        over = " (sweep exceeded frame — lower line rate)" if want > img.shape[0] else ""
                        name = "scan_%04d_p%d_%s.tif" % (seq, p, filt)
                        tmp = os.path.join(CAPTURE_DIR, "." + name + ".part")
                        try:
                            tifffile.imwrite(tmp, img[:lines], metadata={"camera": scan_settings})
                            os.replace(tmp, os.path.join(CAPTURE_DIR, name))
                            print("saved %s | motion %dms -> cropped %d/%d lines%s"
                                  % (name, motion_ms, lines, img.shape[0], over))
                        except Exception as e:
                            print("capture save failed:", e)
                elif ev == "seq_done":
                    if grab: grab.close(); grab = None
                    if have: board_lock.release(); have = False
        except OSError as e:
            print("xylod conn error (%s) - retry" % e); time.sleep(2)
        finally:
            if grab:
                try: grab.close()
                except Exception: pass
                grab = None
            if have:
                try: board_lock.release()
                except Exception: pass
                have = False

def main():
    print("capture agent starting | xylod=%s | capture_dir=%s" % (XYLOD_HOST, CAPTURE_DIR))
    _ar = CAM_WIDTH / float(CAP_LINES)
    print("frame: %d x %d  (aspect %.3f:1%s)  ~%.0f MB/scan"
          % (CAM_WIDTH, CAP_LINES, _ar, " square" if CAP_LINES == CAM_WIDTH else "",
             CAM_WIDTH * CAP_LINES * 2 / 1e6))
    print("camera:", read_state())
    threading.Thread(target=cam_server, daemon=True).start()
    threading.Thread(target=live_server, daemon=True).start()
    threading.Thread(target=xylod_client, daemon=True).start()
    print("ready. (Ctrl+C to stop)")
    while True:
        time.sleep(3600)

if __name__ == "__main__":
    main()
