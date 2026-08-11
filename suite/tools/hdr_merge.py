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
#     it, so each bracket is resampled onto the reference's line grid.
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
MIN_NCC = 0.35       # below this a tile has not really matched anything


def robust_polyfit(x, y, deg, iters=3):
    """Least squares, then re-fit without the points the fit disowns. One tile
    that locked onto the wrong feature would otherwise tilt the whole model."""
    keep = np.ones(len(x), bool)
    p = np.polyfit(x, y, deg)
    for _ in range(iters):
        r = y - np.polyval(p, x)
        mad = float(np.median(np.abs(r - np.median(r)))) + 1e-9
        k = np.abs(r - np.median(r)) < 3.0 * mad
        if int(k.sum()) < deg + 2:
            break
        keep = k
        p = np.polyfit(x[keep], y[keep], deg)
    return p, keep
CHUNK = 2048         # output rows per pass over the files
T = 1024             # probe tile size


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


def masked_ncc(a, b, ma, mb, dy, dx=0):
    A  = a[max(0, dy):a.shape[0] + min(0, dy), max(0, dx):a.shape[1] + min(0, dx)]
    B  = b[max(0, -dy):b.shape[0] + min(0, -dy), max(0, -dx):b.shape[1] + min(0, -dx)]
    MA = ma[max(0, dy):ma.shape[0] + min(0, dy), max(0, dx):ma.shape[1] + min(0, dx)]
    MB = mb[max(0, -dy):mb.shape[0] + min(0, -dy), max(0, -dx):mb.shape[1] + min(0, -dx)]
    m = MA & MB
    if int(m.sum()) < 20000:
        return None
    x = A[m].astype(np.float32); y = B[m].astype(np.float32)
    x -= x.mean(); y -= y.mean()
    sx, sy = x.std(), y.std()
    if sx < 1e-6 or sy < 1e-6:
        return None
    return float((x * y).mean() / (sx * sy))


def _peak(sc):
    """Best key in a {shift: score} map, refined to sub-pixel by a parabola."""
    if len(sc) < 3:
        return None
    k = max(sc, key=sc.get)
    if k - 1 not in sc or k + 1 not in sc:
        return float(k)
    y0, y1, y2 = sc[k - 1], sc[k], sc[k + 1]
    den = (y0 - 2 * y1 + y2)
    return float(k + (0.5 * (y0 - y2) / den if abs(den) > 1e-9 else 0.0))


def probe_shift(ref, mov, y, x, span=96):
    """Sub-pixel (row, column) offset of `mov` at this tile, or (None, None).

    Coarse-to-fine, and the span is WIDE. It used to be +/-8, which silently
    clipped: on a set whose brackets sat ~10 px apart every tile reported
    exactly +8.00 and the geometry was then fitted to that flat lie. A peak
    landing on the boundary is now retried with a wider span instead.

    One axis at a time - they are near-independent here, and a full 2-D search
    costs an order of magnitude more for the same answer."""
    a = ref[y:y+T, x:x+T]; b = mov[y:y+T, x:x+T]
    ma = a < SAT_GUARD;    mb = b < SAT_GUARD
    af = a.astype(np.float32); bf = b.astype(np.float32)
    # coarse pass on a centre crop: same peak, a quarter of the work
    q = T // 4
    ac, bc = af[q:T-q, q:T-q], bf[q:T-q, q:T-q]
    mac, mbc = ma[q:T-q, q:T-q], mb[q:T-q, q:T-q]

    def scan(fixed_dy, along_x):
        s = span
        while True:
            step = max(1, s // 12)
            sc = {}
            for d in range(-s, s + 1, step):
                c = (masked_ncc(ac, bc, mac, mbc, fixed_dy, d) if along_x
                     else masked_ncc(ac, bc, mac, mbc, d, 0))
                if c is not None:
                    sc[d] = c
            if not sc:
                return None
            k = max(sc, key=sc.get)
            if abs(k) < s or s >= 512:          # peak is inside the window
                break
            s *= 2                               # it was not - widen and retry
        fine = {}
        for d in range(k - step, k + step + 1):
            c = (masked_ncc(af, bf, ma, mb, fixed_dy, d) if along_x
                 else masked_ncc(af, bf, ma, mb, d, 0))
            if c is not None:
                fine[d] = c
        return _peak(fine)

    # A tile with no real structure in common still produces a peak somewhere.
    # Refuse to report one unless the match is actually good, or the fit ends up
    # drawn through noise.
    if masked_ncc(af, bf, ma, mb, 0, 0) is None:
        return None, None
    dy = scan(0, False)
    if dy is None:
        return None, None
    kdy = int(round(dy))
    dx = scan(kdy, True)
    best = masked_ncc(af, bf, ma, mb, kdy, int(round(dx)) if dx is not None else 0)
    if best is None or best < MIN_NCC:
        return None, None
    return dy, dx


def fit_geometry(bs, ref=0):
    """Model each bracket on the reference grid as

        src_row = scale*y + off          (sweep axis)
        src_col = x + cx0 + cx1*y        (sensor axis - the scan line itself)

    `scale` comes from the delivered line counts (same arc, different pulse
    count), so only `off` is fitted. The column term is fitted outright: the
    brackets shear along the sensor axis, by an amount that grows with the
    exposure gap - measured 2026-08-11 at ~3 px over the full height for a
    2-stop bracket, 0 at the top. A constant column shift cannot describe that,
    which is why the top of a merge looked aligned and the bottom did not."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    ys = [int(H * f) - T // 2 for f in np.linspace(0.10, 0.90, 11)]
    xs = [W // 3 - T // 2, W // 2 - T // 2, 2 * W // 3 - T // 2]
    geo = []
    print("\ngeometry fit (reference %s):" % bs[ref]["name"])
    for i, b in enumerate(bs):
        if i == ref:
            geo.append((np.array([1.0, 0.0]), np.array([0.0, 0.0])))
            print(f"  {b['name']}: reference"); continue
        # probe_shift returns dy such that MOV row i holds REF row i+dy, so the
        # source row for reference row y is y-dy, NOT y+dy. Getting that
        # backwards doubles the misalignment instead of removing it, and an
        # in-sample residual cannot see it - it only measures how well a line
        # fits the measurements, not which way they are applied. Verified
        # synthetically 2026-08-11; verify_fit() below now checks the applied
        # model out of sample.
        k = (b["h"] - 1) / (bs[ref]["h"] - 1)     # ref row -> this bracket's row
        obs = []
        for y in ys:
            v = [probe_shift(bs[ref]["arr"], b["arr"], y, x) for x in xs]
            dys = [q[0] for q in v if q[0] is not None]
            dxs = [q[1] for q in v if q[1] is not None]
            if dys:
                obs.append((y + T / 2, float(np.median(dys)),
                            float(np.median(dxs)) if dxs else 0.0))
        if not obs:
            sys.exit(f"{b['name']}: could not measure alignment anywhere")

        # rows: wanted src(y) = k*y + off, measured src(y) = y - dy.
        # The line counts give a good prior for the slope, but they only bound
        # the sweep - the delivered pulses are not guaranteed evenly spread - so
        # the measurements choose the slope and the prior is printed alongside
        # to show whether they agree.
        yv = np.array([o[0] for o in obs], float)
        sv = np.array([o[0] - o[1] for o in obs], float)      # y - dy
        # Quadratic when there is enough to support it: the drift is not a
        # straight line - on 0814-0816 a linear fit left 8 px, because the sweep
        # does not accumulate its error evenly. Degree 1 is kept as the fallback.
        deg = 2 if len(obs) >= 6 else 1
        if len(obs) >= 3:
            rp, rkeep = robust_polyfit(yv, sv, deg)
        else:
            rp, rkeep = np.array([k, 0.0]), np.ones(len(obs), bool)
        rres = list(sv[rkeep] - np.polyval(rp, yv[rkeep]))
        rrms = float(np.sqrt(np.mean(np.square(rres))))
        dropped = int((~rkeep).sum())
        k_prior = k
        k = float(np.polyval(np.polyder(rp), float(np.mean(yv))))   # local slope

        # columns: src_col = x + cx0 + cx1*y, and measured src offset is -dx
        yc = np.array([o[0] for o in obs], float)
        sxv = np.array([-o[2] for o in obs], float)
        if len(obs) >= 3:
            cp, ckeep = robust_polyfit(yc, sxv, deg)
        else:
            cp, ckeep = np.array([0.0, float(np.median(sxv))]), np.ones(len(obs), bool)
        cres = sxv[ckeep] - np.polyval(cp, yc[ckeep])
        crms = float(np.sqrt(np.mean(np.square(cres))))

        drift_top = float(np.polyval(rp, 0.0)) - 0.0
        drift_bot = float(np.polyval(rp, H)) - H
        print(f"  {b['name']}: {b['h']} lines vs {bs[ref]['h']}  (degree {deg} fit, "
              f"{len(obs)} usable tiles, {dropped} rejected)")
        print(f"      rows: {drift_top:+.1f} px at the top, {drift_bot:+.1f} at the bottom; "
              f"residual rms {rrms:.2f}, worst {max(map(abs, rres)):.2f}")
        print(f"      line counts alone predicted {(k_prior - 1.0) * H:+.1f} px of drift")
        print(f"      cols: {float(np.polyval(cp, 0.0)):+.2f} px at the top, "
              f"{float(np.polyval(cp, H)):+.2f} at the bottom; residual rms {crms:.2f} px")
        if rrms > 1.5:
            print("      [warn] row model fits poorly - alignment may be unreliable")
        geo.append((rp, cp))
    return geo, W


def verify_fit(bs, geo, ref=0):
    """Apply the fitted model and re-measure. This is the check that catches a
    model applied the WRONG WAY ROUND, which the in-sample residual cannot."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    print("\nverify (residual after applying the fit, want ~0):")
    worst = 0.0
    for i, (b, (rp, cp)) in enumerate(zip(bs, geo)):
        if i == ref:
            continue
        out = []
        for f in (0.20, 0.50, 0.80):
            y = int(H * f)
            x = W // 2 - T // 2
            sy = int(round(float(np.polyval(rp, y))))
            sx = x + int(round(float(np.polyval(cp, y))))
            if sy < 0 or sy + T >= b["h"] or sx < 0 or sx + T >= b["w"]:
                continue
            dy, dx = probe_shift(bs[ref]["arr"][y:y+T, x:x+T],
                                 b["arr"][sy:sy+T, sx:sx+T], 0, 0)
            if dy is None:
                continue
            out.append((dy, dx if dx is not None else 0.0))
            worst = max(worst, abs(dy), abs(dx if dx is not None else 0.0))
        txt = "  ".join(f"dy={d:+.1f} dx={x_:+.1f}" for d, x_ in out)
        print(f"  {b['name']}: {txt}")
    if worst > 1.5:
        print(f"  [WARN] up to {worst:.1f} px left after correction - the model is "
              f"not describing this set")
    else:
        print(f"  -> aligned to within {worst:.1f} px")
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
            fy = int(round(float(np.polyval(geo[i][0], y))))
            sy = int(round(float(np.polyval(geo[i + 1][0], y))))
            fx = x + int(round(float(np.polyval(geo[i][1], y))))
            sx = x + int(round(float(np.polyval(geo[i + 1][1], y))))
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
        fy = np.round(np.polyval(geo[0][0], rows)).astype(np.int64)
        sy = np.round(np.polyval(geo[-1][0], rows)).astype(np.int64)
        # column shear between the two, ~a few px; P varies on a far coarser
        # scale, so one integer shift for the chunk is plenty
        d = int(round(float(np.polyval(geo[-1][1], rows.mean())
                            - np.polyval(geo[0][1], rows.mean()))))
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
            fy = int(round(float(np.polyval(geo[i][0], y))))
            sy = int(round(float(np.polyval(geo[i + 1][0], y))))
            fx = x + int(round(float(np.polyval(geo[i][1], y))))
            sx = x + int(round(float(np.polyval(geo[i + 1][1], y))))
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


def merge(bs, geo, W, P, out_path, flat=None):
    # The output grid has to land inside every bracket at BOTH ends. A negative
    # fitted offset puts the source row below 0 near the top, and a negative
    # numpy slice start wraps to the end of the file — which yields an empty
    # slab rather than an error, so the failure surfaced far from its cause.
    # Start the grid at the first reference row every bracket can supply.
    # Which reference rows can EVERY bracket supply? Evaluated rather than
    # solved, because the row map may be a curve: a negative source row wraps to
    # the end of the file in numpy and fails somewhere unrelated.
    href = bs[0]["h"]
    ys = np.arange(href, dtype=np.float64)
    valid = np.ones(href, bool)
    for b, (rp, _cp) in zip(bs, geo):
        sy = np.polyval(rp, ys)
        valid &= (sy >= 0) & (sy <= b["h"] - 2)
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
    # excursion over the range actually used. A few px out of 8192.
    worst = 0.0
    for (_rp, cp) in geo:
        worst = max(worst, float(np.max(np.abs(np.polyval(cp, ys[top:end])))))
    M = int(np.ceil(worst)) + 1
    Wout = W - 2 * M

    t_max = max(b["t"] for b in bs)
    t_min = min(b["t"] for b in bs)
    Pm = float(P) if np.isscalar(P) else float(np.median(P))   # for the scalars below
    scale = t_max / (SAT - Pm)         # 1.0 = the slowest bracket's clipping point
    print(f"\nmerging {len(bs)} brackets -> {Wout} x {H}   (inset {M} px per side "
          f"for the column shear)")

    out = tifffile.memmap(out_path, shape=(H, Wout), dtype=np.float32,
                          photometric="minisblack", bigtiff=True)
    all_clipped = rescued = salvaged = 0
    for y0 in range(0, H, CHUNK):
        y1 = min(y0 + CHUNK, H)
        # Output row y comes from REFERENCE row y+top; `top` is what keeps every
        # bracket's source index non-negative.
        rows = np.arange(y0, y1, dtype=np.float64) + top
        num = np.zeros((y1 - y0, Wout), np.float32)
        den = np.zeros((y1 - y0, Wout), np.float32)
        for b, (rp, cp) in zip(bs, geo):
            src = np.polyval(rp, rows)
            i0 = np.floor(src).astype(np.int64)
            wgt = (src - i0).astype(np.float32)[:, None]
            # Belt and braces: a stray index here would slice from the end of the
            # file and fail somewhere unrelated, so clamp and say so instead.
            if i0.min() < 0 or i0.max() + 1 >= b["h"]:
                sys.exit(f"{b['name']}: source rows {i0.min()}..{i0.max()+1} "
                         f"outside 0..{b['h']-1} - geometry fit is wrong")
            # One column offset per chunk. The shear is a few px over 25k rows,
            # so within 2048 rows it moves well under a quarter pixel - far below
            # what we are correcting - and this keeps it to one slice per bracket.
            cshift = float(np.polyval(cp, rows.mean()))
            xi = M + int(np.floor(cshift))
            xf = np.float32(cshift - np.floor(cshift))
            lo, hi = int(i0.min()), int(i0.max()) + 2
            slab = b["arr"][lo:hi, :].astype(np.float32)
            def col(a, x0):
                return a[:, x0:x0 + Wout]
            r0 = col(slab, xi)[i0 - lo] * (1.0 - xf) + col(slab, xi + 1)[i0 - lo] * xf
            r1 = col(slab, xi)[i0 + 1 - lo] * (1.0 - xf) + col(slab, xi + 1)[i0 + 1 - lo] * xf
            # Weight fades to zero as either source row approaches saturation,
            # and a row that is already clipped contributes nothing - blending a
            # clipped row with a good one would invent a plausible mid-grey.
            def soft(v):
                w = np.clip((SOFT_HI - v) / (SOFT_HI - SOFT_LO), 0.0, 1.0)
                return w * w * (3.0 - 2.0 * w)      # smoothstep: no visible seam
            wt = np.minimum(soft(r0), soft(r1))
            raw = r0 * (1.0 - wgt) + r1 * wgt
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
            num += wt * sig
            den += wt * np.float32(b["t"])
            # Keep the fastest bracket's own reading. Where every weight has
            # gone to zero it is the only thing left that still has structure,
            # and flooring those pixels to a constant instead was replacing the
            # last ring of real highlight detail with flat white.
            if b is bs[0]:
                fastest_raw = raw
                fastest_ped = ped
                fastest_flat = (flat[xi:xi + Wout][None, :]
                                if flat is not None else np.float32(1.0))
        # Three cases, in order of how much is actually known:
        #   weights survive        -> the weighted estimate
        #   none survive, not sat  -> the fastest bracket's own value (shoulder
        #                             data: compressed, but real structure)
        #   saturated even there   -> a floor; nothing in the set knows more
        dead = den <= 0
        hard = dead & (fastest_raw >= SAT)
        all_clipped += int(hard.sum())
        salvaged += int((dead & ~hard).sum())
        rad = np.where(dead,
                       np.where(hard, (SAT - Pm) / t_min,
                                (fastest_raw - fastest_ped) / fastest_flat / t_min),
                       num / np.maximum(den, 1e-12))
        chunk = (rad * scale).astype(np.float32)
        rescued += int((chunk > 1.0).sum())
        out[y0:y1] = chunk
        print(f"  rows {y0:6d}-{y1:6d}", end="\r")
    out.flush()
    px = H * W
    print(f"\nwrote {out_path}  ({os.path.getsize(out_path)/1e6:.0f} MB, 32-bit float)")
    print(f"  above slowest-bracket clipping : {rescued:,} px ({100.0*rescued/px:.2f}%)")
    print(f"  held by the fastest bracket    : {salvaged:,} px ({100.0*salvaged/px:.4f}%)"
          f"  <- shoulder detail, would have been flat white")
    print(f"  saturated in every bracket     : {all_clipped:,} px ({100.0*all_clipped/px:.4f}%)")
    return out


def check_agreement(bs, geo, P):
    """Do the brackets actually agree on radiance once corrected? If the pedestal
    or the exposures were wrong, they would not."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    print("\nbracket agreement (median ratio of implied radiance, want 1.000):")
    y = int(H * 0.35) - T // 2
    x = W // 2 - T // 2
    ref = bs[0]
    ry = int(round(float(np.polyval(geo[0][0], y))))
    a = ref["arr"][ry:ry+T, x:x+T].astype(np.float32)
    # P may be a per-column profile; take the slice these tiles actually cover.
    pa = P if np.isscalar(P) else P[x:x + T][None, :]
    for b, (rp, cp) in list(zip(bs, geo))[1:]:
        by = int(round(float(np.polyval(rp, y))))
        bx = x + int(round(float(np.polyval(cp, y))))
        c = b["arr"][by:by+T, bx:bx+T].astype(np.float32)
        pc = P if np.isscalar(P) else P[bx:bx + T][None, :]
        m = (a < SAT_GUARD) & (c < SAT_GUARD) & (a > pa + 300)
        if m.sum() < 5000:
            print(f"  {b['name']}: too little overlap to judge"); continue
        ratio = (((c - pc) / b["t"]) / ((a - pa) / ref["t"]))[m]
        print(f"  {ref['name']} vs {b['name']}: {np.median(ratio):.3f} "
              f"(IQR {np.percentile(ratio,25):.3f}-{np.percentile(ratio,75):.3f})")


def preview(out, path, step=12):
    sm = np.asarray(out[::step, ::step], dtype=np.float32)
    v = np.log1p(np.maximum(sm, 0) * 8.0)
    lo, hi = np.percentile(v, 0.5), np.percentile(v, 99.8)
    img = np.clip((v - lo) / max(hi - lo, 1e-9), 0, 1)
    tifffile.imwrite(path, (img * 255).astype(np.uint8), photometric="minisblack")
    print(f"  preview -> {path}  ({img.shape[1]} x {img.shape[0]}, log tone map)")


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

    geo, W = fit_geometry(bs)
    verify_fit(bs, geo)
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

    out = merge(bs, geo, W, P, out_path, flat)
    preview(out, os.path.join(args.out, stem + "_preview.tif"))


if __name__ == "__main__":
    main()
