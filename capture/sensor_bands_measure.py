# Usage: python sensor_bands_measure.py scan_A.tif scan_B.tif ...  (files in D:/capture; writes ./bandprof.npy)
# Sensor-fixed column pattern = the part of the column profile that repeats in
# scans of DIFFERENT scenes. Per scan: mean of every column over all unclipped
# lines, then remove the smooth scene trend (running median, 129 px), leaving
# column-scale structure. Anything real in the sensor correlates across scans.
import struct, sys, numpy as np
from numpy.lib.stride_tricks import sliding_window_view as swv
def tiff(fn):
    f = open(fn, "rb"); f.seek(4); off = struct.unpack("<I", f.read(4))[0]
    f.seek(off); n = struct.unpack("<H", f.read(2))[0]; t = {}
    for _ in range(n):
        tag, typ, cnt, val = struct.unpack("<HHII", f.read(12)); t[tag] = val & 0xFFFF if typ == 3 else val
    return t[256], t[257], t[273], t.get(270)
def desc(fn, off):
    import re
    d = open(fn, "rb").read(4096).decode("latin-1")
    m = re.search(r'"tdi.stages": (\d+).*?"gain": "([-\d.]+)"', d); return m.groups() if m else ("?", "?")
prof = {}
for fn in sys.argv[1:]:
    p = "D:/capture/" + fn
    w, h, off, _ = tiff(p)
    img = np.memmap(p, dtype="<u2", mode="r", offset=off, shape=(h, w))
    step = max(1, h // 4000)
    acc = np.zeros(w); cnt = 0
    for r0 in range(0, h, 2000):
        blk = np.asarray(img[r0:r0 + 2000:step]).astype(np.float64) / 16.0
        blk = blk[blk.max(axis=1) < 4000]
        acc += blk.sum(axis=0); cnt += blk.shape[0]
    cm = acc / max(1, cnt)
    pad = np.pad(cm, 64, mode="edge")
    trend = np.median(swv(pad, 129), axis=1)
    hp = cm - trend
    prof[fn] = (cm, hp)
    st, g = desc(p, off)
    print("%s  stages %s gain %s  lines %d  mean %.0f  column-scale ripple rms %.2f DN (%.2f%%)"
          % (fn, st, g, cnt, cm.mean(), hp.std(), 100 * hp.std() / cm.mean()))
names = list(prof)
print("\ncorrelation of column-scale pattern between scans (1 = identical sensor pattern):")
for i in range(len(names)):
    print("  " + " ".join("%5.2f" % np.corrcoef(prof[names[i]][1], prof[names[j]][1])[0, 1] for j in range(len(names))), names[i][:9])
# where the shared pattern lives: average of normalised hp profiles, 256-px blocks
avg = np.mean([hp / cm.mean() for cm, hp in prof.values()], axis=0) * 100
blocks = [np.sqrt(np.mean(avg[i*256:(i+1)*256]**2)) for i in range(32)]
print("\nshared pattern strength per 256-px block (% rms):")
print("  " + " ".join("%.2f" % b for b in blocks))
steps = np.abs(np.diff(avg))
top = np.argsort(steps)[-12:][::-1]
print("largest column-to-column jumps (col: %):", ", ".join("%d: %+.2f" % (c + 1, avg[c + 1] - avg[c]) for c in sorted(top)))
np.save("./bandprof.npy", np.vstack([p[1] / p[0].mean() for p in prof.values()]))
