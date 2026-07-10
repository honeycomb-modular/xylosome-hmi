# live_agent.py - real live-focus agent (suite/LIVE_PROTOCOL.md), port 5520.
# Replaces suite/tools/fake_capture_agent.py's synthetic scene with real camera
# lines grabbed from the Xtium via Sapera (pythonnet) + numpy.
#
# Camera free-runs on its internal line trigger (exposure mode 7) - no motion,
# no xylod. On live_start it opens the grabber; on live_stop it releases it.
#
# Run:  python "%USERPROFILE%\Desktop\dalsa manuals\live_agent.py"
#   (CamExpert closed; the grabber-config boot task has already exited, board free)

import json, socket, threading, time, os, sys, ctypes
import numpy as np

from pythonnet import load
load("netfx")
import clr

SAP = r"C:\Program Files\Teledyne DALSA\Sapera"
os.add_dll_directory(SAP + r"\Bin")
sys.path.append(SAP + r"\Components\NET\Bin")
clr.AddReference("DALSA.SaperaLT.SapClassBasic")
from DALSA.SaperaLT.SapClassBasic import SapLocation, SapAcquisition, SapBuffer, SapAcqToBuf
from System.Runtime.InteropServices import Marshal

PORT   = 5520
SERVER = "Xtium-CL_MX4_1"
CCF    = SAP + r"\CamFiles\User\HS-80-08K80_Full_8tap_8bit_WORKING.ccf"
LINES_PER_BLOCK = 8

board_lock = threading.Lock()   # single board -> one streaming session at a time


class Grabber:
    def __init__(self):
        self.loc  = SapLocation(SERVER, 0)
        self.acq  = SapAcquisition(self.loc, CCF)
        self.buf  = SapBuffer(1, self.acq, SapBuffer.MemoryType.ScatterGather)
        self.xfer = SapAcqToBuf(self.acq, self.buf)
        for o in (self.acq, self.buf, self.xfer):
            if not o.Create():
                raise RuntimeError("Sapera Create failed: " + o.GetType().Name)
        self.w = int(self.buf.Width)
        self.h = int(self.buf.Height)
        self.n = self.w * self.h
        self.ptr = Marshal.AllocHGlobal(self.n * 2)   # Mono16

    def frame(self):
        self.xfer.Snap(1)
        self.xfer.Wait(5000)
        self.buf.Read(0, 0, self.n, self.ptr)
        raw = ctypes.string_at(int(self.ptr.ToInt64()), self.n * 2)
        return np.frombuffer(raw, dtype="<u2").reshape(self.h, self.w)

    def close(self):
        try: Marshal.FreeHGlobal(self.ptr)
        except Exception: pass
        for o in (self.xfer, self.buf, self.acq):
            try: o.Destroy()
            except Exception: pass


def focus_metric(line8):
    g = np.diff(line8.astype(np.float32))
    return float(np.sqrt(np.mean(g * g)))


def serve(conn, addr):
    conn.sendall((json.dumps({"ev": "welcome", "version": "0.1",
                              "camera": "Piranha 8K", "sim": False}) + "\n").encode())
    rx = b""
    streaming = False
    width, max_hz = 1024, 30.0
    grab = None
    peak = 1e-6
    have_lock = False
    conn.settimeout(0.005)
    t0 = time.monotonic()
    print("client", addr)
    try:
        while True:
            # --- incoming commands ---
            try:
                data = conn.recv(4096)
                if not data:
                    break
                rx += data
                while b"\n" in rx:
                    line, rx = rx.split(b"\n", 1)
                    if not line.strip():
                        continue
                    m = json.loads(line)
                    cmd = m.get("cmd")
                    if cmd == "live_start":
                        width = int(m.get("width", 1024))
                        max_hz = float(m.get("maxHz", 30))
                        if not streaming:
                            if not board_lock.acquire(blocking=False):
                                conn.sendall(b'{"ev":"error","text":"board busy"}\n'); continue
                            have_lock = True
                            try:
                                grab = Grabber()
                            except Exception as e:
                                board_lock.release(); have_lock = False
                                conn.sendall((json.dumps({"ev": "error", "text": str(e)}) + "\n").encode())
                                continue
                            streaming = True; peak = 1e-6; t0 = time.monotonic()
                            print("live_start", addr, "buffer", grab.w, grab.h)
                    elif cmd == "live_stop":
                        if streaming:
                            streaming = False
                            grab.close(); grab = None
                            if have_lock: board_lock.release(); have_lock = False
                        conn.sendall(b'{"ev":"live_stopped"}\n')
                        print("live_stop", addr)
            except socket.timeout:
                pass
            except OSError:
                break

            if not streaming:
                time.sleep(0.03); continue

            # --- grab a frame and stream a block of lines ---
            try:
                img = grab.frame()               # h x w uint16
            except Exception as e:
                conn.sendall((json.dumps({"ev": "error", "text": "grab: " + str(e)}) + "\n").encode())
                break

            h, w = img.shape
            rows = np.linspace(0, h - 1, LINES_PER_BLOCK).astype(int)
            step = max(1, w // width)
            block = bytearray()
            last_focus = 0.0
            for r in rows:
                line8 = np.clip(img[r], 0, 255).astype(np.uint8)   # 8-bit data lives in low byte
                last_focus = focus_metric(line8)                    # focus on FULL-res line
                ds = line8[::step][:width]
                if ds.shape[0] < width:
                    ds = np.pad(ds, (0, width - ds.shape[0]))
                block += ds.tobytes()

            peak = max(peak, last_focus)
            focus_norm = min(1.0, last_focus / peak)
            hdr = json.dumps({"ev": "lines", "count": LINES_PER_BLOCK, "width": width,
                              "bytes": len(block), "focus": round(focus_norm, 4),
                              "tMs": int((time.monotonic() - t0) * 1000)}) + "\n"
            try:
                conn.sendall(hdr.encode() + bytes(block))
            except OSError:
                break
            time.sleep(1.0 / max_hz)
    finally:
        if grab is not None:
            grab.close()
        if have_lock:
            try: board_lock.release()
            except Exception: pass
        conn.close()
        print("client gone", addr)


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT)); srv.listen()
    print(f"live-focus agent on :{PORT}")
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=serve, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
