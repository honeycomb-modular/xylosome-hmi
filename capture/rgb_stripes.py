"""Where do a pass's stripes live: along the scan (time) or across the sensor?

usage: python -I stripes.py <dir> <seq> <lineHz R> <lineHz G> <lineHz B>

Rows of a capture are lines (time), columns are sensor pixels. For each pass:
- row profile (mean of each line), high-passed: line-to-line banding. Its
  strongest periods are reported in lines and, with the pass's line rate, in Hz
  - mains-light flicker shows up at 100/120 Hz (aliased when the line rate is
  below twice that).
- column profile (mean of each sensor pixel), high-passed: fixed pattern
  across the sensor (column stripes), as a % of the mean level.
- dark-floor: the 1st percentile, which rises with dark current on long lines.
"""
import glob
import os
import sys

import numpy as np
import tifffile

d, seq = sys.argv[1], sys.argv[2]
rates = dict(zip("RGB", map(float, sys.argv[3:6])))


def highpass(x, k=51):
    k = min(k, max(3, (len(x) // 2) * 2 - 1))
    ker = np.ones(k) / k
    return x - np.convolve(np.pad(x, k // 2, mode="edge"), ker, mode="valid")


for f in "RGB":
    p = glob.glob(os.path.join(d, f"scan_{seq}_p*_{f}.tif"))[0]
    img = tifffile.imread(p).astype(np.float64)
    img = img[np.any(img > 0, axis=1)]
    lvl = img.mean()
    rows = highpass(img.mean(axis=1))
    cols = highpass(img.mean(axis=0))
    spec = np.abs(np.fft.rfft(rows * np.hanning(len(rows))))
    freq = np.fft.rfftfreq(len(rows), d=1.0)            # cycles per line
    spec[:3] = 0
    top = np.argsort(spec)[-3:][::-1]
    peaks = ", ".join(f"{1/freq[i]:.1f} lines ({freq[i]*rates[f]:.1f} Hz)" for i in top if freq[i] > 0)
    print(f"{f}: level {lvl:7.0f}  line banding rms {rows.std()/lvl*100:5.2f}%  "
          f"column pattern rms {cols.std()/lvl*100:5.2f}%  floor p1 {np.percentile(img[::7, ::7], 1):6.0f}")
    print(f"   strongest line-banding periods: {peaks}")
