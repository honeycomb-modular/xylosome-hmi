#!/usr/bin/env python3
"""fake_capture_agent — live-focus protocol emulator (suite/LIVE_PROTOCOL.md).

Streams synthetic camera lines on :5520 whose sharpness drifts slowly, as if
someone were hunting focus — the suite's waterfall crispens/softens and the
focus metric climbs and falls. No dependencies.

Usage:  python3 fake_capture_agent.py
"""
import json, math, random, socket, struct, threading, time

PORT = 5520
W = 1024          # downsampled line width served to the suite
LINES_PER_BLOCK = 8
BLOCK_HZ = 15     # blocks/s → 120 lines/s

def make_scene(width):
    """A fixed 1-D scene with fine detail: bars, edges, texture."""
    px = [0.0] * width
    rnd = random.Random(7)
    for x in range(width):
        v = 0.35
        v += 0.25 * (1 if (x // 6) % 2 == 0 else -1) * math.exp(-((x - 300) / 180) ** 2)
        v += 0.30 * (1 if (x // 2) % 2 == 0 else -1) * math.exp(-((x - 700) / 90) ** 2)
        v += 0.15 * math.sin(x / 3.1) * math.exp(-((x - 512) / 300) ** 2)
        v += rnd.uniform(-0.03, 0.03)
        px[x] = min(1.0, max(0.0, v))
    return px

SCENE = make_scene(W)

def blurred(scene, radius):
    if radius < 1:
        return scene[:]
    out = []
    r = int(radius)
    for x in range(len(scene)):
        a = max(0, x - r)
        b = min(len(scene), x + r + 1)
        out.append(sum(scene[a:b]) / (b - a))
    return out

def focus_metric(line):
    g = [abs(line[i + 1] - line[i]) for i in range(len(line) - 1)]
    return math.sqrt(sum(v * v for v in g) / len(g))

# metric at perfect focus, for normalization
PEAK = focus_metric(SCENE)

def serve_client(c):
    try:
        c.sendall((json.dumps({"ev": "welcome", "version": "fake-0.1",
                               "camera": "Piranha 8K", "sim": True}) + "\n").encode())
        buf = b""
        streaming = False
        t0 = time.monotonic()
        c.settimeout(0.02)
        while True:
            try:
                data = c.recv(4096)
                if not data:
                    return
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    m = json.loads(line)
                    if m.get("cmd") == "live_start":
                        streaming = True
                        print("live_start")
                    elif m.get("cmd") == "live_stop":
                        streaming = False
                        c.sendall(b'{"ev":"live_stopped"}\n')
                        print("live_stop")
            except socket.timeout:
                pass
            if not streaming:
                time.sleep(0.05)
                continue

            # slow focus hunt: blur radius oscillates 0..12 px
            t = time.monotonic() - t0
            radius = 6 + 6 * math.sin(t / 5.0) + random.uniform(-0.5, 0.5)
            radius = max(0.0, radius)
            line = blurred(SCENE, radius)
            focus = min(1.0, focus_metric(line) / PEAK)

            noisy = bytes(
                min(255, max(0, int(v * 255 + random.uniform(-6, 6))))
                for v in line)
            payload = noisy * LINES_PER_BLOCK
            hdr = json.dumps({"ev": "lines", "count": LINES_PER_BLOCK,
                              "width": W, "bytes": len(payload),
                              "focus": round(focus, 4),
                              "tMs": int(t * 1000)}) + "\n"
            try:
                c.sendall(hdr.encode() + payload)
            except OSError:
                return
            time.sleep(1.0 / BLOCK_HZ)
    finally:
        c.close()

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", PORT))
srv.listen()
print(f"fake_capture_agent listening on :{PORT}")
while True:
    conn, addr = srv.accept()
    print("client", addr)
    threading.Thread(target=serve_client, args=(conn,), daemon=True).start()
