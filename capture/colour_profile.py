"""Fit a viewing colour profile from a merged ColorChecker Classic scan.

usage: python -I colour_profile.py <merged RGB16.tif> <out json>
         --grid x0 y0 x1 y1        chart patch-centre grid, UPRIGHT preview px of the
                                    merged image: top-left patch centre, bottom-right
                                    patch centre (6 columns x 4 rows), at --scale
         --scale S                  preview px per full-res px (default 1.0)
         [--box N]                  sample box half-size at full res (default 120)

Reads the 24 patch means (linear, raw orientation handled here), fits
  rgb_display = M · (gain ∘ rgb_camera) · exposure
against the ColorChecker's published sRGB values in LINEAR sRGB, with the six
neutral patches setting the gains (grey = grey) and all 24 the 3x3 matrix
(rows constrained to preserve grey). Writes the profile the Review Suite's
viewer applies (View > Colour profile): gains, matrix, exposure, and the
before/after error. Nothing in the TIFFs changes.
"""
import json
import sys

import cv2
import numpy as np
import tifffile

# ColorChecker Classic (post-2014), sRGB 8-bit, rows top to bottom
SRGB8 = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
    (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
    (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]
NAMES = ["dark skin", "light skin", "blue sky", "foliage", "blue flower", "bluish green",
         "orange", "purplish blue", "moderate red", "purple", "yellow green", "orange yellow",
         "blue", "green", "red", "yellow", "magenta", "cyan",
         "white", "neutral 8", "neutral 6.5", "neutral 5", "neutral 3.5", "black"]


def srgb_to_lin(c):
    c = np.asarray(c, np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb8(l):
    l = np.clip(l, 0, 1)
    s = np.where(l <= 0.0031308, 12.92 * l, 1.055 * np.power(l, 1 / 2.4) - 0.055)
    return s * 255.0


def opt(name, n=1, default=None):
    if name not in sys.argv:
        return default
    i = sys.argv.index(name)
    v = sys.argv[i + 1:i + 1 + n]
    return [float(x) for x in v] if n > 1 else float(v[0])


src, out = sys.argv[1], sys.argv[2]
grid = opt("--grid", 4)
scale = opt("--scale", default=1.0)
box = int(opt("--box", default=120))
if grid is None:
    sys.exit(__doc__)

m = tifffile.memmap(src)
# Upright like the Suite: rows = lines (scan axis) in the file; rotate 90 CW, flip horizontal.
up = cv2.flip(cv2.rotate(np.ascontiguousarray(m), cv2.ROTATE_90_CLOCKWISE), 1).astype(np.float32)
H, W = up.shape[:2]
x0, y0, x1, y1 = [g / scale for g in grid]
cam = []
for r in range(4):
    for c in range(6):
        cx = x0 + (x1 - x0) * c / 5.0
        cy = y0 + (y1 - y0) * r / 3.0
        ys, xs = int(cy) - box, int(cx) - box
        patch = up[max(0, ys):ys + 2 * box, max(0, xs):xs + 2 * box].reshape(-1, 3)
        cam.append(np.median(patch, axis=0))
cam = np.array(cam) / 65535.0                       # linear camera RGB, 0..1
ref = srgb_to_lin(SRGB8)                           # linear sRGB reference

# Black: the chart's black patch is 3.1% reflectance, not zero; subtract the
# camera's residual pedestal estimated from it.
ped = cam[23] - ref[23] * (cam[18] - cam[23]) / (ref[18] - ref[23])
cam_b = cam - ped

# White balance from the mid neutrals (8, 6.5, 5, 3.5): gains that make them
# grey (green = 1), weighted toward the brighter ones. White is left out (it
# clips in a scan exposed for the scene) and so is black (pedestal-sensitive);
# with those in, the red gain came out 12% short and every grey stayed warm.
neu = cam_b[19:23]
w = ref[19:23, 1]
gain = np.array([np.sum(w * neu[:, 1]) / np.sum(w * neu[:, 0]), 1.0,
                 np.sum(w * neu[:, 1]) / np.sum(w * neu[:, 2])])
wb = cam_b * gain[None, :]
# Exposure from neutral 8, not white: a scan exposed for the scene clips the
# white patch (65520 of 65535 on 2283), and a clipped anchor squashes every
# other grey. Clipped patches are left out of the fit altogether.
exposure = ref[19, 1] / wb[19, 1]
wb *= exposure
ok = np.all(cam < 0.97, axis=1)          # unclipped in every channel
print("patches used in the fit: %d of 24 (clipped: %s)" % (ok.sum(), [NAMES[i] for i in range(24) if not ok[i]]))

# 3x3 matrix. Weighted least squares in linear space, weights ~ 1/sqrt(luminance)
# so dark patches count like a viewer sees them, rows constrained to sum to 1
# (grey stays grey), and a ridge pull toward the identity: an unregularised
# fit drove blue's row to large negative coefficients, which clips and
# amplifies noise for a smaller chart error. The ridge weight is swept and the
# one with the lowest perceptual (sRGB-encoded) error is kept.
def fit_matrix(lam):
    A = wb[ok]; wgt = 1.0 / np.sqrt(np.maximum(ref[ok].mean(axis=1), 0.02))
    Aw = A * wgt[:, None]
    rows = []
    for k in range(3):
        t = ref[ok, k] * wgt
        I = np.eye(3)[k]
        n = 3
        K = np.zeros((n + 1, n + 1)); K[:n, :n] = Aw.T @ Aw + lam * np.eye(n); K[:n, n] = 1; K[n, :n] = 1
        rhs = np.zeros(n + 1); rhs[:n] = Aw.T @ t + lam * I; rhs[n] = 1
        rows.append(np.linalg.solve(K, rhs)[:n])
    return np.array(rows)

def err(a, b):
    d = (lin_to_srgb8(np.clip(a, 0, 1)) - lin_to_srgb8(b))[ok]
    return np.sqrt(np.mean(np.sum(d * d, axis=1)))

best = None
for lam in (0.0, 0.01, 0.03, 0.1, 0.3, 1.0, 3.0):
    Mc = fit_matrix(lam); e = err(wb @ Mc.T, ref)
    print("ridge %-5g -> RMS %.1f   diag %s" % (lam, e, np.round(np.diag(Mc), 2)))
    if best is None or e < best[0]: best = (e, lam, Mc)
e_fit, lam_best, M = best
print("kept ridge %g" % lam_best)
fit = wb @ M.T

e_raw = err(cam / cam[19, 1] * ref[19, 1], ref)
e_wb = err(wb, ref)

print("patch            camera(lin)        after WB+matrix      reference (sRGB8)")
for i in range(24):
    print("%-14s  %3d %3d %3d   ->   %3d %3d %3d     ref %3d %3d %3d" % (
        (NAMES[i],) + tuple(lin_to_srgb8(cam[i] / cam[19, 1] * ref[19, 1]).round().astype(int))
        + tuple(lin_to_srgb8(fit[i]).round().astype(int)) + tuple(SRGB8[i])))
print("\nRMS error in sRGB 8-bit units: raw %.1f  ->  white balance %.1f  ->  WB + matrix %.1f" % (e_raw, e_wb, e_fit))
print("gains R/G/B: %.3f %.3f %.3f   exposure x%.3f   pedestal %s" % (gain[0], gain[1], gain[2], exposure, (ped * 65535).round().astype(int)))
print("matrix:\n", np.round(M, 4))

profile = {
    "source": src, "chart": "ColorChecker Classic", "illuminant": "5600 K",
    "gain": gain.tolist(), "exposure": float(exposure),
    "pedestal": (ped * 65535).tolist(),
    "matrix": M.tolist(),
    "errorRmsSrgb8": {"raw": float(e_raw), "wb": float(e_wb), "fit": float(e_fit)},
}
with open(out, "w") as f:
    json.dump(profile, f, indent=2)
print("wrote", out)
