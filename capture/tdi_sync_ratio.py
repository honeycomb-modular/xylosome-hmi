"""TDI sync score at native sampling - the scorer that worked on scenes where
tdi_sync_score.py did not (2026-10-30, 96 stages, dark fence / far trees).

usage: python -I tdi_sync_ratio.py sweep.json [--band 2:14] [--cols 0:2600] [--blur 1.5]

For each scan of a tdi_sync_sweep.py run: in the band of arc (degrees past
the arc start) and the sensor columns given, the mean squared gradient ALONG
the scan divided by the mean squared gradient ACROSS the sensor, after a
small Gaussian blur so the camera's grain does not swamp the picture, on
pixels that are neither dark nor clipped. TDI smear acts along the scan
only, so the ratio is highest where the trigger matches the motion; the
across term cancels the scene, the focus and the exposure. No resampling:
the 10% change in sampling density across a sweep biases the ratio by far
less than the smear does at 48 or 96 stages, and the box resampling of
tdi_sync_score.py beat against periodic subjects (fence slats) and gave
two-humped curves.

Choose the band where the IN-FOCUS subject is, at the depth that matters:
the sync depends on subject distance while the lens pupil is off the
rotation axis. Prints the ratio per scan and a quadratic peak with a
bootstrap interval, plus what that interval means in pixels of smear at the
sweep's stage count.
"""
import json
import sys
import numpy as np
import cv2
import tifffile

CAP = "D:/capture/"
argv = sys.argv[1:]


def opt(name, default):
    return argv[argv.index(name) + 1] if name in argv else default


res = json.load(open(argv[0] if "/" in argv[0] or "\\" in argv[0] else CAP + argv[0]))
res.sort(key=lambda r: r["lpd"])
b0, b1 = (float(v) for v in opt("--band", "2:14").split(":"))
c0, c1 = (int(v) for v in opt("--cols", "0:2600").split(":"))
sigma = float(opt("--blur", "1.5"))


def ratio(blk):
    b = cv2.GaussianBlur(blk, (0, 0), sigma) if sigma > 0 else blk
    ok = (b > 1500) & (b < 60000)
    ga = np.diff(b, axis=0)[:, :-1]
    gc = np.diff(b, axis=1)[:-1, :]
    m = ok[1:, :-1] & ok[:-1, :-1]
    if m.sum() < 10000:
        return float("nan"), float(m.mean())
    return float((ga[m] ** 2).mean() / (gc[m] ** 2).mean()), float(m.mean())


print("lpd     file                ratio   valid   (band %g..%g deg, cols %d..%d, blur %g)" % (b0, b1, c0, c1, sigma))
xs, ys = [], []
stages = None
for r in res:
    lpd = r["lpd"]
    stages = stages or r.get("stages")
    with tifffile.TiffFile(CAP + r["file"]) as t:
        img = t.pages[0].asarray()
    img = img[np.any(img > 0, axis=1)].astype(np.float32)
    blk = img[int(b0 * lpd):int(b1 * lpd), c0:c1]
    q, v = ratio(blk)
    print("%-7.1f %-19s %.3f   %3.0f%%" % (lpd, r["file"], q, 100 * v))
    if q == q:
        xs.append(lpd); ys.append(q)
x, y = np.array(xs), np.array(ys)
if len(x) >= 4:
    sel = y >= 0.85 * y.max()
    if sel.sum() < 4:
        sel = np.argsort(y)[-4:]
    a, b, c = np.polyfit(x[sel], y[sel], 2)
    if a >= 0:
        sys.exit("\nno peak inside the range: the ratio is still %s at the %s end - widen the sweep"
                 % ("rising" if y[-1] > y[0] else "falling", "high" if y[-1] > y[0] else "low"))
    p0 = -b / (2 * a)
    rng = np.random.default_rng(0)
    boots = []
    for _ in range(4000):
        i = rng.integers(0, sel.sum(), sel.sum())
        if len(set(i)) >= 3:
            a2, b2, c2 = np.polyfit(x[sel][i], y[sel][i] + rng.normal(0, 0.008, len(i)), 2)
            if a2 < 0:
                boots.append(-b2 / (2 * a2))
    lo, hi = np.percentile(boots, [16, 84])
    print("\npeak %.2f lines/deg  (68%% %.2f .. %.2f, from %d points)" % (p0, lo, hi, sel.sum()))
    if stages:
        print("at %d stages that interval is +-%.2f px of smear" % (stages, stages * max(hi - p0, p0 - lo) / p0))
    print("-> settings > calibration > tdi.sync: lines/deg = %.1f" % p0)
