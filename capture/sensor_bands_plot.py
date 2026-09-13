# Usage: python sensor_bands_plot.py   (reads ./bandprof.npy, writes ./band_profile.png)
import struct, zlib, numpy as np
S = "./"
def png(fn, a):
    h, w = a.shape[:2]; rgb = a.ndim == 3
    raw = b"".join(b"\x00" + a[y].tobytes() for y in range(h))
    ch = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    open(fn, "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2 if rgb else 0, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw, 6)) + ch(b"IEND", b""))
P = np.load(S + "bandprof.npy") * 100          # (nscans, 8192) percent deviation
avg = P.mean(axis=0)
W, H = 1638, 300
img = np.full((H, W, 3), 255, np.uint8)
def plot(y0, h, xs, ys, lo, hi, col):
    px = ((xs - xs[0]) / (xs[-1] - xs[0]) * (W - 1)).astype(int)
    py = (y0 + h - 1 - (np.clip(ys, lo, hi) - lo) / (hi - lo) * (h - 1)).astype(int)
    for i in range(len(px) - 1):
        a, b = sorted((py[i], py[i + 1])); img[a:b + 1, px[i]:px[i] + 2] = col
# panel 1: whole sensor, 5-col bins so single-column spikes stay visible
xs = np.arange(0, 8192, 5); ys = np.array([avg[i:i+5][np.argmax(np.abs(avg[i:i+5]))] for i in xs])
img[140, :] = 200; plot(0, 140, xs, ys, -7, 7, (40, 40, 40))
for c in (2048, 4096, 6144): img[0:140, int(c / 8191 * (W - 1))] = (0, 120, 255)
# panel 2: columns 2300-2520 zoom, each scan in a colour
cols = [(220, 60, 60), (60, 160, 60), (60, 60, 220), (200, 140, 0)]
xs = np.arange(2300, 2521)
img[160 + 70, :] = 200
for k in range(P.shape[0]): plot(160, 140, xs, P[k, 2300:2521], -8, 8, cols[k])
png(S + "band_profile.png", img)
print("ok")
