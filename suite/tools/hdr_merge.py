#!/usr/bin/env python3
# hdr_merge.py - reconstruct one HDR image from a bracket set of line scans.
#
# The brackets differ only in line rate: xylod runs the same arc slower, so each
# line integrates longer. Same arc, one stop per halving. What that leaves for
# the merge:
#
#   * Line counts differ by a few (height = EXSYNC pulses actually delivered).
#     Same arc over a different number of lines is a STRETCH, not an offset:
#     measured on 0787/0788/0789 the brackets drift ~2 lines top to bottom,
#     exactly the difference in their line counts. An integer shift cannot fix
#     it, so each bracket is resampled onto the reference's line grid - and the
#     drift is not smooth either, so it is measured densely, not modelled.
#   * A black pedestal that does NOT scale with exposure, ~1550 counts.
#   * Saturation at 65520, not 65535 (12-bit data left-justified into uint16).
#
# Merge rule: for each pixel sum the pedestal-corrected counts of every bracket
# that is not clipped, and divide by the total exposure those brackets
# represent. For photon-limited data that is the maximum-likelihood estimate; it
# needs no weighting function and clipped samples simply do not participate.
#
#   python hdr_merge.py 0787 0788 0789
#   python hdr_merge.py 0787 0788 0789 --out D:\hdr-merge

import argparse, json, os, re, sys
import numpy as np
import tifffile

SAT = 65520          # 4095 << 4: full scale for 12-bit left-justified data
SAT_GUARD = 64000    # stay off the shoulder, where response goes non-linear
# A pixel used to be in or out at SAT_GUARD. That hard switch is what made a
# merge look scruffy: the brackets disagree by a few percent, so wherever the
# count of contributing brackets changed the estimate stepped by that much - and
# because the threshold is crossed pixel by pixel through noise, the boundary is
# speckled rather than clean. Fading the contribution out instead spreads that
# step over a range of brightness, where it is invisible.
SOFT_LO = 52000      # full weight below this
SOFT_HI = SAT_GUARD  # zero weight above this
CHUNK = 2048         # output rows per pass over the files
T = 1024             # probe tile size for the exposure and black-level fits

def load_set(paths):
    out = []
    for p in paths:
        tf = tifffile.TiffFile(p)
        desc = tf.pages[0].tags.get("ImageDescription")
        rate = None
        if desc:
            try:
                rate = float(json.loads(desc.value)["camera"]["line.rate"])
            except Exception:
                pass
        tf.close()
        if rate is None:
            sys.exit(f"{p}: no line.rate in ImageDescription - cannot know exposure")
        a = tifffile.memmap(p, mode="r")
        out.append({"path": p, "name": os.path.basename(p), "arr": a, "rate": rate,
                    "t": 1.0 / rate, "h": a.shape[0], "w": a.shape[1]})
    return out


# Alignment is MEASURED DENSELY, not modelled. One quadratic for the whole sweep
# used to describe it, fitted on 11 tiles between 10% and 90% of the height and
# checked on 3. On 1833-1836 that left +/-2 px wobble through the body and 25 to
# 100 px at the start of the sweep, where the fastest pass does not space its
# first ~3000 lines like the slower ones - none of which 3 centre tiles can see.
# Offsets are now measured every BAND rows at COLS places across the line and
# interpolated between, so the geometry is whatever the brackets actually did.
N = 512              # registration tile
BAND = 256           # rows between registration bands
COLS = 9             # tiles per band across the line
MIN_NCC = 0.5        # below this a tile has not really matched anything
# Lanczos-3 resampling. Every bracket but the reference is resampled, and linear
# interpolation - what this used to do - keeps only 0.82 of the contrast at a
# 4-pixel period and 0.51 at Nyquist on average over sub-pixel positions.
# Lanczos-3 keeps 1.0 and 0.65.
LZ = 3


def _pair(a, b, ta, tb):
    """Two tiles on a common radiance scale, clipped wherever EITHER one clips:
    a highlight blown in the brighter bracket must be flat in both, or the
    correlation locks onto the edge of the clipping instead of the scene."""
    a = a.astype(np.float32) / ta
    b = b.astype(np.float32) / tb
    hi = min(SAT_GUARD / ta, SAT_GUARD / tb)
    return np.minimum(a, hi), np.minimum(b, hi)


_WIN = np.outer(np.hanning(N), np.hanning(N)).astype(np.float32)
_FQ = np.hypot(np.fft.fftfreq(N)[:, None], np.fft.fftfreq(N)[None, :])
_LP = np.exp(-_FQ ** 2 / (2 * 0.18 ** 2)).astype(np.float32)


def xcorr(a, b):
    """Sub-pixel (dy, dx, ncc) such that b row i holds a row i+dy, b column j
    holds a column j+dx. Partly whitened phase correlation: plain correlation is
    dominated by the broad tones, full phase correlation by the noise."""
    n = N
    X = np.fft.fft2((a - a.mean()) * _WIN) * np.conj(np.fft.fft2((b - b.mean()) * _WIN))
    c = np.real(np.fft.ifft2(X / (np.abs(X) ** 0.6 + 1e-6) * _LP))
    ky, kx = np.unravel_index(int(np.argmax(c)), c.shape)

    def sub(m0, m1, m2, k):
        d = m0 - 2 * m1 + m2
        v = k + (0.5 * (m0 - m2) / d if abs(d) > 1e-12 else 0.0)
        return v - n if v > n / 2 else v
    dy = sub(c[(ky - 1) % n, kx], c[ky, kx], c[(ky + 1) % n, kx], ky)
    dx = sub(c[ky, (kx - 1) % n], c[ky, kx], c[ky, (kx + 1) % n], kx)
    iy, ix = int(round(dy)), int(round(dx))
    A = a[max(0, iy):n + min(0, iy), max(0, ix):n + min(0, ix)]
    B = b[max(0, -iy):n + min(0, -iy), max(0, -ix):n + min(0, -ix)]
    A = A - A.mean(); B = B - B.mean()
    ncc = float((A * B).mean() / (A.std() * B.std() + 1e-9))
    return dy, dx, ncc


class Warp:
    """Where reference pixel (y, x) lies in one bracket:

        row = y - dy(y) - tilt(y) * (x - xc)
        col = x - dx(y)

    dy, tilt and dx are measured per band and interpolated between bands. The
    tilt is real: the fastest bracket of 1833-1836 sits 2 px further along the
    sweep at one end of the line than at the other."""

    def __init__(self, yk, dy, tilt, dx, xc, lo, hi):
        self.yk, self.dy, self.tilt, self.dx = yk, dy, tilt, dx
        self.xc, self.lo, self.hi = xc, lo, hi
        self.identity = not (np.any(dy) or np.any(tilt) or np.any(dx))

    def row(self, y, x=None):
        y = np.asarray(y, np.float64)
        r = y - np.interp(y, self.yk, self.dy)
        if x is not None:
            r = r - np.interp(y, self.yk, self.tilt) * (np.asarray(x, np.float64) - self.xc)
        return r

    def col(self, y):
        """Column shift: source column = x + col(y)."""
        return -np.interp(np.asarray(y, np.float64), self.yk, self.dx)


def _band_line(xs, v):
    """a + tilt*(x - xc) through one band, after dropping tiles that matched
    something else - a car that moved between passes, a repeating texture."""
    med = np.median(v)
    mad = float(np.median(np.abs(v - med)))
    keep = np.abs(v - med) < max(3.0 * mad, 1.5)
    if int(keep.sum()) < 4:
        return float(np.median(v[keep])) if keep.any() else float(med), 0.0
    t, a = np.polyfit(xs[keep], v[keep], 1)
    return float(a), float(t)


def _despike(v, r=2, floor=1.5):
    """A band whose value disagrees with its neighbours' median is replaced by
    it. The median of a straight run is its centre, so a real steep drift - the
    start of the fastest pass moves ~10 px per band - survives."""
    out = v.copy()
    for i in range(len(v)):
        nb = v[max(0, i - r):i + r + 1]
        med = np.median(nb)
        mad = float(np.median(np.abs(nb - med)))
        if abs(v[i] - med) > max(3.0 * mad, floor):
            out[i] = med
    return out


def fit_warp(ref, b):
    """Dense alignment of bracket `b` onto the reference grid.

    Bands are walked outwards from the middle, each starting from its
    neighbour's answer, so a drift of 100 px accumulates as a series of small
    steps a 512 px tile can always see. Only the seed band needs a wide search,
    done on a 4x binned region."""
    H = min(ref["h"], b["h"]); W = min(ref["w"], b["w"])
    xs = np.array([int(v) for v in np.linspace(0, W - N, COLS)])
    xc = W / 2.0
    ys = list(range(0, H - N, BAND))
    mid = len(ys) // 2

    seeds = []
    y = min(max(0, ys[mid] + N // 2 - 1024), H - 2048)
    for x in xs[2:-2]:
        x = int(min(max(0, x + N // 2 - 1024), W - 2048))
        A = np.asarray(ref["arr"][y:y+2048, x:x+2048], np.float32).reshape(512, 4, 512, 4).mean((1, 3))
        B = np.asarray(b["arr"][y:y+2048, x:x+2048], np.float32).reshape(512, 4, 512, 4).mean((1, 3))
        d = xcorr(*_pair(A, B, ref["t"], b["t"]))
        if d[2] > MIN_NCC:
            seeds.append((4 * d[0], 4 * d[1]))
    seed = np.median(np.array(seeds), axis=0) if seeds else np.zeros(2)

    centre = np.full(len(ys), np.nan)
    band = np.full((len(ys), 3), np.nan)            # dy, tilt, dx
    for order in (range(mid, len(ys)), range(mid - 1, -1, -1)):
        p = seed if order.start == mid else band[mid, [0, 2]]
        if not np.all(np.isfinite(p)):
            p = seed
        for i in order:
            y = ys[i]
            # A tile whose partner would start above row 0 is pushed down, not
            # dropped: the start of the sweep is exactly where it is needed.
            y = min(y + max(0, int(np.ceil(p[0])) - y), H - N - 1)
            vy, vx, used = [], [], []
            for x in xs:
                sy = int(round(y - p[0])); sx = int(round(x - p[1]))
                if sy < 0 or sy + N > b["h"] or sx < 0 or sx + N > b["w"]:
                    continue
                A = np.asarray(ref["arr"][y:y+N, x:x+N])
                B = np.asarray(b["arr"][sy:sy+N, sx:sx+N])
                if float(((A < SAT_GUARD) & (B < SAT_GUARD)).mean()) < 0.3:
                    continue
                dy, dx, ncc = xcorr(*_pair(A, B, ref["t"], b["t"]))
                if ncc < MIN_NCC or abs(dy) > N / 8 or abs(dx) > N / 8:
                    continue
                vy.append(y - sy + dy); vx.append(x - sx + dx); used.append(x + N / 2 - xc)
            if len(vy) < 2:
                continue
            u = np.array(used)
            a, t = _band_line(u, np.array(vy))
            c, _ = _band_line(u, np.array(vx))
            band[i] = (a, t, c)
            centre[i] = y + N / 2
            p = np.array([a, c])

    ok = np.isfinite(centre)
    if int(ok.sum()) < 3:
        sys.exit(f"{b['name']}: could not measure alignment - too few matching bands")
    yk = centre[ok]
    o = np.argsort(yk)
    yk = yk[o]
    dy = _despike(band[ok, 0][o])
    dx = _despike(band[ok, 2][o])
    # A band's tilt rests on 9 tiles across 8000 px and is noisy; the tilt
    # itself changes slowly, so it is smoothed hard.
    tl = band[ok, 1][o]
    tilt = np.array([np.median(tl[max(0, i - 4):i + 5]) for i in range(len(tl))])
    return Warp(yk, dy, tilt, dx, xc, yk[0] - N / 2, yk[-1] + N / 2), int(ok.sum()), len(ys)


def fit_geometry(bs, ref):
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    geo = []
    print("\ngeometry (reference %s, measured every %d rows):" % (bs[ref]["name"], BAND))
    for i, b in enumerate(bs):
        if i == ref:
            geo.append(Warp(np.array([0.0, float(H)]), np.zeros(2), np.zeros(2),
                            np.zeros(2), W / 2.0, 0.0, float(bs[ref]["h"])))
            print(f"  {b['name']}: reference"); continue
        g, used, total = fit_warp(bs[ref], b)
        geo.append(g)
        q = lambda v: f"{v[0]:+.1f} at the top .. {v[len(v)//2]:+.1f} mid .. {v[-1]:+.1f} at the bottom"
        print(f"  {b['name']}: {used}/{total} bands matched, rows {g.lo:.0f}..{g.hi:.0f} covered")
        print(f"      sweep offset {q(-g.dy)} px   (range {np.ptp(g.dy):.1f})")
        print(f"      line offset  {q(-g.dx)} px;  tilt up to "
              f"{np.max(np.abs(g.tilt)) * W:.1f} px across the line")
    return geo, W


def _lanczos(t):
    """Weights for taps at offsets -LZ+1..LZ from floor(position), t = fraction.
    Normalised so a flat field stays flat."""
    ws = []
    for k in range(-LZ + 1, LZ + 1):
        x = np.float32(k) - t
        ws.append(np.sinc(x) * np.sinc(x / LZ))
    s = sum(ws)
    return [w / s for w in ws]


def resample(arr, g, rows, x0, w):
    """Values of one bracket at reference rows `rows` and reference columns
    x0..x0+w, Lanczos-3, rows then columns. Also returns the brightest raw
    sample under the kernel: a value built partly from a clipped sample is not
    trustworthy even when the result itself lands below the clip."""
    rows = np.asarray(rows, np.float64)
    if g.identity:
        v = np.asarray(arr[int(rows[0]):int(rows[-1]) + 1, x0:x0 + w], np.float32)
        return v, v
    dc = g.col(rows)
    j0 = int(np.floor(x0 + dc.min())) - LZ + 1
    j1 = int(np.floor(x0 + w - 1 + dc.max())) + LZ + 1
    js = np.arange(j0, j1, dtype=np.float64)
    sr = g.row(rows[:, None], js[None, :] - float(np.mean(dc)))
    i0 = np.floor(sr).astype(np.int64)
    lo, hi = int(i0.min()) - LZ + 1, int(i0.max()) + LZ + 1
    if lo < 0 or hi > arr.shape[0] or j0 < 0 or j1 > arr.shape[1]:
        sys.exit(f"resample: source rows {lo}..{hi} cols {j0}..{j1} outside the scan - "
                 f"geometry is wrong")
    slab = np.asarray(arr[lo:hi, j0:j1], np.float32)
    wr = _lanczos((sr - i0).astype(np.float32))
    V = np.zeros(sr.shape, np.float32); Vp = np.zeros(sr.shape, np.float32)
    # The peak is taken over the two NEAREST taps per axis only (the 2x2 that
    # carry ~90% of the kernel), not all 36. Sun glints in road aggregate are
    # single saturated pixels, and judging a sample by its outer lobes threw
    # away every bracket within 3 px of each one - on 1863-1866 that left the
    # sunlit pavement to the fastest bracket alone, at 20x the wrong radiance
    # (a shadow had moved), as hard-edged dark blocks. An outer lobe's share
    # of a clipped neighbour is a percent or two; a wrong bracket is not.
    for k, wk in zip(range(-LZ + 1, LZ + 1), wr):
        s = np.take_along_axis(slab, i0 - lo + k, axis=0)
        V += wk * s
        if k in (0, 1):
            np.maximum(Vp, s, out=Vp)
    del wr, sr
    xs = x0 + dc                                   # source column of output column 0, per row
    ic = np.floor(xs).astype(np.int64)
    wc = _lanczos((xs - ic).astype(np.float32)[:, None])
    base = (ic - j0)[:, None] + np.arange(w)[None, :]
    out = np.zeros((len(rows), w), np.float32); peak = np.zeros((len(rows), w), np.float32)
    for k, wk in zip(range(-LZ + 1, LZ + 1), wc):
        idx = base + k
        out += wk * np.take_along_axis(V, idx, axis=1)
        if k in (0, 1):
            np.maximum(peak, np.take_along_axis(Vp, idx, axis=1), out=peak)
    return out, peak


def verify_fit(bs, geo, ref):
    """Resample tiles through the fitted geometry, with the merge's own
    resampler, and measure what is left. Tiles sit BETWEEN the bands the fit
    was measured on, so this is out of sample, and a model applied the wrong
    way round doubles the offset instead of hiding it."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    print("\nverify (residual after resampling, out of sample, want ~0):")
    worst = 0.0
    for i, (b, g) in enumerate(zip(bs, geo)):
        if i == ref:
            continue
        lo, hi = int(max(g.lo, 0)) + BAND // 2, int(min(g.hi, H)) - N
        res = []
        for y in range(lo, hi, BAND * 3):
            for x in np.linspace(N, W - 2 * N, 5).astype(int):
                r = g.row([y, y + N - 1]); c = x + g.col([y, y + N - 1])
                if r.min() < LZ or r.max() > b["h"] - LZ - 2 or c.min() < LZ or c.max() + N > b["w"] - LZ - 2:
                    continue
                A = np.asarray(bs[ref]["arr"][y:y+N, x:x+N])
                B, Bp = resample(b["arr"], g, np.arange(y, y + N), int(x), N)
                if float(((A < SAT_GUARD) & (Bp < SAT_GUARD)).mean()) < 0.3:
                    continue
                dy, dx, ncc = xcorr(*_pair(A, B, bs[ref]["t"], b["t"]))
                if ncc >= MIN_NCC and abs(dy) < N / 8 and abs(dx) < N / 8:
                    res.append((dy, dx))
        if not res:
            print(f"  {b['name']}: nothing to measure"); continue
        r = np.abs(np.array(res))
        p95 = np.percentile(r, 95, axis=0)
        worst = max(worst, float(p95.max()))
        print(f"  {b['name']}: {len(r)} tiles  rows p50 {np.median(r[:,0]):.2f} p95 {p95[0]:.2f}"
              f"  |  cols p50 {np.median(r[:,1]):.2f} p95 {p95[1]:.2f} px")
    if worst > 0.5:
        print(f"  [WARN] 5% of tiles are still >{worst:.1f} px off - expect soft or doubled "
              f"detail there (moving subject, or geometry the bands cannot follow)")
    else:
        print(f"  -> aligned: 95% of tiles within {worst:.2f} px")
    return worst


def fit_response(bs, geo):
    """Measure each bracket's exposure RELATIVE to the fastest, from the images.

    The obvious ratio is 1/line.rate, and for most sets it is right. But under
    EXSYNC the camera's line.rate is only its readout setting - the EL2521's
    trigger does the pacing - so the two can disagree, and on 0814-0816 they did
    badly enough to leave the brackets 54% apart on radiance. For a linear
    sensor a pair satisfies  b = r*a + P*(1-r), so a straight line through the
    pair gives BOTH the true ratio and the pedestal. Fitted on binned medians so
    a few misregistered edges cannot drag it.

    Returns (relative exposures, P). Exposures are chained from the fastest."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    print("\nresponse fit (exposure ratio measured from the images):")
    te = [1.0]
    ps = []
    for i in range(len(bs) - 1):
        f, s = bs[i], bs[i + 1]
        av, bv = [], []
        for frac in (0.20, 0.35, 0.50, 0.65, 0.80):
            y = int(H * frac) - T // 2
            x = W // 2 - T // 2
            fy = int(round(float(geo[i].row(y))))
            sy = int(round(float(geo[i + 1].row(y))))
            fx = x + int(round(float(geo[i].col(y))))
            sx = x + int(round(float(geo[i + 1].col(y))))
            a = f["arr"][fy:fy+T, fx:fx+T].astype(np.float32)[::3, ::3]
            b = s["arr"][sy:sy+T, sx:sx+T].astype(np.float32)[::3, ::3]
            m = (a < SOFT_LO) & (b < SOFT_LO)      # linear region of BOTH
            if m.sum() > 2000:
                av.append(a[m]); bv.append(b[m])
        if not av:
            print(f"  {f['name']} -> {s['name']}: no linear overlap, using line.rate")
            te.append(te[-1] * (s["t"] / f["t"]))
            continue
        a = np.concatenate(av); b = np.concatenate(bv)
        # binned medians, so bright detail does not dominate the line
        lo, hi = np.percentile(a, 2), np.percentile(a, 98)
        edges = np.linspace(lo, hi, 21)
        xs, ys = [], []
        for j in range(len(edges) - 1):
            m = (a >= edges[j]) & (a < edges[j + 1])
            if int(m.sum()) > 200:
                xs.append(np.median(a[m])); ys.append(np.median(b[m]))
        if len(xs) < 4:
            print(f"  {f['name']} -> {s['name']}: too few bins, using line.rate")
            te.append(te[-1] * (s["t"] / f["t"]))
            continue
        m_, c_ = (float(v) for v in np.polyfit(np.array(xs), np.array(ys), 1))
        nominal = s["t"] / f["t"]
        te.append(te[-1] * m_)
        if abs(1.0 - m_) > 1e-6:
            ps.append(c_ / (1.0 - m_))
        flag = "" if abs(m_ / nominal - 1) < 0.05 else "   <- line.rate disagrees"
        print(f"  {f['name']} -> {s['name']}: measured x{m_:.3f} "
              f"({np.log2(m_):+.2f} stop), line.rate said x{nominal:.3f} "
              f"({np.log2(nominal):+.2f}){flag}")
    P = float(np.median(ps)) if ps else 0.0
    print(f"  relative exposures: " + ", ".join(f"{b['name'][5:9]}={t:.3f}"
                                                for b, t in zip(bs, te)))
    print(f"  black level from the same fit: P = {P:.0f}")
    return te, P


def load_flat(path, P0):
    """Per-column GAIN from a flat-field scan: one sweep of an evenly lit,
    featureless, defocused surface filling the frame.

    Why it cannot be derived from ordinary scans: the sweep pans horizontally,
    so a feature's VERTICAL position lands on the same sensor columns in every
    scan ever taken. Scene structure and sensor structure are therefore
    perfectly confounded along this axis - no amount of averaging the archive
    separates them, and a column profile correlates ~0.99 between unrelated
    scans for that reason alone. Only a frame with no vertical structure breaks
    the tie.

    Bracket comparison cannot find it either: a per-column gain multiplies every
    bracket equally, so it cancels out of the ratio that gives the pedestal."""
    a = tifffile.memmap(path, mode="r")
    h = a.shape[0]
    band = np.asarray(a[int(h * 0.2):int(h * 0.8):3, :], np.float32)
    col = np.median(band, axis=0) - P0
    if np.median(col) < 500:
        sys.exit(f"{os.path.basename(path)}: too dark to be a flat field "
                 f"(median {np.median(col):.0f} counts above black)")
    g = col / np.median(col)
    # Smooth only lightly: segment steps are real and must survive.
    k = 5
    g = np.convolve(g, np.ones(k) / k, mode="same")
    g[:k] = g[k]; g[-k:] = g[-k - 1]
    g = np.clip(g, 0.5, 2.0)
    print(f"\nflat field from {os.path.basename(path)}: per-column gain "
          f"{g.min():.3f}..{g.max():.3f}, p5..p95 "
          f"{np.percentile(g,5):.3f}..{np.percentile(g,95):.3f}")
    return g.astype(np.float32)


def fit_pedestal_profile(bs, geo, P0):
    """Black level per COLUMN, not one number for the whole line.

    The sensor's dark offset varies across the line - measured 2026-08-11 at a
    182 count spread on a 1647 count pedestal, which is 8% of a shadow tone.
    Subtracting a single scalar leaves that pattern in the image as vertical
    strips, worst in the darks and amplified by the merge, because the fastest
    bracket divides the residual by the smallest exposure.

    Fitted with the exposure ratio FIXED at the measured one, so each column has
    a single parameter and a median over thousands of rows pins it. A free
    per-column slope is ill-conditioned wherever a column spans a narrow range,
    and produced pedestals of +/-80000 counts when tried."""
    f, s = bs[0], bs[-1]                 # widest gap: best separated
    r = s["t"] / f["t"]
    if r < 1.5:
        return None
    W = min(b["w"] for b in bs)
    H = min(b["h"] for b in bs)
    chunks = []
    for frac in (0.20, 0.35, 0.50, 0.65, 0.80):
        y = int(H * frac)
        rows = np.arange(y, min(y + 1500, H - 2), 3, dtype=np.float64)
        fy = np.round(geo[0].row(rows)).astype(np.int64)
        sy = np.round(geo[-1].row(rows)).astype(np.int64)
        # column shear between the two, ~a few px; P varies on a far coarser
        # scale, so one integer shift for the chunk is plenty
        d = int(round(float(geo[-1].col(rows.mean())
                            - geo[0].col(rows.mean()))))
        lo, hi = max(0, -d), min(W, W - d)
        if fy.min() < 0 or fy.max() >= f["h"] or sy.min() < 0 or sy.max() >= s["h"]:
            continue
        A = f["arr"][fy, :][:, lo:hi].astype(np.float32)
        B = s["arr"][sy, :][:, lo + d:hi + d].astype(np.float32)
        m = (A < SOFT_LO) & (B < SOFT_LO) & (B > A + 200)
        res = np.where(m, B - r * A, np.nan)
        with np.errstate(invalid="ignore"):
            col = np.nanmedian(res, axis=0)
        full = np.full(W, np.nan, np.float32)
        full[lo:hi] = col
        chunks.append(full)
    if len(chunks) < 2:
        return None
    with np.errstate(invalid="ignore"):
        prof = np.nanmedian(np.vstack(chunks), axis=0) / (1.0 - r)
    if not np.isfinite(prof).any():
        return None
    prof = np.where(np.isfinite(prof), prof, P0)
    # light smoothing: keep the segment structure, drop per-column noise
    k = 9
    prof = np.convolve(prof, np.ones(k) / k, mode="same")
    prof[:k] = prof[k]; prof[-k:] = prof[-k - 1]
    lo5, hi95 = np.percentile(prof, 5), np.percentile(prof, 95)
    print(f"\nper-column black level: median {np.median(prof):.0f}, "
          f"p5..p95 {lo5:.0f}..{hi95:.0f} ({hi95 - lo5:.0f} counts of banding removed)")
    return prof.astype(np.float32)


def fit_black(bs, geo):
    """Pedestal P: signal scales with exposure, P does not.

    The algebraic estimate per pair - (slow - r*fast)/(1-r) - is exact in theory
    and noisy in practice: on a heavily clipped set the two pairs disagreed by
    855 counts, and the median of them satisfied neither. Since what P is FOR is
    making the brackets agree on radiance, pick the P that does that: scan it
    and minimise the disagreement it leaves behind. Same quantity, chosen by the
    thing it has to deliver."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    print("\nblack level:")

    # Gather paired samples once, corrected by the fitted geometry.
    sets = []
    for i in range(len(bs) - 1):
        f, s = bs[i], bs[i + 1]
        r = s["t"] / f["t"]
        av, bv = [], []
        for frac in (0.20, 0.35, 0.50, 0.65, 0.80):
            y = int(H * frac) - T // 2
            x = W // 2 - T // 2
            fy = int(round(float(geo[i].row(y))))
            sy = int(round(float(geo[i + 1].row(y))))
            fx = x + int(round(float(geo[i].col(y))))
            sx = x + int(round(float(geo[i + 1].col(y))))
            a = f["arr"][fy:fy+T, fx:fx+T].astype(np.float32)[::3, ::3]
            b = s["arr"][sy:sy+T, sx:sx+T].astype(np.float32)[::3, ::3]
            m = (a < SAT_GUARD) & (b < SAT_GUARD) & (b > a + 200)
            if m.sum() > 2000:
                av.append(a[m]); bv.append(b[m])
        if av:
            sets.append((f["name"], s["name"], r,
                         np.concatenate(av), np.concatenate(bv)))
    if not sets:
        sys.exit("could not fit a black level - no usable overlap")

    def disagreement(P):
        errs = []
        for _fn, _sn, r, a, b in sets:
            ok = (a > P + 300) & (b > P + 300)
            if int(ok.sum()) < 500:
                return None
            ratio = ((b[ok] - P) / r) / (a[ok] - P)
            errs.append(abs(float(np.median(np.log(ratio)))))
        return float(np.mean(errs)) if errs else None

    best, bestP = None, None
    for P in np.arange(0.0, 3000.0, 25.0):
        d = disagreement(float(P))
        if d is not None and (best is None or d < best):
            best, bestP = d, float(P)
    if bestP is None:
        sys.exit("could not fit a black level - no usable overlap")
    for P in np.arange(max(0.0, bestP - 30), bestP + 30, 2.0):   # refine
        d = disagreement(float(P))
        if d is not None and d < best:
            best, bestP = d, float(P)

    for fn, sn, r, a, b in sets:
        # the algebraic estimate, for comparison
        alg = float(np.median((b - r * a) / (1.0 - r)))
        ok = (a > bestP + 300) & (b > bestP + 300)
        res = float(np.median(((b[ok] - bestP) / r) / (a[ok] - bestP))) if ok.sum() else float("nan")
        print(f"  {fn} vs {sn} (ratio {r:.3f}): algebraic P = {alg:7.1f}, "
              f"ratio at chosen P = {res:.3f}")
    print(f"  -> using P = {bestP:.0f}   (residual disagreement {100*best:.2f}%)")
    if best > 0.02:
        print("  [warn] brackets still disagree by >2% - suspect clipping or a "
              "scene that changed between passes")
    return bestP


# Ghost rejection. Brackets are separate passes seconds apart, so anything that
# moved - a car, a person, a branch - is in a different place in each, and the
# merge used to average all of them into a double exposure. Each bracket is now
# compared, in GHOST_BLOCK blocks, with the slowest bracket that is unclipped
# across that block (the anchor); where their radiances disagree by more than
# GHOST_LO its weight fades, and is gone at GHOST_HI. Blocks, not pixels: a
# block mean barely notices a sub-pixel edge mismatch but plainly sees an
# object that is not there. Dim blocks are not judged - their ratio is noise.
GHOST_BLOCK = 16
GHOST_LO, GHOST_HI = 0.10, 0.25      # |ln radiance ratio|
GHOST_FLOOR = 800                    # counts above black a block needs to be judged


def _block_means(a, B):
    h, w = a.shape
    ph, pw = -h % B, -w % B
    if ph or pw:
        a = np.pad(a, ((0, ph), (0, pw)), mode="edge")
    return a.reshape(a.shape[0] // B, B, a.shape[1] // B, B).mean((1, 3))


def _upsample(c, h, w, B):
    """Bilinear from block centres, so a rejected block fades rather than
    stepping - a hard edge in the weights is a visible edge in the noise."""
    def axis(n, m):
        u = (np.arange(m) + 0.5) / B - 0.5
        i0 = np.clip(np.floor(u).astype(np.int64), 0, max(n - 2, 0))
        i1 = np.minimum(i0 + 1, n - 1)
        t = np.clip(u - i0, 0.0, 1.0).astype(np.float32) if n > 1 else np.zeros(m, np.float32)
        return i0, i1, t
    r0, r1, tr = axis(c.shape[0], h)
    c0, c1, tc = axis(c.shape[1], w)
    a = c[r0] * (1 - tr)[:, None] + c[r1] * tr[:, None]
    return a[:, c0] * (1 - tc) + a[:, c1] * tc


def deghost(per):
    """per = [(sig, wt, t)] fastest first. Returns the weights to use.

    The anchor used to need a block with EVERY pixel unclipped (block weight
    > 0.99), and a bracket was only judged if it was bright (> GHOST_FLOOR)
    itself. On 1863-1866 that missed a whole car: sun glints in the pavement
    cost the slower brackets their anchor status one block at a time, the
    fastest bracket was then judged against itself, and its dark tyre - dim,
    so exempt anyway - was averaged into the road. Now the anchor is the
    slowest bracket with half its block unclipped, each pair is compared over
    the pixels BOTH see unclipped, and the test is whether the bracket saw what
    the anchor says it should have - which a shadow or a tyre fails by being
    too dark, not just too bright."""
    B = GHOST_BLOCK
    n = len(per)
    Wb = [_block_means(wt, B) for _, wt, _ in per]
    Sw = [_block_means(sig * wt, B) / np.maximum(Wb[i], 1e-6)
          for i, (sig, wt, _) in enumerate(per)]
    aidx = np.full(Wb[0].shape, -1, np.int64)
    for i in reversed(range(n)):                        # slowest first
        take = (aidx < 0) & (Wb[i] > 0.5) & (Sw[i] > GHOST_FLOOR)
        aidx[take] = i
    out = []
    for i, (sig, wt, t) in enumerate(per):
        c = np.ones(Wb[0].shape, np.float32)
        for a in range(i + 1, n):                       # anchors are slower brackets
            blk = aidx == a
            if not blk.any():
                continue
            asig, awt, at = per[a]
            m = wt * awt                                # pixels both see unclipped
            mb = _block_means(m, B)
            mm = np.maximum(mb, 1e-6)
            si = _block_means(sig * m, B) / mm          # this bracket, common pixels
            sa = _block_means(asig * m, B) / mm         # anchor, same pixels
            # Judged where the common set is real and the anchor implies this
            # bracket should have seen a clear signal; dimness is then evidence.
            ok = blk & (mb > 0.25) & (sa > GHOST_FLOOR) & (sa * (t / at) > GHOST_FLOOR)
            with np.errstate(invalid="ignore", divide="ignore"):
                dev = np.abs(np.log(np.maximum(si, 1.0) / t / (np.maximum(sa, 1.0) / at)))
            k = np.clip((dev - GHOST_LO) / (GHOST_HI - GHOST_LO), 0.0, 1.0)
            c = np.where(ok, 1.0 - k * k * (3.0 - 2.0 * k), c).astype(np.float32)
        out.append(wt if c.min() >= 1.0 else wt * _upsample(c, *sig.shape, B))
    return out


def tonemap(v, knee):
    """Scene-linear merge -> display values 0..1 for the viewable file.

    Extended Reinhard with its white point at 1.0 (the brightest thing the set
    recorded), then a 2.2 gamma. Below `knee` - the slowest bracket's clipping
    point, i.e. what one long exposure could have held - it stays close to
    linear; above it the extra highlight range is rolled into the top of the
    scale instead of being cut off at white."""
    x = np.maximum(v, 0.0) / knee
    L = 1.0 / knee
    y = x * (1.0 + x / (L * L)) / (1.0 + x)
    return np.clip(y, 0.0, 1.0) ** (1.0 / 2.2)


def merge(bs, geo, W, P, out_path, flat=None, ref=0):
    # The output grid has to land inside every bracket at BOTH ends. A negative
    # fitted offset puts the source row below 0 near the top, and a negative
    # numpy slice start wraps to the end of the file — which yields an empty
    # slab rather than an error, so the failure surfaced far from its cause.
    # Start the grid at the first reference row every bracket can supply.
    # Which reference rows can EVERY bracket supply? Evaluated rather than
    # solved, because the row map may be a curve: a negative source row wraps to
    # the end of the file in numpy and fails somewhere unrelated.
    # A bracket also has to have been MEASURED there: outside the bands its
    # alignment is a guess, and at the start of the fastest pass a bad one.
    href = bs[ref]["h"]
    ys = np.arange(href, dtype=np.float64)
    valid = np.ones(href, bool)
    for b, g in zip(bs, geo):
        for xe in (0.0, float(W)):
            sy = g.row(ys, xe)
            valid &= (sy >= LZ - 1) & (sy <= b["h"] - LZ - 2)
        valid &= (ys >= g.lo) & (ys <= g.hi)
    idx = np.flatnonzero(valid)
    if idx.size < 16:
        sys.exit("no usable overlap between brackets")
    top, end = int(idx[0]), int(idx[-1]) + 1
    H = end - top
    if top or end < href:
        print(f"  (using reference rows {top}..{end}: the rest is not present in "
              f"every bracket)")

    # Column margin: the sensor-axis shear means a bracket's source column can
    # sit either side of the output column, so the output is inset by the worst
    # excursion over the range actually used, plus the kernel's reach. A few px
    # out of 8192.
    worst = 0.0
    for g in geo:
        worst = max(worst, float(np.max(np.abs(g.col(ys[top:end])))))
    M = int(np.ceil(worst)) + LZ
    Wout = W - 2 * M

    t_max = max(b["t"] for b in bs)
    t_min = min(b["t"] for b in bs)
    Pm = float(P) if np.isscalar(P) else float(np.median(P))   # for the scalars below
    # 1.0 = the FASTEST bracket's clipping point: the brightest thing the set
    # can know. It used to be the slowest bracket's, which put every recovered
    # highlight - the reason for bracketing at all - above 1.0, where most
    # viewers (and Photoshop's 32-bit view) show plain white.
    scale = t_min / (SAT - Pm)
    knee = t_min / t_max               # where a single slow exposure would clip
    print(f"\nmerging {len(bs)} brackets -> {Wout} x {H}   (inset {M} px per side "
          f"for the column shear)")

    out = tifffile.memmap(out_path, shape=(H, Wout), dtype=np.float32,
                          photometric="minisblack", bigtiff=True)
    view_path = os.path.splitext(out_path)[0] + "_view.tif"
    view = tifffile.memmap(view_path, shape=(H, Wout), dtype=np.uint16,
                           photometric="minisblack", bigtiff=True)
    all_clipped = rescued = salvaged = floored = 0
    kept = np.zeros(len(bs)); offered = np.zeros(len(bs))
    for y0 in range(0, H, CHUNK):
        y1 = min(y0 + CHUNK, H)
        # Output row y comes from REFERENCE row y+top; `top` is what keeps every
        # bracket's source index non-negative.
        rows = np.arange(y0, y1, dtype=np.float64) + top
        per = []; raw_of = []
        for b, g in zip(bs, geo):
            raw, peak = resample(b["arr"], g, rows, M, Wout)
            # Weight fades to zero as the brightest raw sample under the kernel
            # approaches saturation - blending a clipped sample with good ones
            # would invent a plausible mid-grey.
            def soft(v):
                w = np.clip((SOFT_HI - v) / (SOFT_HI - SOFT_LO), 0.0, 1.0)
                return w * w * (3.0 - 2.0 * w)      # smoothstep: no visible seam
            wt = soft(peak)
            # Pedestal and flat vary on a far coarser scale than the column
            # shift moves within a chunk, so one integer offset per chunk.
            xi = M + int(round(float(np.mean(g.col(rows)))))
            # Pedestal is a property of the SENSOR column, so it is indexed by
            # this bracket's own source columns - the shear means each bracket
            # reads a slightly different part of the line for the same output
            # column, and that is exactly the sample whose offset applies.
            ped = P if np.isscalar(P) else P[xi:xi + Wout][None, :]
            sig = raw - ped
            # Flat field divides the SIGNAL, never the pedestal: the offset is
            # added after the pixel's gain, so correcting it by gain would bend
            # the black level instead of flattening the response.
            if flat is not None:
                sig = sig / flat[xi:xi + Wout][None, :]
            per.append((sig, wt, np.float32(b["t"])))
            raw_of.append(raw)
            # Keep the fastest bracket's own reading. Where every weight has
            # gone to zero it is the only thing left that still has structure,
            # and flooring those pixels to a constant instead was replacing the
            # last ring of real highlight detail with flat white.
            if b is bs[0]:
                fastest_raw = raw
                fastest_peak = peak
                fastest_ped = ped
                fastest_flat = (flat[xi:xi + Wout][None, :]
                                if flat is not None else np.float32(1.0))
        num = np.zeros((y1 - y0, Wout), np.float32)
        den = np.zeros((y1 - y0, Wout), np.float32)
        # A clipped sample is not nothing: it says the radiance is AT LEAST its
        # clip level. Whatever the unclipped brackets end up claiming, the
        # answer may not fall below the brightest floor any clipped bracket
        # sets. Without this, a pixel where every slow bracket had saturated
        # could be reported at a twentieth of what they proved it exceeded.
        floor = np.zeros((y1 - y0, Wout), np.float32)
        for i, ((sig, wt, t), wg) in enumerate(zip(per, deghost(per))):
            num += wg * sig
            den += wg * t
            offered[i] += float(wt.sum()); kept[i] += float(wg.sum())
            np.maximum(floor, np.where(raw_of[i] >= SOFT_HI, sig / t, 0.0), out=floor)
        del per, raw_of
        # Three cases, in order of how much is actually known:
        #   weights survive        -> the weighted estimate
        #   none survive, not sat  -> the fastest bracket's own value (shoulder
        #                             data: compressed, but real structure)
        #   saturated even there   -> a floor; nothing in the set knows more
        dead = den <= 0
        hard = dead & (fastest_peak >= SAT)
        all_clipped += int(hard.sum())
        salvaged += int((dead & ~hard).sum())
        rad = np.where(dead,
                       np.where(hard, (SAT - Pm) / t_min,
                                (fastest_raw - fastest_ped) / fastest_flat / t_min),
                       num / np.maximum(den, 1e-12))
        floored += int((rad < floor).sum())
        rad = np.maximum(rad, floor)
        chunk = (rad * scale).astype(np.float32)
        rescued += int((chunk > knee).sum())
        out[y0:y1] = chunk
        view[y0:y1] = (tonemap(chunk, knee) * 65535.0 + 0.5).astype(np.uint16)
        print(f"  rows {y0:6d}-{y1:6d}", end="\r")
    out.flush(); view.flush()
    px = H * W
    print(f"\nwrote {out_path}  ({os.path.getsize(out_path)/1e6:.0f} MB, 32-bit float, "
          f"1.0 = brightest recoverable)")
    # Not "wrote ": the Suite takes the last such line as the merge result.
    print(f"  viewable  -> {view_path}  (16-bit, highlights rolled off above "
          f"{knee:.3f})")
    print("  ghost rejection, share of each bracket's weight removed: " +
          ", ".join(f"{b['name']}: {100.0 * (1 - k / max(o, 1e-9)):.1f}%"
                    for b, k, o in zip(bs, kept, offered)))
    print(f"  above slowest-bracket clipping : {rescued:,} px ({100.0*rescued/px:.2f}%)")
    print(f"  held by the fastest bracket    : {salvaged:,} px ({100.0*salvaged/px:.4f}%)"
          f"  <- shoulder detail, would have been flat white")
    print(f"  saturated in every bracket     : {all_clipped:,} px ({100.0*all_clipped/px:.4f}%)")
    print(f"  raised to a clipped bracket's floor: {floored:,} px ({100.0*floored/px:.4f}%)"
          f"  <- the unclipped brackets claimed less than a clipped one proved")
    return view


def check_agreement(bs, geo, P):
    """Do the brackets actually agree on radiance once corrected? If the pedestal
    or the exposures were wrong, they would not."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    print("\nbracket agreement (median ratio of implied radiance, want 1.000):")
    y = int(H * 0.35) - T // 2
    x = W // 2 - T // 2
    ref = bs[0]
    ry = int(round(float(geo[0].row(y))))
    a = ref["arr"][ry:ry+T, x:x+T].astype(np.float32)
    # P may be a per-column profile; take the slice these tiles actually cover.
    pa = P if np.isscalar(P) else P[x:x + T][None, :]
    for b, g in list(zip(bs, geo))[1:]:
        by = int(round(float(g.row(y))))
        bx = x + int(round(float(g.col(y))))
        c = b["arr"][by:by+T, bx:bx+T].astype(np.float32)
        pc = P if np.isscalar(P) else P[bx:bx + T][None, :]
        m = (a < SAT_GUARD) & (c < SAT_GUARD) & (a > pa + 300)
        if m.sum() < 5000:
            print(f"  {b['name']}: too little overlap to judge"); continue
        ratio = (((c - pc) / b["t"]) / ((a - pa) / ref["t"]))[m]
        print(f"  {ref['name']} vs {b['name']}: {np.median(ratio):.3f} "
              f"(IQR {np.percentile(ratio,25):.3f}-{np.percentile(ratio,75):.3f})")


def preview(view, path, step=12):
    img = (np.asarray(view[::step, ::step]) >> 8).astype(np.uint8)
    tifffile.imwrite(path, img, photometric="minisblack")
    print(f"  preview -> {path}  ({img.shape[1]} x {img.shape[0]}, same curve as the viewable file)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scans", nargs="+", help="scan numbers (0787) or full paths")
    ap.add_argument("--dir", default=r"D:\capture")
    ap.add_argument("--out", default=r"D:\hdr-merge")
    ap.add_argument("--pass", dest="pas", default="p0_C")
    ap.add_argument("--scalar-black", action="store_true",
                    help="one black level for the whole line instead of a "
                         "per-column profile (for comparing the two)")
    ap.add_argument("--suffix", default="", help="appended to the output name")
    ap.add_argument("--flat", default="",
                    help="scan number or path of a FLAT FIELD sweep (evenly lit, "
                         "featureless, defocused). Corrects the sensor's "
                         "per-column gain - the vertical banding that no amount "
                         "of ordinary data can separate from the scene.")
    args = ap.parse_args()

    paths = [s if os.path.sep in s else
             os.path.join(args.dir, f"scan_{s}_{args.pas}.tif") for s in args.scans]
    for p in paths:
        if not os.path.exists(p):
            sys.exit(f"missing: {p}")

    bs = load_set(paths)
    bs.sort(key=lambda b: b["t"])          # fastest (darkest) first
    print("bracket set:")
    t0 = bs[0]["t"]
    for b in bs:
        print(f"  {b['name']}  {b['w']}x{b['h']}  {b['rate']:9.1f} Hz  "
              f"{1e6*b['t']:7.1f} us  {np.log2(b['t']/t0):+.2f} stop")

    # The SLOWEST bracket is the reference: it carries most of the signal
    # wherever it is not clipped (55% on 1833-1836), so it is the one that goes
    # through untouched. Referencing the fastest resampled all the good data
    # and kept only the noisiest bracket sharp.
    ref = len(bs) - 1
    geo, W = fit_geometry(bs, ref)
    verify_fit(bs, geo, ref)
    # Measured exposures replace 1/line.rate everywhere below.
    te, P = fit_response(bs, geo)
    for b, t in zip(bs, te):
        b["t"] = t
    if P <= 0:
        P = fit_black(bs, geo)
    # One number per line leaves the sensor's own column-to-column offset in the
    # image as vertical strips; a profile removes them.
    if not args.scalar_black:
        prof = fit_pedestal_profile(bs, geo, P)
        if prof is not None:
            P = prof
    check_agreement(bs, geo, P)

    os.makedirs(args.out, exist_ok=True)
    # Name from the scan numbers, not from the arguments: the Suite passes full
    # paths, which would otherwise end up in the filename.
    labels = []
    for p in paths:
        m = re.search(r"scan_(\d+)", os.path.basename(p))
        labels.append(m.group(1) if m else os.path.splitext(os.path.basename(p))[0])
    stem = "hdr_" + "_".join(labels) + args.suffix
    out_path = os.path.join(args.out, stem + ".tif")
    flat = None
    if args.flat:
        fp = args.flat if os.path.sep in args.flat else os.path.join(
            args.dir, f"scan_{args.flat}_{args.pas}.tif")
        if not os.path.exists(fp):
            sys.exit(f"flat field not found: {fp}")
        flat = load_flat(fp, float(P) if np.isscalar(P) else float(np.median(P)))

    view = merge(bs, geo, W, P, out_path, flat, ref)
    preview(view, os.path.join(args.out, stem + "_preview.tif"))


if __name__ == "__main__":
    main()
