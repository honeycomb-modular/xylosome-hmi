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


def masked_ncc(a, b, ma, mb, dy):
    A  = a[max(0, dy):a.shape[0] + min(0, dy)]
    B  = b[max(0, -dy):b.shape[0] + min(0, -dy)]
    m  = ma[max(0, dy):ma.shape[0] + min(0, dy)] & mb[max(0, -dy):mb.shape[0] + min(0, -dy)]
    if int(m.sum()) < 20000:
        return None
    x = A[m].astype(np.float32); y = B[m].astype(np.float32)
    x -= x.mean(); y -= y.mean()
    sx, sy = x.std(), y.std()
    if sx < 1e-6 or sy < 1e-6:
        return None
    return float((x * y).mean() / (sx * sy))


def probe_dy(ref, mov, y, x, span=8):
    """Sub-pixel row offset of `mov` relative to `ref` at this tile, or None."""
    a = ref[y:y+T, x:x+T]; b = mov[y:y+T, x:x+T]
    ma = a < SAT_GUARD;    mb = b < SAT_GUARD
    af = a.astype(np.float32); bf = b.astype(np.float32)
    sc = {}
    for dy in range(-span, span + 1):
        c = masked_ncc(af, bf, ma, mb, dy)
        if c is not None:
            sc[dy] = c
    if len(sc) < 3:
        return None
    k = max(sc, key=sc.get)
    if k - 1 not in sc or k + 1 not in sc:
        return float(k)
    # parabolic interpolation through the peak and its neighbours
    y0, y1, y2 = sc[k - 1], sc[k], sc[k + 1]
    den = (y0 - 2 * y1 + y2)
    return float(k + (0.5 * (y0 - y2) / den if abs(den) > 1e-9 else 0.0))


def fit_geometry(bs, ref=0):
    """Model each bracket as  src_row = scale*y + offset  on the reference grid.

    scale comes from the delivered line counts (same arc, different pulse count),
    so only the offset is fitted - and the residual then tells us whether that
    model is actually right."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    ys = [int(H * f) - T // 2 for f in np.linspace(0.10, 0.90, 11)]
    xs = [W // 3 - T // 2, W // 2 - T // 2, 2 * W // 3 - T // 2]
    geo = []
    print("\ngeometry fit (reference %s):" % bs[ref]["name"])
    for i, b in enumerate(bs):
        if i == ref:
            geo.append((1.0, 0.0)); print(f"  {b['name']}: reference"); continue
        scale = (bs[ref]["h"] - 1) / (b["h"] - 1)
        obs = []
        for y in ys:
            v = [probe_dy(bs[ref]["arr"], b["arr"], y, x) for x in xs]
            v = [q for q in v if q is not None]
            if v:
                obs.append((y + T / 2, float(np.median(v))))
        if not obs:
            sys.exit(f"{b['name']}: could not measure alignment anywhere")
        # dy(y) = (scale-1)*y + offset  ->  offset = dy - (scale-1)*y
        offs = [dy - (scale - 1.0) * yc for yc, dy in obs]
        off = float(np.median(offs))
        resid = [dy - ((scale - 1.0) * yc + off) for yc, dy in obs]
        rms = float(np.sqrt(np.mean(np.square(resid))))
        drift = (scale - 1.0) * H
        print(f"  {b['name']}: {b['h']} lines vs {bs[ref]['h']} -> scale {scale:.7f} "
              f"({drift:+.1f} lines of drift), offset {off:+.2f}")
        print(f"      residual rms {rms:.2f} lines, worst {max(map(abs, resid)):.2f}")
        if rms > 1.5:
            print("      [warn] model fits poorly - alignment may be unreliable")
        geo.append((scale, off))
    return geo, W


def fit_black(bs, geo):
    """Pedestal P: signal scales with exposure, P does not. For a pair with
    exposure ratio r,  (slow-P) = r*(fast-P)  =>  P = (slow - r*fast)/(1-r)."""
    H = min(b["h"] for b in bs)
    W = min(b["w"] for b in bs)
    ests = []
    print("\nblack level:")
    for i in range(len(bs) - 1):
        f, s = bs[i], bs[i + 1]
        r = s["t"] / f["t"]
        vals = []
        for frac in (0.20, 0.35, 0.50, 0.65, 0.80):
            y = int(H * frac) - T // 2
            x = W // 2 - T // 2
            fy = int(round(geo[i][0] * y + geo[i][1]))
            sy = int(round(geo[i + 1][0] * y + geo[i + 1][1]))
            a = f["arr"][fy:fy+T, x:x+T].astype(np.float32)
            b = s["arr"][sy:sy+T, x:x+T].astype(np.float32)
            m = (a < SAT_GUARD) & (b < SAT_GUARD) & (b > a + 200)   # real signal only
            if m.sum() > 5000:
                vals.append(np.median((b[m] - r * a[m]) / (1.0 - r)))
        if vals:
            p = float(np.median(vals))
            ests.append(p)
            print(f"  {f['name']} vs {s['name']} (ratio {r:.3f}): P = {p:7.1f}  "
                  f"(tiles {min(vals):.0f}..{max(vals):.0f})")
    if not ests:
        sys.exit("could not fit a black level - no usable overlap")
    P = float(np.median(ests))
    print(f"  -> using P = {P:.1f}   (pair spread {max(ests)-min(ests):.1f} counts)")
    return P


def merge(bs, geo, W, P, out_path):
    # The output grid has to land inside every bracket at BOTH ends. A negative
    # fitted offset puts the source row below 0 near the top, and a negative
    # numpy slice start wraps to the end of the file — which yields an empty
    # slab rather than an error, so the failure surfaced far from its cause.
    # Start the grid at the first reference row every bracket can supply.
    top = 0
    for (s, o) in geo:
        top = max(top, int(np.ceil(-o / s)) if o < 0 else 0)
    end = min(int((b["h"] - 2 - o) / s) for b, (s, o) in zip(bs, geo))
    end = min(end, bs[0]["h"])
    H = end - top
    if H < 16:
        sys.exit(f"no usable overlap between brackets (top={top}, end={end})")
    if top:
        print(f"  (skipping the first {top} line(s): not present in every bracket)")
    t_max = max(b["t"] for b in bs)
    t_min = min(b["t"] for b in bs)
    scale = t_max / (SAT - P)          # 1.0 = the slowest bracket's clipping point
    print(f"\nmerging {len(bs)} brackets -> {W} x {H}")

    out = tifffile.memmap(out_path, shape=(H, W), dtype=np.float32,
                          photometric="minisblack", bigtiff=True)
    all_clipped = rescued = 0
    for y0 in range(0, H, CHUNK):
        y1 = min(y0 + CHUNK, H)
        # Output row y comes from REFERENCE row y+top; `top` is what keeps every
        # bracket's source index non-negative.
        rows = np.arange(y0, y1, dtype=np.float64) + top
        num = np.zeros((y1 - y0, W), np.float32)
        den = np.zeros((y1 - y0, W), np.float32)
        for b, (s, o) in zip(bs, geo):
            src = rows * s + o
            i0 = np.floor(src).astype(np.int64)
            wgt = (src - i0).astype(np.float32)[:, None]
            # Belt and braces: a stray index here would slice from the end of the
            # file and fail somewhere unrelated, so clamp and say so instead.
            if i0.min() < 0 or i0.max() + 1 >= b["h"]:
                sys.exit(f"{b['name']}: source rows {i0.min()}..{i0.max()+1} "
                         f"outside 0..{b['h']-1} - geometry fit is wrong")
            lo, hi = int(i0.min()), int(i0.max()) + 2
            slab = b["arr"][lo:hi, :W].astype(np.float32)
            r0 = slab[i0 - lo]
            r1 = slab[i0 + 1 - lo]
            # A pixel is usable only if BOTH source rows are unclipped - blending a
            # clipped row with a good one would invent a plausible mid-grey.
            good = (r0 < SAT_GUARD) & (r1 < SAT_GUARD)
            raw = r0 * (1.0 - wgt) + r1 * wgt
            num += np.where(good, raw - P, 0.0)
            den += np.where(good, np.float32(b["t"]), np.float32(0.0))
        dead = den <= 0
        all_clipped += int(dead.sum())
        rad = np.where(dead, (SAT - P) / t_min, num / np.maximum(den, 1e-12))
        chunk = (rad * scale).astype(np.float32)
        rescued += int((chunk > 1.0).sum())
        out[y0:y1] = chunk
        print(f"  rows {y0:6d}-{y1:6d}", end="\r")
    out.flush()
    px = H * W
    print(f"\nwrote {out_path}  ({os.path.getsize(out_path)/1e6:.0f} MB, 32-bit float)")
    print(f"  above slowest-bracket clipping : {rescued:,} px ({100.0*rescued/px:.2f}%)")
    print(f"  clipped in every bracket       : {all_clipped:,} px ({100.0*all_clipped/px:.4f}%)")
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
    ry = int(round(geo[0][0] * y + geo[0][1]))
    a = ref["arr"][ry:ry+T, x:x+T].astype(np.float32)
    for b, (s, o) in list(zip(bs, geo))[1:]:
        by = int(round(s * y + o))
        c = b["arr"][by:by+T, x:x+T].astype(np.float32)
        m = (a < SAT_GUARD) & (c < SAT_GUARD) & (a > P + 300)
        if m.sum() < 5000:
            print(f"  {b['name']}: too little overlap to judge"); continue
        ratio = ((c[m] - P) / b["t"]) / ((a[m] - P) / ref["t"])
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
    P = fit_black(bs, geo)
    check_agreement(bs, geo, P)

    os.makedirs(args.out, exist_ok=True)
    # Name from the scan numbers, not from the arguments: the Suite passes full
    # paths, which would otherwise end up in the filename.
    labels = []
    for p in paths:
        m = re.search(r"scan_(\d+)", os.path.basename(p))
        labels.append(m.group(1) if m else os.path.splitext(os.path.basename(p))[0])
    stem = "hdr_" + "_".join(labels)
    out_path = os.path.join(args.out, stem + ".tif")
    out = merge(bs, geo, W, P, out_path)
    preview(out, os.path.join(args.out, stem + "_preview.tif"))


if __name__ == "__main__":
    main()
