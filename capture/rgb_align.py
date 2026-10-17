"""Measure and correct the G->R and B->R misregistration of one colour scan.

Imported by rgb_merge.py. Works in raw capture orientation: rows = lines
(scan / time axis, "y"), columns = sensor pixels ("x").

measure(ref, mov): tile phase correlation on edge images (so the different
filter brightness does not matter), sub-pixel. Returns arrays of tile
centres, shifts and responses.
fit(...): robust affine fit dx, dy = a0 + a1*x + a2*y (iterative 3-sigma
rejection; moving people and featureless tiles drop out).
warp(img, model): resample `mov` onto `ref`'s grid.
"""
import cv2
import numpy as np

TILE = 512


def _edges(img):
    f = np.log1p(img.astype(np.float32))
    gx = cv2.Sobel(f, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(f, cv2.CV_32F, 0, 1, ksize=3)
    return cv2.magnitude(gx, gy)


def measure(ref, mov, tile=TILE):
    er, em = _edges(ref), _edges(mov)
    win = cv2.createHanningWindow((tile, tile), cv2.CV_32F)
    pts = []
    H, W = ref.shape
    for y in range(0, H - tile + 1, tile):
        for x in range(0, W - tile + 1, tile):
            a = er[y:y + tile, x:x + tile]
            b = em[y:y + tile, x:x + tile]
            if a.std() < 1e-3 or b.std() < 1e-3:
                continue
            (dx, dy), resp = cv2.phaseCorrelate(a, b, win)
            pts.append((x + tile / 2, y + tile / 2, dx, dy, resp))
    return np.array(pts)


def fit(pts, min_resp=0.08, max_shift=60.0):
    keep = (pts[:, 4] >= min_resp) & (np.abs(pts[:, 2]) < max_shift) & (np.abs(pts[:, 3]) < max_shift)
    p = pts[keep]
    A = np.c_[np.ones(len(p)), p[:, 0], p[:, 1]]
    m = np.ones(len(p), bool)
    for _ in range(5):
        cx, *_ = np.linalg.lstsq(A[m], p[m, 2], rcond=None)
        cy, *_ = np.linalg.lstsq(A[m], p[m, 3], rcond=None)
        rx, ry = p[:, 2] - A @ cx, p[:, 3] - A @ cy
        s = max(0.05, 1.4826 * np.median(np.hypot(rx[m], ry[m])))
        m = np.hypot(rx, ry) < 3 * s
    rms = float(np.sqrt(np.mean(rx[m] ** 2 + ry[m] ** 2)))
    return cx, cy, int(m.sum()), len(pts), rms


def warp(mov, cx, cy):
    # mov(x + dx(x,y), y + dy(x,y)) lands on ref(x, y)
    H, W = mov.shape
    M = np.array([[1 + cx[1], cx[2], cx[0]],
                  [cy[1], 1 + cy[2], cy[0]]], np.float32)
    return cv2.warpAffine(mov.astype(np.float32), M, (W, H),
                          flags=cv2.INTER_CUBIC | cv2.WARP_INVERSE_MAP,
                          borderMode=cv2.BORDER_REPLICATE)


def describe(name, cx, cy, n_ok, n, rms, H, W):
    return (f"{name}: shift x {cx[0]:+.2f} y {cy[0]:+.2f} px | across frame: "
            f"x varies {cx[1]*W:+.2f}/{cx[2]*H:+.2f}, y varies {cy[1]*W:+.2f}/{cy[2]*H:+.2f} px "
            f"(along x / along y) | tiles used {n_ok}/{n}, fit rms {rms:.2f} px")
