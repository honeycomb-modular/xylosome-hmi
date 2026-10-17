"""Brightness of each colour pass of one scan, and the stops between them.

usage: python -I pass_stops.py <dir> <seq>
Reads scan_<seq>_p*_<F>.tif, uses rows that actually hold data (the capture
agent leaves unfilled rows at zero), and reports mean / median / p99 and the
stops of each pass relative to the brightest.
"""
import glob
import math
import os
import sys

import numpy as np
import tifffile

d, seq = sys.argv[1], sys.argv[2]
rows = []
for path in sorted(glob.glob(os.path.join(d, f"scan_{seq}_p*_*.tif"))):
    img = tifffile.imread(path)
    if img.ndim > 2:
        img = img[..., 0]
    filled = img[np.any(img > 0, axis=1)]
    sub = filled[:: max(1, filled.shape[0] // 2000), :: 4].astype(np.float64)
    name = os.path.basename(path)
    rows.append((name, img.shape, filled.shape[0], sub.mean(), np.median(sub),
                 np.percentile(sub, 99), int(img.max())))

best_mean = max(r[3] for r in rows)
best_med = max(r[4] for r in rows)
for name, shape, nfill, mean, med, p99, mx in rows:
    print(f"{name:24s} {shape} filled {nfill:6d}  mean {mean:8.0f}  median {med:8.0f}  "
          f"p99 {p99:8.0f}  max {mx:5d}  | stops vs brightest: mean "
          f"{math.log2(best_mean / max(mean, 1e-9)):+.2f}  median "
          f"{math.log2(best_med / max(med, 1e-9)):+.2f}")
