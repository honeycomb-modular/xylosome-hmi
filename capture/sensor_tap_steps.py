# Usage: python sensor_tap_steps.py scan_A.tif ...  (files in D:/capture)
# Level step (%) at each 512-column sensor-tap boundary, from narrow linear fits either side.
import struct, sys, re, numpy as np
def tiff(fn):
    f = open(fn, "rb"); f.seek(4); off = struct.unpack("<I", f.read(4))[0]
    f.seek(off); n = struct.unpack("<H", f.read(2))[0]; t = {}
    for _ in range(n):
        tag, typ, cnt, val = struct.unpack("<HHII", f.read(12)); t[tag] = val & 0xFFFF if typ == 3 else val
    return t[256], t[257], t[273]
x = np.arange(8192)
for fn in sys.argv[1:]:
    p = "D:/capture/" + fn; w, h, off = tiff(p)
    hdr = open(p, "rb").read(6000).decode("latin-1")
    meta = {k: (re.search(r'"%s": "?([^",}]+)' % re.escape(k), hdr) or [None, "?"])[1] for k in ("tdi.stages", "gain", "scan.dir")}
    img = np.memmap(p, dtype="<u2", mode="r", offset=off, shape=(h, w))
    step = max(1, h // 3000); acc = np.zeros(w); cnt = 0
    for r0 in range(0, h, 2000):
        blk = np.asarray(img[r0:r0+2000:step]).astype(np.float64)/16
        blk = blk[blk.max(axis=1) < 4000]; acc += blk.sum(0); cnt += len(blk)
    cm = acc/max(cnt, 1); out = []
    for b in range(512, 8192, 512):
        # narrow local fits: only the step survives, scene structure mostly doesn't
        L = slice(b-72, b-8); R = slice(b+8, b+72)
        vl = np.polyval(np.polyfit(x[L], cm[L], 1), b-.5); vr = np.polyval(np.polyfit(x[R], cm[R], 1), b-.5)
        out.append(100*(vr/vl-1))
    print("%-20s %s lines %5d | %s" % (fn, meta, cnt, " ".join("%+5.1f" % v for v in out)))
