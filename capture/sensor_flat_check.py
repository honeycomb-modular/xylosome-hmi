# Usage: python sensor_flat_check.py scan_A.tif [scan_B.tif]  (files in D:/capture; flat-target scans)
# Level, clipping, falloff, column ripple vs 129-px local trend, dark lines deeper than -1.5%.
import struct, sys, re, os, numpy as np
from numpy.lib.stride_tricks import sliding_window_view as swv
def tiff(fn):
    f = open(fn, "rb"); f.seek(4); off = struct.unpack("<I", f.read(4))[0]
    f.seek(off); n = struct.unpack("<H", f.read(2))[0]; t = {}
    for _ in range(n):
        tag, typ, cnt, val = struct.unpack("<HHII", f.read(12)); t[tag] = val & 0xFFFF if typ == 3 else val
    return t[256], t[257], t[273]
out = {}
for fn in sys.argv[1:]:
    p = "D:/capture/" + fn
    w, h, off = tiff(p)
    hdr = open(p, "rb").read(6000).decode("latin-1")
    meta = {k: (re.search(r'"%s": "?([^",}]+)' % re.escape(k), hdr) or [None, "?"])[1] for k in ("tdi.stages", "gain", "line.rate", "scan.dir")}
    img = np.memmap(p, dtype="<u2", mode="r", offset=off, shape=(h, w))
    sub = np.asarray(img[::4]).astype(np.float32) / 16.0          # 12-bit DN
    sat = (sub >= 4094).mean() * 100
    rowmean = sub.mean(axis=1)
    cm = sub.mean(axis=0)
    pad = np.pad(cm, 64, mode="edge"); trend = np.median(swv(pad, 129), axis=1)
    rel = (cm / trend - 1) * 100
    # row stability: lines along scan of a flat target should be constant
    print("\n%s  %dx%d  %s" % (fn, w, h, meta))
    print("  level: mean %.0f DN (%.0f%% of 4095), col min %.0f max %.0f, saturated px %.3f%%" % (cm.mean(), cm.mean() / 40.95, cm.min(), cm.max(), sat))
    print("  large-scale falloff: centre/edge = %.2f  (mean of cols 0-256 %.0f, 3968-4224 %.0f, 7936-8192 %.0f)" % (
        cm[3968:4224].mean() / ((cm[:256].mean() + cm[-256:].mean()) / 2), cm[:256].mean(), cm[3968:4224].mean(), cm[-256:].mean()))
    print("  row-mean along scan: min %.0f max %.0f std %.1f DN (lighting / motion variation)" % (rowmean.min(), rowmean.max(), rowmean.std()))
    print("  column-scale ripple rms %.2f%%; per 1024-px block: %s" % (rel[64:-64].std(), " ".join("%.2f" % rel[i:i+1024].std() for i in range(0, w, 1024))))
    print("  known spots: 2404-2415 %+.1f%%, around 5115 %+.1f/%+.1f%%, around 6656 %+.1f/%+.1f%%" % (
        rel[2403:2415].mean(), rel[5100:5114].mean(), rel[5115:5130].mean(), rel[6640:6655].mean(), rel[6656:6670].mean()))
    # dips deeper than 1.5%
    dip = rel < -1.5; idx = np.flatnonzero(dip); groups = []
    if idx.size:
        s = idx[0]; prev = idx[0]
        for i in idx[1:]:
            if i > prev + 2: groups.append((s, prev)); s = i
            prev = i
        groups.append((s, prev))
    groups = [(a, b, rel[a:b+1].min()) for a, b in groups if 64 <= a < w - 64]
    groups.sort(key=lambda g: g[2])
    print("  dark lines deeper than -1.5%%: %d; deepest: %s" % (len(groups), ", ".join("%d-%d %.1f%%" % (a+1, b+1, d) for a, b, d in groups[:15])))
    out[fn] = (cm, rel)
np.save(os.path.join(os.path.dirname(__file__), "flat_rel.npy"), np.vstack([v[1] for v in out.values()]))
np.save(os.path.join(os.path.dirname(__file__), "flat_cm.npy"), np.vstack([v[0] for v in out.values()]))
names = list(out)
if len(names) > 1:
    for i in range(len(names)):
        for j in range(i+1, len(names)):
            print("corr %s vs %s: %.2f" % (names[i][:9], names[j][:9], np.corrcoef(out[names[i]][1][64:-64], out[names[j]][1][64:-64])[0, 1]))
