"""Denoise a scan pass, non-destructively: the raw TIFF is never touched.

usage: python -I clean_pass.py <pass.tif> [<pass.tif> ...] [--out DIR] [--strength K] [--proof]

Writes <DIR>/<same file name> (default DIR = <capture dir>/cleaned), a 16-bit
TIFF of exactly the raw's size and orientation, so everything that reads a raw
pass (the merge, the Suite's proxies, Photoshop) reads the cleaned one the
same way. Prints "wrote <path>" per file on success.

What it does, and only this: the sensor's grain is smoothed with a non-local
means filter that knows how much noise to expect at every pixel. Nothing is
estimated from the picture - no black level, no column pattern, no tone -
those belong to the camera's own flat-field (settings > calibration) and to
the viewer. Each pass is cleaned on its own, so the colour fringing between
passes (the registration, the artistic signature) is exactly as captured.

The noise model is the Piranha HS 8k at gain 0, 96 TDI stages, measured on
scans 2642 and 2679-2681 (2026-10-30), in counts of the 16-bit file:
  variance = 4 x signal + readnoise^2
  readnoise = 230 counts on sensor columns 0-6143 (raw x); Camera Link tap 4
  (columns 6144-8191) reads noisier and its grain is correlated along the
  row: 416 counts at 6144 rising to 784 at the edge. That tap is what
  shows as "scratchy" shadows on one side of every scan.
A variance-stabilising transform (generalised Anscombe) turns that into unit
white noise, the filter runs with one strength everywhere, and the exact
inverse brings the counts back (bias under one count).

--strength K  filter strength in units of the noise sigma (default 0.6).
              0.45 keeps a little grain, 0.8 is smooth; above 1 wax sets in.
              Measured on scan 2681: K=0.6 takes the shadow grain from 275
              to 59 counts (tap 4: 445 -> 107) and keeps 98% of the
              mid-frequency texture; K=0.8: 29 / 81, 96%.
--proof       also writes <DIR>/<name>_proof.png: two 1:1 crops (the darkest
              flat area and the most detailed one), raw beside cleaned, in
              display orientation, gamma 2.2.
"""
import os
import sys
import time

import cv2
import numpy as np
import tifffile

SHOT_GAIN = 4.0          # variance per count of signal (16-bit counts)
READ_NOISE = 230.0       # counts, sensor columns 0-6143
TAP4_START = 6144        # Camera Link tap 4: cols 6144-8191
TAP4_READ = (416.0, 784.0)   # counts at 6144 ... 8191, linear in between
PATCH, SEARCH = 7, 21    # non-local means windows (px)


def read_noise(ncols):
    """Per-column read-noise sigma (16-bit counts) for a pass ncols wide."""
    x = np.arange(ncols, dtype=np.float32)
    rn = np.full(ncols, READ_NOISE, np.float32)
    t4 = x >= TAP4_START
    if t4.any():
        rn[t4] = np.interp(x[t4], [TAP4_START, max(TAP4_START + 1, ncols - 1)], list(TAP4_READ))
    return rn


def denoise(img, strength):
    """img: uint16 (rows = scan lines, cols = sensor). Returns uint16, same shape."""
    x = img.astype(np.float32)
    b = (read_noise(img.shape[1]) ** 2)[None, :]
    # generalised Anscombe: u has unit variance whatever the signal
    u = 0.5 * np.sqrt(SHOT_GAIN * x + b)
    umin = float(u.min())
    umax = float(0.5 * np.sqrt(SHOT_GAIN * 65535.0 + b.max()))
    scale = float(np.floor(65000.0 / (umax - umin)))     # 16-bit steps per sigma (~180)
    us = np.clip((u - umin) * scale + 0.5, 0, 65535).astype(np.uint16)
    del u
    d = cv2.fastNlMeansDenoising(us, h=[strength * scale], templateWindowSize=PATCH,
                                 searchWindowSize=SEARCH, normType=cv2.NORM_L1)
    del us
    u = d.astype(np.float32) / scale + umin
    # exact algebraic inverse, with the Anscombe bias term (-1/8 in u^2 units)
    x = (4.0 * u * u - b) / SHOT_GAIN - 0.5
    # never above the raw's own full scale (65520 on a 12-bit camera)
    return np.clip(x + 0.5, 0, float(img.max())).astype(np.uint16)


def grain(img, step=8):
    """Shadow grain in counts: MAD of the residual after a 5x5 median over the
    darkest flat quarter of a subsample (a scalar, for the log only)."""
    s = img[::step, ::step].astype(np.float32)
    res = s - cv2.medianBlur(s, 5)
    dark = s < np.percentile(s, 25)
    r = res[dark]
    return 1.4826 * float(np.median(np.abs(r - np.median(r)))) if r.size else 0.0


def proof(raw, out, path):
    """Two 1:1 crops, raw | cleaned, display orientation (transposed), gamma 2.2."""
    H, W = raw.shape
    s = 4
    sub = raw[::s, ::s].astype(np.float32)
    lo, hi = np.percentile(sub, [0.3, 99.7])
    k = 128 // s                                  # the 512-px crop, measured on the subsample
    m = 512 // s                                  # keep clear of the frame edges
    box = cv2.blur(sub, (k, k))
    var = cv2.blur(sub * sub, (k, k)) - box * box
    mid = (box > lo + 0.02 * (hi - lo)) & (box < lo + 0.3 * (hi - lo))   # shadows, not black
    var_d = np.where(mid, var, np.inf)
    var_d[:m, :] = var_d[-m:, :] = var_d[:, :m] = var_d[:, -m:] = np.inf
    y0, x0 = np.unravel_index(np.argmin(var_d), var_d.shape)            # darkest flat
    # most detailed: mid-frequency texture (a 3-px blur minus a 15-px one),
    # so a hard edge or the frame border does not win over real detail
    tex = cv2.blur(np.abs(cv2.blur(sub, (3, 3)) - cv2.blur(sub, (15, 15))), (k, k))
    tex = np.where(box < hi, tex, -np.inf)
    tex[:m, :] = tex[-m:, :] = tex[:, :m] = tex[:, -m:] = -np.inf
    y1, x1 = np.unravel_index(np.argmax(tex), tex.shape)

    def crop(img, cy, cx):
        cy, cx = int(cy) * s, int(cx) * s
        cy = min(max(cy - 256, 0), H - 512); cx = min(max(cx - 256, 0), W - 512)
        c = img[cy:cy + 512, cx:cx + 512].astype(np.float32)
        return (np.clip((c - lo) / (hi - lo), 0, 1) ** (1 / 2.2) * 255).astype(np.uint8).T

    gap = np.full((512, 8), 255, np.uint8)
    rows = [np.concatenate([crop(raw, y, x), gap, crop(out, y, x)], 1) for y, x in ((y0, x0), (y1, x1))]
    cv2.imwrite(path, np.concatenate([rows[0], np.full((8, rows[0].shape[1]), 255, np.uint8), rows[1]], 0))


def main(argv):
    files, out_dir, strength, want_proof = [], "", 0.6, False
    it = iter(argv)
    for a in it:
        if a == "--out":
            out_dir = next(it, "")
        elif a == "--strength":
            strength = float(next(it, "0.6"))
        elif a == "--proof":
            want_proof = True
        elif a.startswith("--"):
            sys.exit(f"unknown option {a}\n\n{__doc__}")
        else:
            files.append(a)
    if not files or not out_dir and out_dir != "":
        sys.exit(__doc__)
    if not 0.1 <= strength <= 2.0:
        sys.exit("--strength must be between 0.1 and 2")
    for src in files:
        src = os.path.abspath(src)
        dst_dir = out_dir or os.path.join(os.path.dirname(src), "cleaned")
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, os.path.basename(src))
        if os.path.abspath(dst) == src:
            sys.exit(f"refusing to overwrite the source: {src}")
        t0 = time.time()
        img = tifffile.imread(src)
        if img.ndim > 2:
            img = img[..., 0]
        if img.dtype != np.uint16:
            sys.exit(f"{os.path.basename(src)}: expected a 16-bit pass, got {img.dtype}")
        out = denoise(img, strength)
        tmp = dst + ".part"
        tifffile.imwrite(tmp, out, metadata={"cleaned": {"source": os.path.basename(src), "strength": strength,
                                                         "model": "piranha-hs-8k-2026-10-30"}})
        os.replace(tmp, dst)
        print(f"{os.path.basename(src)}: grain {grain(img):.0f} -> {grain(out):.0f} counts "
              f"(strength {strength:g}), {img.shape[0]} x {img.shape[1]}, {time.time() - t0:.0f} s")
        if want_proof:
            p = os.path.splitext(dst)[0] + "_proof.png"
            proof(img, out, p)
            print(f"proof {p}")
        print(f"wrote {dst}")


if __name__ == "__main__":
    main(sys.argv[1:])
