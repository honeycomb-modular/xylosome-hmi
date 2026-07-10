# scan_capture.py - capture agent (image save). Subscribes to xylod :5510,
# grabs a frame per pass via Sapera, and writes a TIFF named the way the Suite
# pairs it: scan_<seq>_p<pass>_<filter>.tif (temp + rename), into CAPTURE_DIR.
#
# NOTE: no external trigger yet -> the camera free-runs; each saved frame is a
# snapshot taken at pass_end, not a motion-synced scan strip. Proves the
# capture -> save -> Suite-display pipeline; real scan frames come with the
# EL2521 EXSYNC trigger later.
#
# Deps:  pip install pythonnet numpy tifffile
# Run:   python "%USERPROFILE%\Desktop\dalsa manuals\scan_capture.py"
#        (CamExpert closed; run the Suite with the SAME CAPTURE_DIR)

import os, sys, json, socket, time, ctypes
import numpy as np
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

SERVER      = "Xtium-CL_MX4_1"
CCF         = SAP + r"\CamFiles\User\HS-80-08K80_Full_8tap_8bit_WORKING.ccf"
XYLOD_HOST  = os.environ.get("XYLOD_HOST", "192.168.2.2")
XYLOD_PORT  = 5510
CAPTURE_DIR = os.environ.get("CAPTURE_DIR", r"D:\capture")
os.makedirs(CAPTURE_DIR, exist_ok=True)


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
        self.ptr = Marshal.AllocHGlobal(self.n * 2)

    def frame(self):
        self.xfer.Snap(1)
        self.xfer.Wait(5000)
        self.buf.Read(0, 0, self.n, self.ptr)
        raw = ctypes.string_at(int(self.ptr.ToInt64()), self.n * 2)
        return np.frombuffer(raw, dtype="<u2").reshape(self.h, self.w)


grab = None
seq = 0
pass_filter = {}   # pass index -> filter (verbatim from xylod, so the Suite's token matches)


def save_frame(seq, p, filt):
    img = grab.frame()
    name = "scan_%04d_p%d_%s.tif" % (seq, p, filt)
    tmp  = os.path.join(CAPTURE_DIR, "." + name + ".part")
    tifffile.imwrite(tmp, img)               # 16-bit grayscale TIFF
    os.replace(tmp, os.path.join(CAPTURE_DIR, name))
    print("saved", name, img.shape)


def main():
    global grab, seq
    grab = Grabber()
    print("grabber ready %dx%d -> capturing to %s" % (grab.w, grab.h, CAPTURE_DIR))
    while True:
        try:
            c = socket.create_connection((XYLOD_HOST, XYLOD_PORT))
            f = c.makefile("r")
            c.sendall(b'{"cmd":"hello","client":"capture"}\n')
            print("connected to xylod at %s:%d" % (XYLOD_HOST, XYLOD_PORT))
            for line in f:
                line = line.strip()
                if not line:
                    continue
                m = json.loads(line)
                ev = m.get("ev")
                if ev == "pass_start":
                    p = int(m.get("pass", -1))
                    filt = m.get("filter", p)
                    if p == 0:
                        seq += 1
                    pass_filter[p] = filt
                    print("pass_start", p, filt, "(seq %d)" % seq)
                elif ev == "pass_end":
                    p = int(m.get("pass", -1))
                    filt = pass_filter.get(p, p)
                    try:
                        save_frame(seq, p, filt)
                    except Exception as e:
                        print("save failed:", e)
        except OSError as e:
            print("xylod connection error (%s) - retrying" % e)
            time.sleep(2)


if __name__ == "__main__":
    main()
