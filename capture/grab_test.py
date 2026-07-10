# grab_test.py - INCREMENT 1 (Python): prove pythonnet can drive Sapera the same
# way PowerShell did - grab real frames, read pixels into numpy, handle Mono16.
# Run:  python "%USERPROFILE%\Desktop\dalsa manuals\grab_test.py"

import os, sys, ctypes
import numpy as np

# Sapera assemblies target .NET Framework -> select that runtime BEFORE import clr
from pythonnet import load
load("netfx")
import clr

SAP = r"C:\Program Files\Teledyne DALSA\Sapera"
os.add_dll_directory(SAP + r"\Bin")                      # native Sapera DLLs
sys.path.append(SAP + r"\Components\NET\Bin")            # managed assembly search path
clr.AddReference("DALSA.SaperaLT.SapClassBasic")

from DALSA.SaperaLT.SapClassBasic import SapLocation, SapAcquisition, SapBuffer, SapAcqToBuf
from System.Runtime.InteropServices import Marshal

SERVER = "Xtium-CL_MX4_1"
CCF    = SAP + r"\CamFiles\User\HS-80-08K80_Full_8tap_8bit_WORKING.ccf"

loc  = SapLocation(SERVER, 0)
acq  = SapAcquisition(loc, CCF)
buf  = SapBuffer(1, acq, SapBuffer.MemoryType.ScatterGather)
xfer = SapAcqToBuf(acq, buf)

for o in (acq, buf, xfer):
    if not o.Create():
        print("Create failed:", o.GetType().Name); sys.exit(1)

w, h = int(buf.Width), int(buf.Height)
print("buffer", w, "x", h, "format", buf.Format)

n = w * h
ptr = Marshal.AllocHGlobal(n * 2)          # Mono16 -> 2 bytes/pixel
try:
    for f in range(8):
        xfer.Snap(1)
        xfer.Wait(5000)
        buf.Read(0, 0, n, ptr)             # count = n ELEMENTS (pixels)
        raw = ctypes.string_at(int(ptr.ToInt64()), n * 2)
        img = np.frombuffer(raw, dtype="<u2").reshape(h, w)   # little-endian uint16

        line16 = img[h // 2]
        line8  = np.clip(line16, 0, 255).astype(np.uint8)     # 8-bit data in 16-bit container
        g = np.diff(line8.astype(np.float32))
        focus = float(np.sqrt(np.mean(g * g)))
        print(f"frame {f}: 16b[min={line16.min()} max={line16.max()}] "
              f"8b[min={line8.min()} max={line8.max()} mean={line8.mean():.1f}] "
              f"focusRMS={focus:.2f}  highByteMax={int((line16 >> 8).max())}")
finally:
    Marshal.FreeHGlobal(ptr)
    xfer.Destroy(); buf.Destroy(); acq.Destroy()
print("done")
