"""Embed the Suite's profile view into a merged TIFF as an ICC profile.

usage: python -I view_icc.py <RGB16.tif> --profile <colour_profile.json>
           [--black chart|sensor] [--toe 0.01] [--offset 0.0] [--trim-thirds 0]
           [--exposure captured|chart] [--icc-out view.icc] [--no-embed]

The Suite shows a merged scan through the chart profile (View > Colour
profile): per channel a black point (the chart's black patch or the
sensor's zero, plus an offset) softened by a toe, then the chart-fitted 3x3
with the white-balance gains and exposure, then sRGB for the screen. The
TIFF itself stays linear camera RGB with no profile, so Photoshop assigns
its working space to it and shows something else entirely.

An ICC matrix/TRC profile expresses exactly that pipeline: one 1D curve per
channel (here: the black point and toe, as a 16-bit table), then a 3x3 to
XYZ (here: the chart matrix, gains and exposure, taken on to D50 through
the sRGB primaries). Photoshop opens the file with the profile embedded and
renders it as the Suite does - through the monitor's own profile rather
than assuming an sRGB screen, which is the one thing it does better.

The profile is written into the TIFF in place: the ICC bytes and a fresh
IFD are appended and the header is pointed at the new IFD. The pixel data
and every other tag are untouched (the old IFD is left behind, a few
hundred bytes). Re-run after a merge or a change of view; the tag is
replaced, not duplicated. Classic and BigTIFF, either byte order.

The curve formulas mirror shaders/wb.frag and Main.qml (viewMatrix,
viewPedestal, cpToe) - change them together.
"""
import json
import os
import struct
import sys
import time

import numpy as np

argv = sys.argv[1:]


def opt(name, default=None):
    if name in argv:
        i = argv.index(name)
        return argv[i + 1]
    return default


VALUED = {"--profile", "--black", "--toe", "--offset", "--trim-thirds", "--exposure", "--icc-out"}
pos = [a for i, a in enumerate(argv) if not a.startswith("--") and (i == 0 or argv[i - 1] not in VALUED)]
if not pos or not opt("--profile"):
    sys.exit(__doc__)
src = pos[0]
p = json.load(open(opt("--profile")))
black = opt("--black", "chart")
toe = float(opt("--toe", "0.01"))
offset = float(opt("--offset", "0"))
trim_thirds = int(opt("--trim-thirds", "0"))
as_captured = opt("--exposure", "captured") != "chart"
icc_out = opt("--icc-out")

gain = np.array(p["gain"], np.float64)
M = np.array(p["matrix"], np.float64)
exposure = float(p["exposure"])
pedestal = np.array(p["pedestal"], np.float64) / 65535.0
chart_black = np.array(p.get("chartBlack") or p["pedestal"], np.float64) / 65535.0

# ── the view, as Main.qml computes it ─────────────────────────────────────────
e = 1.0 if as_captured else exposure
e_mat = e * 2.0 ** (trim_thirds / 3.0) / (1.0 - offset)
cm = M * gain[None, :] * e_mat                                   # camera -> linear sRGB
base = chart_black if (black == "chart" and "chartBlack" in p) else pedestal
ped = base + offset / np.maximum(0.01, gain * e)                # viewPedestal
knee = toe

N = 16384
x = np.linspace(0.0, 1.0, N)
curves = []
for c in range(3):
    lin = x - ped[c]
    if knee > 0:
        t = ped[c] + knee
        y = np.where(x <= t, knee * np.power(x / t, t / knee), lin)
    else:
        y = np.maximum(lin, 0.0)
    curves.append(np.clip(y, 0.0, 1.0))

# linear sRGB -> XYZ, D50 (Bradford), the colorants ICC wants
SRGB_TO_XYZ_D50 = np.array([[0.4360747, 0.3850649, 0.1430804],
                            [0.2225045, 0.7168786, 0.0606169],
                            [0.0139322, 0.0971045, 0.7141733]])
colorants = SRGB_TO_XYZ_D50 @ cm                               # columns: r, g, b in XYZ


# ── ICC v2 matrix/TRC profile ─────────────────────────────────────────────────
def s15f16(v):
    return struct.pack(">i", int(round(v * 65536.0)))


def tag_xyz(xyz):
    return b"XYZ " + b"\0\0\0\0" + b"".join(s15f16(v) for v in xyz)


def tag_curv(lut):
    q = np.clip(np.round(lut * 65535.0), 0, 65535).astype(">u2")
    return b"curv" + b"\0\0\0\0" + struct.pack(">I", len(q)) + q.tobytes()


def tag_desc(text):
    a = text.encode("ascii", "replace") + b"\0"
    return (b"desc" + b"\0\0\0\0" + struct.pack(">I", len(a)) + a
            + struct.pack(">II", 0, 0) + struct.pack(">HB", 0, 0) + b"\0" * 67)


def tag_text(text):
    return b"text" + b"\0\0\0\0" + text.encode("ascii", "replace") + b"\0"


desc = "Xylosome view: %s black%s, toe %.2f%%, %s%s" % (
    "chart" if black == "chart" else "sensor-zero",
    (" +%.1f%%" % (offset * 100)) if offset else "",
    toe * 100,
    "as captured" if as_captured else "normalised to chart",
    ("" if trim_thirds == 0 else " %+d/3 stop" % trim_thirds))
tags = [
    (b"desc", tag_desc(desc)),
    (b"cprt", tag_text("Xylosome Suite, generated from colour_profile.json")),
    (b"wtpt", tag_xyz((0.9642, 1.0, 0.8249))),
    (b"rXYZ", tag_xyz(colorants[:, 0])),
    (b"gXYZ", tag_xyz(colorants[:, 1])),
    (b"bXYZ", tag_xyz(colorants[:, 2])),
    (b"rTRC", tag_curv(curves[0])),
    (b"gTRC", tag_curv(curves[1])),
    (b"bTRC", tag_curv(curves[2])),
]
table = b""
data = b""
off = 128 + 4 + 12 * len(tags)
for sig, body in tags:
    while (off + len(data)) % 4:
        data += b"\0"
    table += sig + struct.pack(">II", off + len(data), len(body))
    data += body
body = struct.pack(">I", len(tags)) + table + data
tm = time.gmtime()
header = struct.pack(">I", 128 + len(body)) + b"\0\0\0\0" + struct.pack(">I", 0x02100000)
header += b"mntr" + b"RGB " + b"XYZ "
header += struct.pack(">6H", tm.tm_year, tm.tm_mon, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
header += b"acsp" + b"MSFT" + struct.pack(">I", 0) + b"xylo" + b"\0\0\0\0"
header += struct.pack(">Q", 0) + struct.pack(">I", 0)
header += s15f16(0.9642) + s15f16(1.0) + s15f16(0.8249)
header += b"xylo" + b"\0" * 16 + b"\0" * 28
assert len(header) == 128
icc = header + body
print("ICC: %d bytes, %s" % (len(icc), desc))
print("     curves: black at %.2f%% / %.2f%% / %.2f%% of full scale, knee %.2f%%"
      % (ped[0] * 100, ped[1] * 100, ped[2] * 100, knee * 100))
print("     colorant sum (white) XYZ %.4f %.4f %.4f (D50 = 0.9642 1.0000 0.8249)" % tuple(colorants.sum(axis=1)))
if icc_out:
    with open(icc_out, "wb") as f:
        f.write(icc)
    print("wrote", icc_out)
if "--no-embed" in argv:
    sys.exit(0)


# ── embed: append the bytes and a fresh IFD, repoint the header ───────────────
ICC_TAG = 34675
with open(src, "r+b") as f:
    head = f.read(16)
    bo = {b"II": "<", b"MM": ">"}[head[:2]]
    magic = struct.unpack(bo + "H", head[2:4])[0]
    if magic == 42:
        ifd0 = struct.unpack(bo + "I", head[4:8])[0]
        n_fmt, e_len, o_fmt, o_len, hdr_off = "H", 12, "I", 4, 4
    elif magic == 43:
        ifd0 = struct.unpack(bo + "Q", head[8:16])[0]
        n_fmt, e_len, o_fmt, o_len, hdr_off = "Q", 20, "Q", 8, 8
    else:
        sys.exit("not a TIFF: " + src)
    f.seek(ifd0)
    n = struct.unpack(bo + n_fmt, f.read(struct.calcsize(n_fmt)))[0]
    raw = f.read(e_len * n)
    nxt = f.read(o_len)
    entries = [raw[i * e_len:(i + 1) * e_len] for i in range(n)]
    kept = [e for e in entries if struct.unpack(bo + "H", e[:2])[0] != ICC_TAG]
    replaced = len(kept) != len(entries)

    f.seek(0, os.SEEK_END)
    end = f.tell()
    pad = (-end) % 8
    icc_pos = end + pad
    f.write(b"\0" * pad + icc)
    pad2 = (-(icc_pos + len(icc))) % 8
    ifd_pos = icc_pos + len(icc) + pad2
    if magic == 42:
        new = struct.pack(bo + "HHII", ICC_TAG, 7, len(icc), icc_pos)
    else:
        new = struct.pack(bo + "HHQQ", ICC_TAG, 7, len(icc), icc_pos)
    kept.append(new)
    kept.sort(key=lambda e: struct.unpack(bo + "H", e[:2])[0])
    f.write(b"\0" * pad2 + struct.pack(bo + n_fmt, len(kept)) + b"".join(kept) + nxt)
    f.seek(hdr_off)
    f.write(struct.pack(bo + o_fmt, ifd_pos))
print("%s %d-byte ICC profile in %s" % ("replaced the" if replaced else "embedded a", len(icc), src))
