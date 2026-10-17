"""Merge one colour scan's R/G/B passes into a colour image.

usage: python -I rgb_merge.py <capture dir> <seq> <out dir> [--align]

Example: python -I capture/rgb_merge.py D:/capture 2227 D:/merged --align

Each pass becomes its own channel. One shared white point and one gamma for
all three channels, so the image shows the real balance between the passes
(no per-channel stretch). Rows are trimmed to the shortest pass (passes can
differ by a few lines). Writes:
  scan_<seq>_RGB16.tif   full resolution, 16-bit linear
  scan_<seq>_RGB.jpg     full resolution, 8-bit, gamma 2.2, upright + unmirrored
  scan_<seq>_RGB_preview.png  preview, 2048 px on the short side, upright

--align registers G and B onto R (rgb_align.py): slow passes drop lines
evenly (EL2521 frequency step, 2026-10-16), so blue can be ~1% short along
the scan. The 16-bit TIFF stays in raw capture orientation.
"""
import glob
import os
import sys

import cv2
import numpy as np
import tifffile

src, seq, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)

chan = {}
for f in "RGB":
    paths = glob.glob(os.path.join(src, f"scan_{seq}_p*_{f}.tif"))
    if not paths:
        sys.exit(f"missing {f} pass for scan {seq}")
    img = tifffile.imread(paths[0])
    if img.ndim > 2:
        img = img[..., 0]
    chan[f] = img[np.any(img > 0, axis=1)]          # drop unfilled rows
    print(f"{f}: {os.path.basename(paths[0])} -> {chan[f].shape}")

rows = min(c.shape[0] for c in chan.values())
cols = min(c.shape[1] for c in chan.values())

# Destripe: slow passes (the exposure-matched blue) integrate each line for
# longer, so every sensor column's dark current adds its own offset — stripes
# along the scan and a lifted black. Estimate each column's dark offset as its
# 2nd percentile over the whole pass, remove it, and bring every channel's
# black down to the lowest channel's floor (dark current is additive, so this
# is a subtraction, not a gain).
offs = {f: np.percentile(chan[f][:rows, :cols], 2, axis=0) for f in "RGB"}
floor = min(float(np.median(o)) for o in offs.values())
for f in "RGB":
    c = chan[f][:rows, :cols].astype(np.float32) - (offs[f] - floor)[None, :].astype(np.float32)
    chan[f] = np.clip(c, 0, 65535).astype(np.uint16)
    print(f"{f}: column dark offset median {np.median(offs[f]):.0f}, "
          f"spread p5..p95 {np.percentile(offs[f], 5):.0f}..{np.percentile(offs[f], 95):.0f}")

r, g, b = (chan[f] for f in "RGB")

# Registration: green and blue onto red (affine per channel, sub-pixel).
if "--align" in sys.argv:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import rgb_align as align
    H, W = r.shape
    out_ch = []
    for name, mov in (("G", g), ("B", b)):
        pts = align.measure(r, mov)
        cx, cy, n_ok, n, rms = align.fit(pts)
        print(align.describe(f"{name}->R before", cx, cy, n_ok, n, rms, H, W))
        # Too few matching tiles (dark, busy or moving scene) or a loose fit:
        # the "correction" would be noise. Keep the channel as captured.
        if n_ok < max(40, 0.25 * n) or rms > 1.5:
            print(f"{name}->R: alignment unreliable ({n_ok}/{n} tiles, rms {rms:.2f} px) "
                  f"- leaving {name} as captured")
            out_ch.append(mov)
            continue
        warped = np.clip(align.warp(mov, cx, cy), 0, 65535).astype(np.uint16)
        cx2, cy2, n2, nn2, rms2 = align.fit(align.measure(r, warped))
        print(align.describe(f"{name}->R after ", cx2, cy2, n2, nn2, rms2, H, W))
        out_ch.append(warped)
    g, b = out_ch

rgb16 = np.dstack([r, g, b]).astype(np.uint16)
tifffile.imwrite(os.path.join(out, f"scan_{seq}_RGB16.tif"), rgb16, photometric="rgb")

# Shared white point: the 99.5th percentile over all three channels together.
white = float(np.percentile(np.stack([r[::8, ::8], g[::8, ::8], b[::8, ::8]]), 99.5))
lin = np.clip(rgb16.astype(np.float32) / max(white, 1.0), 0.0, 1.0)
img8 = (np.power(lin, 1 / 2.2) * 255.0 + 0.5).astype(np.uint8)
bgr = img8[..., ::-1]                                # OpenCV writes BGR
# Raw capture lies on its side and mirrored: rows are lines (scan axis).
bgr = cv2.flip(cv2.rotate(bgr, cv2.ROTATE_90_CLOCKWISE), 1)
cv2.imwrite(os.path.join(out, f"scan_{seq}_RGB.jpg"), bgr, [cv2.IMWRITE_JPEG_QUALITY, 95])

oh, ow = bgr.shape[:2]
h = 2048
w = int(round(ow * h / oh))
prev = cv2.resize(bgr, (w, h), interpolation=cv2.INTER_AREA)
cv2.imwrite(os.path.join(out, f"scan_{seq}_RGB_preview.png"), prev)
print(f"merged {rows} x {cols}, white point {white:.0f}, preview {w} x {h}")
