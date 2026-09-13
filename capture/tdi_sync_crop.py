# Usage: python tdi_sync_crop.py scan_A.tif LPD_A scan_B.tif LPD_B ...
# Crops the same patch (BIN_LINE/BIN_COL, located at REF_LPD) from each scan at equal angular size,
# scores it, and writes bin_compare.png next to this script.
import struct, zlib, sys, numpy as np
def tiff(fn):
    f = open(fn, "rb"); f.seek(4); off = struct.unpack("<I", f.read(4))[0]
    f.seek(off); n = struct.unpack("<H", f.read(2))[0]; t = {}
    for _ in range(n):
        tag, typ, cnt, val = struct.unpack("<HHII", f.read(12)); t[tag] = val & 0xFFFF if typ == 3 else val
    return t[256], t[257], t[273]
def png(fn, a):
    h, w = a.shape
    raw = b"".join(b"\x00" + a[y].tobytes() for y in range(h))
    ch = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    open(fn, "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw, 6)) + ch(b"IEND", b""))
# (file, lines/deg, label); bin centre found in 1817's display preview
REF_LPD, BIN_LINE, BIN_COL, HALF = 149.5, 10192, 4571, 300
crops = []
for fn, lpd in [(sys.argv[i], float(sys.argv[i+1])) for i in range(1, len(sys.argv), 2)]:
    w, h, off = tiff("D:/capture/" + fn)
    img = np.memmap("D:/capture/" + fn, dtype="<u2", mode="r", offset=off, shape=(h, w))
    k = lpd / REF_LPD
    l0, l1 = int((BIN_LINE - HALF) * k), int((BIN_LINE + HALF) * k)
    c = np.asarray(img[l0:l1, BIN_COL - HALF:BIN_COL + HALF]).astype(np.float64) / 16
    # resample along scan to the 149.5 grid (box) so every crop is the same angular size
    idx = np.linspace(0, c.shape[0], 2 * HALF + 1)
    cs = np.concatenate([np.zeros((1, c.shape[1])), np.cumsum(c, 0)])
    C = np.array([np.interp(idx, np.arange(cs.shape[0]), cs[:, j]) for j in range(c.shape[1])]).T
    r = (C[1:] - C[:-1]) / (idx[1] - idx[0])
    lo, hi = np.percentile(r, 1), np.percentile(r, 99.7)
    d = np.clip((r - lo) / (hi - lo), 0, 1) ** 0.6
    # display orientation = (line -> x, column -> y)
    crops.append((fn, lpd, (d.T * 255).astype(np.uint8)))
    ga = np.diff(r, axis=0); gc = np.diff(r, axis=1)
    print("%s lpd %.1f  bin score %.3f" % (fn, lpd, (ga**2).mean() / (gc**2).mean()))
sep = np.full((2 * HALF, 8), 255, np.uint8)
png(sys.argv[0].replace("crop.py", "bin_compare.png"), np.hstack(sum([[c[2], sep] for c in crops], [])[:-1]))
