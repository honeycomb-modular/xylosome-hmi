"""Merge one colour scan's R/G/B passes into a colour image.

usage: python -I rgb_merge.py <capture dir> <seq> <out dir> [--align] [--denoise-blue[=K]]
       python -I rgb_merge.py --files R.tif G.tif B.tif --out merged.tif [--jpg] [--align] [--denoise-blue[=K]]

The second form is what the Review Suite calls (Session > Merge R/G/B): explicit
pass files, one output TIFF, no JPEG/preview unless --jpg (the Suite builds its
own proxies). Prints "wrote <path>" on success.

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

--denoise-blue smooths the blue pass's grain: it integrates ~4x longer than
red, so dark-current shot noise makes it visibly grainier (scan 2233: same
~250-count grain as R/G but on a channel half as bright). An edge-preserving
bilateral filter in linear 16-bit, sigma = K x the measured grain (default
K=3; edges above that survive, grain below it is averaged). R and G untouched.
"""
import glob
import os
import re
import sys

import cv2
import numpy as np
import tifffile

argv = sys.argv[1:]
if "--files" in argv:
    i = argv.index("--files")
    files = argv[i + 1:i + 4]
    out_tif = argv[argv.index("--out") + 1] if "--out" in argv else ""
    if len(files) != 3 or not out_tif:
        sys.exit("usage: --files R.tif G.tif B.tif --out merged.tif")
    paths = dict(zip("RGB", files))
    m = re.search(r"scan_(\d+)", os.path.basename(files[0]))
    seq = m.group(1) if m else "merge"
    out = os.path.dirname(os.path.abspath(out_tif))
    want_jpg = "--jpg" in argv
else:
    pos = [a for a in argv if not a.startswith("--")]
    if len(pos) < 3:
        sys.exit(__doc__)
    src, seq, out = pos[0], pos[1], pos[2]
    paths = {}
    for f in "RGB":
        g = glob.glob(os.path.join(src, f"scan_{seq}_p*_{f}.tif"))
        if not g:
            sys.exit(f"missing {f} pass for scan {seq}")
        paths[f] = g[0]
    out_tif = os.path.join(out, f"scan_{seq}_RGB16.tif")
    want_jpg = True
os.makedirs(out, exist_ok=True)

chan = {}
for f in "RGB":
    img = tifffile.imread(paths[f])
    if img.ndim > 2:
        img = img[..., 0]
    chan[f] = img[np.any(img > 0, axis=1)]          # drop unfilled rows
    print(f"{f}: {os.path.basename(paths[f])} -> {chan[f].shape}")

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

# Blue denoise (see the docstring). Grain is measured as the MAD of the
# residual after a 5x5 median, in the middle of the frame.
dn = [a for a in sys.argv if a.startswith("--denoise-blue")]
if dn:
    k = float(dn[0].split("=")[1]) if "=" in dn[0] else 3.0
    bf = b.astype(np.float32)
    H, W = bf.shape
    t = bf[H // 2 - 512:H // 2 + 512, W // 2 - 512:W // 2 + 512]
    res = t - cv2.medianBlur(t, 5)
    mad = 1.4826 * float(np.median(np.abs(res - np.median(res))))
    bf = cv2.bilateralFilter(bf, 9, k * mad, 3.0)
    res2 = bf[H // 2 - 512:H // 2 + 512, W // 2 - 512:W // 2 + 512]
    res2 = res2 - cv2.medianBlur(res2, 5)
    mad2 = 1.4826 * float(np.median(np.abs(res2 - np.median(res2))))
    b = np.clip(bf, 0, 65535).astype(np.uint16)
    print(f"B: denoised, grain {mad:.0f} -> {mad2:.0f} counts (sigma {k:g} x grain)")

rgb16 = np.dstack([r, g, b]).astype(np.uint16)
tmp = out_tif + ".part"
tifffile.imwrite(tmp, rgb16, photometric="rgb")
os.replace(tmp, out_tif)
if not want_jpg:
    print(f"merged {rows} x {cols}")
    print(f"wrote {out_tif}")
    sys.exit(0)

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
print(f"wrote {out_tif}")
