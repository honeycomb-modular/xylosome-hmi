"""Merge one colour scan's R/G/B passes into a colour image.

usage: python -I rgb_merge.py <capture dir> <seq> <out dir> [--align] [--denoise-blue[=K]]
       python -I rgb_merge.py --files R.tif G.tif B.tif --out merged.tif [--jpg] [--align] [--denoise-blue[=K]] [--denoise-chroma[=K]]

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

--deband-rows removes line-to-line exposure jitter: every scan line is one
trigger period, and a period that alternates by one EL2521 step (the word
dither at low rates, 0.3% at 470 Hz) or a late trigger shows as a faint
horizontal band once the shadows are lifted. Each row is scaled by the ratio
of its mean to the mean smoothed over its 9 neighbours (clamped to +-3%), per
channel, which is blind to the subject (a row-wide change) and removes only
what differs between a line and its neighbours.

--denoise-chroma smooths the COLOUR DIFFERENCE of all three channels and leaves
luminance alone: the sensor's grain (~190 counts on R and G) then reads as
monochrome grain instead of red/green speckle, and edges keep their
sharpness because luminance is untouched. Edge-preserving (bilateral) on each
chroma plane, threshold K x the measured chroma grain (default K=3).

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

# Line-count match. A slow (exposure-matched) pass drops lines evenly — the
# EL2521 frequency step truncates, so blue came back 1.06% short on scan 2233
# (17835 vs 18026 lines) and its image was compressed along the scan: 25 px
# off at the start of the frame, 175 px at the end. Trimming every pass to the
# shortest hid that. The drop is uniform, so the exact correction is to
# resample each pass along the scan to red's line count; the registration
# below then only has the odd pixel left to find.
rowsR = chan["R"].shape[0]
cols = min(c.shape[1] for c in chan.values())
for f in "GB":
    n = chan[f].shape[0]
    if n != rowsR:
        print(f"{f}: {n} lines -> resampled to red's {rowsR} ({100.0 * (rowsR - n) / n:+.2f}%)")
        chan[f] = cv2.resize(chan[f][:, :cols], (cols, rowsR), interpolation=cv2.INTER_LINEAR)
rows = rowsR

# Destripe: slow passes (the exposure-matched blue) integrate each line for
# longer, so every sensor column's dark current adds its own offset — stripes
# along the scan and a lifted black. Two parts, both additive (subtraction,
# never a gain):
#  · the column PATTERN: each column's offset relative to its neighbours.
#    Estimated as the median over all lines of (pixel - the row's local mean
#    across 31 columns). Scene content is smooth across neighbouring columns
#    and changes along the scan, so the median keeps only the fixed pattern.
#    It used to be each column's 2nd percentile, which needs dark pixels in
#    every column: on a bright wall (scan 2245) that was wall texture, and
#    subtracting it printed the wall's column minima as bands in the merge.
#  · the channel's lifted black: its 2nd percentile, brought down to the
#    lowest channel's floor.
def column_pattern(img):
    sub = img[::max(1, img.shape[0] // 4000)].astype(np.float32)   # ~4000 lines is plenty
    local = cv2.blur(sub, (31, 1))                                   # mean across 31 columns, per row
    return np.median(sub - local, axis=0)

offs = {}
for f in "RGB":
    img = chan[f][:rows, :cols]
    pat = column_pattern(img)
    offs[f] = float(np.percentile(img[::8, ::8], 2))
    print(f"{f}: column pattern p5..p95 {np.percentile(pat, 5):+.0f}..{np.percentile(pat, 95):+.0f} counts, "
          f"black (p2) {offs[f]:.0f}")
    chan[f] = (img.astype(np.float32) - pat[None, :].astype(np.float32), None)
floor = min(offs.values())
for f in "RGB":
    c = chan[f][0] - np.float32(offs[f] - floor)
    chan[f] = np.clip(c, 0, 65535).astype(np.uint16)

r, g, b = (chan[f] for f in "RGB")

if "--deband-rows" in sys.argv:
    outs = []
    for name, c in (("R", r), ("G", g), ("B", b)):
        cf = c.astype(np.float32)
        rm = cf.mean(axis=1)
        sm = cv2.blur(rm.reshape(-1, 1), (1, 9)).ravel()
        gain = np.clip(sm / np.maximum(rm, 1.0), 0.97, 1.03)
        outs.append(np.clip(cf * gain[:, None], 0, 65535).astype(np.uint16))
        print(f"{name}: row banding p5..p95 {100 * (np.percentile(gain, 5) - 1):+.2f}%..{100 * (np.percentile(gain, 95) - 1):+.2f}% removed")
    r, g, b = outs

# Registration: green and blue onto red (affine per channel, sub-pixel).
if "--align" in sys.argv:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import rgb_align as align
    H, W = r.shape
    out_ch = []
    trim = 0          # px: the largest shift applied; the warps' replicated borders are cut off below
    for name, mov in (("G", g), ("B", b)):
        pts = align.measure(r, mov)
        cx, cy, n_ok, n, rms = align.fit(pts)
        print(align.describe(f"{name}->R before", cx, cy, n_ok, n, rms, H, W))
        # The affine needs enough matching tiles spread over the frame (12% of
        # them, at least 12) and a tight fit. A scan with little texture (the
        # chart on a black curtain: 37 of 192 tiles) fails that, but its
        # shift is still a clean constant - the blue sat 4 px off on scan 2283
        # and every edge ghosted - so fall back to the median shift when the
        # reliable tiles agree within a pixel or two.
        if n_ok < max(12, 0.12 * n) or rms > 3.0:
            good = pts[pts[:, 4] >= 0.08]
            if len(good) >= 8:
                dx, dy = np.median(good[:, 2]), np.median(good[:, 3])
                sx = np.subtract(*np.percentile(good[:, 2], [75, 25]))
                sy = np.subtract(*np.percentile(good[:, 3], [75, 25]))
                if sx < 2.5 and sy < 2.5:
                    print(f"{name}->R: affine unreliable ({n_ok}/{n} tiles, rms {rms:.2f} px) - "
                          f"constant shift x {dx:+.2f} y {dy:+.2f} px from {len(good)} tiles "
                          f"(IQR {sx:.1f}/{sy:.1f})")
                    cx = np.array([dx, 0.0, 0.0]); cy = np.array([dy, 0.0, 0.0])
                    trim = max(trim, abs(dx), abs(dy))
                    warped = np.clip(align.warp(mov, cx, cy), 0, 65535).astype(np.uint16)
                    cx2, cy2, n2, nn2, rms2 = align.fit(align.measure(r, warped))
                    print(align.describe(f"{name}->R after ", cx2, cy2, n2, nn2, rms2, H, W))
                    out_ch.append(warped)
                    continue
            print(f"{name}->R: alignment unreliable ({n_ok}/{n} tiles, rms {rms:.2f} px) "
                  f"- leaving {name} as captured")
            out_ch.append(mov)
            continue
        trim = max(trim, abs(cx[0]) + abs(cx[1]) * W + abs(cx[2]) * H, abs(cy[0]) + abs(cy[1]) * W + abs(cy[2]) * H)
        warped = np.clip(align.warp(mov, cx, cy), 0, 65535).astype(np.uint16)
        cx2, cy2, n2, nn2, rms2 = align.fit(align.measure(r, warped))
        print(align.describe(f"{name}->R after ", cx2, cy2, n2, nn2, rms2, H, W))
        # One refinement by a CONSTANT shift, the median over the reliable
        # tiles: the first fit is measured on tiles several px off and leaves
        # ~1 px; re-fitting a whole affine on a sparse scene (30-40 tiles)
        # just chases its own noise, the median does not.
        pts2 = align.measure(r, warped)
        good2 = pts2[pts2[:, 4] >= 0.08]
        if len(good2) >= 8:
            dx2, dy2 = float(np.median(good2[:, 2])), float(np.median(good2[:, 3]))
            if max(abs(dx2), abs(dy2)) > 0.3:
                trim = max(trim, abs(dx2), abs(dy2))
                warped = np.clip(align.warp(warped, np.array([dx2, 0.0, 0.0]), np.array([dy2, 0.0, 0.0])),
                                 0, 65535).astype(np.uint16)
                pts3 = align.measure(r, warped); good3 = pts3[pts3[:, 4] >= 0.08]
                print(f"{name}->R refine: median shift x {dx2:+.2f} y {dy2:+.2f} px applied; "
                      f"residual median x {np.median(good3[:, 2]):+.2f} y {np.median(good3[:, 3]):+.2f} px "
                      f"over {len(good3)} tiles")
        out_ch.append(warped)
    g, b = out_ch
    # Cut the replicated borders the warps left (a shifted channel has no data
    # for its first rows/columns): the same margin on all three channels.
    t = int(np.ceil(trim)) + 1
    if trim > 0 and 2 * t < min(r.shape):
        r, g, b = (c[t:-t, t:-t] for c in (r, g, b))
        rows, cols = r.shape
        print(f"edges trimmed by {t} px for the registration shifts -> {rows} x {cols}")

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

# Chroma denoise (see the docstring): Y from the three channels, each
# channel's difference to Y smoothed with an edge-preserving filter, Y kept.
dc = [a for a in sys.argv if a.startswith("--denoise-chroma")]
if dc:
    k = float(dc[0].split("=")[1]) if "=" in dc[0] else 3.0
    rf, gf, bf = (c.astype(np.float32) for c in (r, g, b))
    Y = 0.3 * rf + 0.5 * gf + 0.2 * bf
    outs = []
    Hh, Ww = Y.shape
    for name, cf in (("R", rf), ("G", gf), ("B", bf)):
        d = cf - Y
        t = d[Hh // 2 - 512:Hh // 2 + 512, Ww // 2 - 512:Ww // 2 + 512]
        res = t - cv2.medianBlur(t, 5)
        mad = 1.4826 * float(np.median(np.abs(res - np.median(res))))
        d = cv2.bilateralFilter(d, 9, k * max(mad, 1.0), 4.0)
        outs.append(np.clip(Y + d, 0, 65535).astype(np.uint16))
        print(f"{name}: chroma grain {mad:.0f} counts smoothed (sigma {k:g} x)")
    r, g, b = outs

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
