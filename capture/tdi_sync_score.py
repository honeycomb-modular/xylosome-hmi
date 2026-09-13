# Usage: python tdi_sync_score.py round1.json [round2.json ...]   (outputs of tdi_sync_sweep.py)
# TDI sync score. Each scan is box-resampled along the scan axis onto one common
# angular grid (T lines/deg, below every tested value) so a stretched image is not
# mistaken for a blurred one. Then along-scan detail energy is divided by
# across-sensor detail energy from the SAME image: TDI smear only acts along the
# scan, so the across term cancels scene, focus and exposure.
import json, struct, sys
import numpy as np
T = 140.0
CAP_DIR = "D:/capture/"
def tiff(fn):
    f = open(fn, "rb"); h = f.read(8); off = struct.unpack("<I", h[4:])[0]
    f.seek(off); n = struct.unpack("<H", f.read(2))[0]; t = {}
    for _ in range(n):
        tag, typ, cnt, val = struct.unpack("<HHII", f.read(12))
        t[tag] = val & 0xFFFF if typ == 3 else val
    return t[256], t[257], t[273]
def score(fn, lpd, bands=12):
    w, h, off = tiff(CAP_DIR + fn)
    img = np.memmap(CAP_DIR + fn, dtype="<u2", mode="r", offset=off, shape=(h, w))
    cols = [c for c0 in range(256, w - 256, 512) for c in range(c0, c0 + 48)]
    a = np.asarray(img[:, cols[0]:cols[0] + 1])  # warm
    strips = np.stack([np.asarray(img[:, c0:c0 + 48]) for c0 in range(256, w - 256, 512)], axis=0).astype(np.float64) / 16.0
    # strips: (nstrip, h, 48). Box-resample axis 1 from lpd to T.
    csum = np.concatenate([np.zeros_like(strips[:, :1]), np.cumsum(strips, axis=1)], axis=1)
    nout = int(h * T / lpd) - 1
    edges = np.arange(nout + 1) * lpd / T
    i0 = np.floor(edges).astype(int); fr = edges - i0
    C = csum[:, i0] * (1 - fr)[None, :, None] + csum[:, np.minimum(i0 + 1, h)] * fr[None, :, None]
    r = (C[:, 1:] - C[:, :-1]) / (lpd / T)                       # (nstrip, nout, 48)
    ok = (r > 300) & (r < 4000)                                   # not dark, not clipped
    ga = np.diff(r, axis=1)[:, :, :-1]; va = ok[:, 1:, :-1] & ok[:, :-1, :-1]
    gc = np.diff(r, axis=2)[:, :-1, :];  vc = ok[:, :-1, 1:] & ok[:, :-1, :-1]
    ga2 = np.where(va, ga * ga, 0.0); gc2 = np.where(vc, gc * gc, 0.0)
    tot = ga2.sum() / max(1, va.sum()) / (gc2.sum() / max(1, vc.sum()))
    bs = []
    L = ga2.shape[1] // bands
    for b in range(bands):
        sl = slice(b * L, (b + 1) * L)
        na, nc = va[:, sl].sum(), vc[:, sl].sum()
        bs.append(float("nan") if min(na, nc) < 5000 else (ga2[:, sl].sum() / na) / (gc2[:, sl].sum() / nc))
    return tot, bs, float(ok.mean())
res = []
for path in sys.argv[1:]:
    res += json.load(open(path))
res.sort(key=lambda r: r["lpd"])
print("lpd     file                score   valid  per-band (12 x 12 deg)")
for r in res:
    tot, bs, v = score(r["file"], r["lpd"])
    r["score"] = tot
    print("%-7.1f %-19s %.3f   %3.0f%%   %s" % (r["lpd"], r["file"], tot, 100 * v, " ".join("  -  " if b != b else "%.2f" % b for b in bs)))
