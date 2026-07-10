# make_square.py - grab a longer run and build one square image (default 8192^2).
# Free-running (no motion trigger yet), so a static scene repeats down the frame;
# with motion/EXSYNC later, the same capture becomes a real scan strip.
#
# Saves:  <CAPTURE_DIR>\square.tif          (raw 16-bit, what the camera gave)
#         <CAPTURE_DIR>\square_preview.png  (contrast-stretched 8-bit, easy to view)
#
# Deps:  pip install pythonnet numpy tifffile opencv-python
# Run:   python "%USERPROFILE%\Desktop\dalsa manuals\make_square.py"
#        (CamExpert closed; brighten first with set_exposure.ps1 if it's dark)

import os, sys, ctypes
import numpy as np
import tifffile, cv2

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
CAPTURE_DIR = os.environ.get("CAPTURE_DIR", r"D:\capture")
SIZE        = int(os.environ.get("SQUARE", "8192"))   # target square side
os.makedirs(CAPTURE_DIR, exist_ok=True)

loc  = SapLocation(SERVER, 0)
acq  = SapAcquisition(loc, CCF)
buf  = SapBuffer(1, acq, SapBuffer.MemoryType.ScatterGather)
xfer = SapAcqToBuf(acq, buf)
for o in (acq, buf, xfer):
    if not o.Create():
        print("Create failed:", o.GetType().Name); sys.exit(1)

w, h = int(buf.Width), int(buf.Height)
n = w * h
ptr = Marshal.AllocHGlobal(n * 2)
nbuf = (SIZE + h - 1) // h
print("grabbing %d buffers of %dx%d to build %dx%d ..." % (nbuf, w, h, SIZE, SIZE))

rows = []
for i in range(nbuf):
    xfer.Snap(1)
    xfer.Wait(5000)
    buf.Read(0, 0, n, ptr)
    raw = ctypes.string_at(int(ptr.ToInt64()), n * 2)
    rows.append(np.frombuffer(raw, dtype="<u2").reshape(h, w).copy())
    print("  %d/%d" % (i + 1, nbuf))

Marshal.FreeHGlobal(ptr)
xfer.Destroy(); buf.Destroy(); acq.Destroy()

full = np.vstack(rows)[:SIZE, :SIZE]          # SIZE x SIZE, uint16
raw_path     = os.path.join(CAPTURE_DIR, "square.tif")
preview_path = os.path.join(CAPTURE_DIR, "square_preview.png")
tifffile.imwrite(raw_path, full)
disp = cv2.normalize(full, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
cv2.imwrite(preview_path, disp)
print("saved:", raw_path, full.shape, "16-bit  |", preview_path,
      "(min=%d max=%d)" % (int(full.min()), int(full.max())))
