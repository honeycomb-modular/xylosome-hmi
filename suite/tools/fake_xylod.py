#!/usr/bin/env python3
"""fake_xylod — minimal xylod protocol emulator for suite UI development.

Speaks just enough of beckhoff/PROTOCOL.md: welcome, 10 Hz status,
pass_start/pass_end/seq_done. Runs a 4-pass sequence every 15 s, forever.
No dependencies.

Usage:
    python3 fake_xylod.py                     # daemon only (listens on :5510)
    python3 fake_xylod.py --write-files DIR   # also play capture PC: writes a
                                              # small valid TIFF into DIR ~2 s
                                              # after each pass ends
"""
import json, os, socket, struct, sys, threading, time

PORT = 5510
PASS_S = 6.0        # seconds per pass
GAP_S = 2.0         # filter/settle gap between passes
IDLE_S = 15.0       # idle time between sequences
FILTERS = ["R", "G", "B", "C"]

clients = []
lock = threading.Lock()
t0 = time.monotonic()
WRITE_DIR = None
if "--write-files" in sys.argv:
    WRITE_DIR = sys.argv[sys.argv.index("--write-files") + 1]
    os.makedirs(WRITE_DIR, exist_ok=True)
seq_no = 0

def write_tiff(name, w=256, h=160, shade=128):
    """Minimal valid grayscale TIFF — enough for the watcher and, later,
    the ingest pipeline to chew on. Written via temp name + rename."""
    px = bytes([min(255, max(0, shade + ((x ^ y) % 64) - 32))
                for y in range(h) for x in range(w)])
    entries = [(256, 3, w), (257, 3, h), (258, 3, 8), (259, 3, 1),
               (262, 3, 1), (273, 4, 8 + 2 + 12 * 8 + 4), (277, 3, 1),
               (278, 3, h), (279, 4, len(px))]
    ifd = struct.pack("<H", len(entries))
    for tag, typ, val in entries:
        ifd += struct.pack("<HHI", tag, typ, 1) + struct.pack("<I", val)
    ifd += struct.pack("<I", 0)
    data = struct.pack("<2sHI", b"II", 42, 8) + ifd + px
    tmp = os.path.join(WRITE_DIR, "." + name + ".part")
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, os.path.join(WRITE_DIR, name))
    print("wrote", name)

def capture_pc(seq, p, f):
    """Simulated capture PC: file lands a moment after the pass ends."""
    time.sleep(2.0)
    write_tiff(f"scan_{seq:04d}_p{p}_{f}.tif", shade=80 + 40 * p)

def _catmull_rom(pts, seg=32):
    """Same spline the Pi draws (evalCatmullRom)."""
    if len(pts) < 2:
        return pts
    ext = [pts[0]] + pts + [pts[-1]]
    out = []
    for i in range(len(ext) - 3):
        p0, p1, p2, p3 = ext[i], ext[i+1], ext[i+2], ext[i+3]
        for s in range(seg):
            u = s / seg
            u2, u3 = u*u, u*u*u
            out.append(tuple(
                0.5 * ((2*p1[k]) + (-p0[k]+p2[k])*u
                       + (2*p0[k]-5*p1[k]+4*p2[k]-p3[k])*u2
                       + (-p0[k]+3*p1[k]-3*p2[k]+p3[k])*u3)
                for k in (0, 1)))
    out.append(pts[-1])
    return out

def write_meta_svg(seq):
    """Fake MetadataRecorder export — a 1:1 port of the Pi's buildSvg():
    Courier, black + #555555 only, transparent ground, edge-tiled boxes,
    ruled table rows, dashed zero axis, Catmull-Rom curve, params footer."""
    time.sleep(3.0)
    from datetime import datetime
    ts = datetime.now()
    name = f"xylosome_{ts.strftime('%Y%m%d')}_{ts.strftime('%H%M%S')}.svg"
    FM = "Courier New, Courier, monospace"
    BLK, DIM = "#000000", "#555555"
    fz, lh, pad, vpad = 13, 20, 8, 6
    c = [20, 26, 84, 84, 62, 36]                      # column widths
    tblW = sum(c) + pad * 2                            # 328
    tblH = 5 * lh + vpad * 2                           # 112
    crvW, hdrH, prmH = 240, 44, 44
    W = tblW + crvW                                    # 568
    H = hdrH + tblH + prmH                             # 200
    yMain, yPrm = hdrH, hdrH + tblH
    o = []
    def txt(x, y, s, fill=BLK, anc="start", size=fz, extra=""):
        o.append(f'<text x="{x}" y="{y}" font-family="{FM}" font-size="{size}" '
                 f'{extra}fill="{fill}" text-anchor="{anc}">{s}</text>')
    def box(x, y, w, h):
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" '
                 f'fill="none" stroke="{BLK}" stroke-width="1"/>')
    def rule(x, y, w):
        o.append(f'<line x1="{x}" y1="{y}" x2="{x+w}" y2="{y}" '
                 f'stroke="{DIM}" stroke-width="0.5"/>')
    # 1. header
    box(0, 0, W, hdrH)
    txt(pad, 29, "XYLOSOME_01", BLK, "start", 20, 'letter-spacing="1" ')
    txt(W - pad, 29, ts.strftime("%Y-%m-%d  %H:%M:%S.") + f"{ts.microsecond//1000:03d}",
        DIM, "end")
    # 2a. timing table
    box(0, yMain, tblW, tblH)
    xs = [pad]
    for w in c[:-1]:
        xs.append(xs[-1] + w)
    lblY = yMain + vpad + fz
    for x, s in zip(xs, ["#", "ch", "t_start", "t_end", "duration", "ms"]):
        txt(x, lblY, s, DIM)
    rule(0, lblY + 4, tblW)
    for i, ch in enumerate("RGBC"):
        t0, dur = i * 8000, 6000 + i * 4
        ry = lblY + 4 + (i + 1) * lh
        f_ = lambda ms: f"{ms//60000:02d}:{(ms%60000)//1000:02d}.{ms%1000:03d}"
        for x, s, col in zip(xs, [str(i+1), ch, f_(t0), f_(t0+dur),
                                  f"{dur/1000:.3f}s", str(dur)],
                             [DIM, BLK, BLK, BLK, BLK, DIM]):
            txt(x, ry, s, col)
        if i < 3:
            rule(0, ry + 4, tblW)
    # 2b. curve box — dashed zero axis + catmull-rom
    box(tblW, yMain, crvW, tblH)
    gP = 10
    giX, giY, giW, giH = tblW + gP, yMain + gP, crvW - gP*2, tblH - gP*2
    zy = giY + giH // 2
    o.append(f'<line x1="{giX}" y1="{zy}" x2="{giX+giW}" y2="{zy}" '
             f'stroke="{DIM}" stroke-width="0.5" stroke-dasharray="3,4"/>')
    nodes = [(0.0, 0.85), (0.3, 0.25), (0.65, 0.15), (1.0, 0.7)]
    pts = _catmull_rom([(nx*giW, ny*giH) for nx, ny in nodes])
    o.append('<polyline fill="none" stroke="' + BLK +
             '" stroke-width="1" stroke-linejoin="round" points="' +
             " ".join(f"{giX+x:.1f},{giY+y:.1f}" for x, y in pts) + '"/>')
    # 3. params footer
    box(0, yPrm, W, prmH)
    txt(pad, yPrm + vpad + 11,
        "n: " + " ".join(f"({nx:.2f},{ny:.2f})" for nx, ny in nodes),
        DIM, "start", 11)
    txt(pad, yPrm + vpad + 27, "box_w 480  aspect 1.778  lines 14222",
        DIM, "start", 11)
    svg = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">\n' + "\n".join(o) + "\n</svg>\n")
    tmp = os.path.join(WRITE_DIR, "." + name + ".part")
    with open(tmp, "w") as fh:
        fh.write(svg)
    os.replace(tmp, os.path.join(WRITE_DIR, name))
    print("wrote", name)

state = {"state": "idle", "pass": -1, "progress": 0.0, "posDeg": 0.0,
         "velDegS": 0.0, "lineHz": 0.0, "estopOk": True,
         "op": True, "enabled": True, "homed": True, "filterSlot": 0,
         "drive": {"sw": 4663, "fault": 0}, "echo": 0}

def send(sock, obj):
    try:
        sock.sendall((json.dumps(obj) + "\n").encode())
    except OSError:
        with lock:
            if sock in clients:
                clients.remove(sock)

def broadcast(obj):
    with lock:
        targets = list(clients)
    for c in targets:
        send(c, obj)

def tms():
    return int((time.monotonic() - t0) * 1000)

def status_loop():
    while True:
        broadcast(dict(state, ev="status"))
        time.sleep(0.1)

def sequence_loop():
    global seq_no
    while True:
        time.sleep(IDLE_S)
        seq_no += 1
        for p, f in enumerate(FILTERS):
            state["state"] = "filter"
            state["pass"] = p
            state["progress"] = 0.0
            time.sleep(GAP_S * 0.6)
            state["state"] = "settle"
            time.sleep(GAP_S * 0.4)
            broadcast({"ev": "pass_start", "pass": p, "filter": f, "tMs": tms()})
            state["state"] = "running"
            steps = int(PASS_S / 0.05)
            for i in range(steps):
                x = (i + 1) / steps
                tri = 1 - abs(2 * x - 1)          # triangle speed profile
                state["progress"] = x
                state["posDeg"] = 30.0 * x
                state["velDegS"] = 60.0 * (0.2 + 0.8 * tri)
                state["lineHz"] = 5000.0 * (0.2 + 0.8 * tri)
                time.sleep(0.05)
            broadcast({"ev": "pass_end", "pass": p, "tMs": tms()})
            if WRITE_DIR:
                threading.Thread(target=capture_pc, args=(seq_no, p, f), daemon=True).start()
        state.update(state="idle", progress=0.0, posDeg=0.0, velDegS=0.0, lineHz=0.0)
        state["pass"] = -1
        broadcast({"ev": "seq_done", "passes": 4})
        if WRITE_DIR:
            threading.Thread(target=write_meta_svg, args=(seq_no,), daemon=True).start()

def serve():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen()
    print(f"fake_xylod listening on :{PORT} — sequence every {IDLE_S:.0f}s")
    while True:
        c, addr = srv.accept()
        print("client", addr)
        with lock:
            clients.append(c)
        send(c, {"ev": "welcome", "version": "fake-0.1", "sim": True})
        threading.Thread(target=drain, args=(c,), daemon=True).start()

def drain(c):
    """Read and ignore client commands (hello/status etc.)."""
    try:
        while c.recv(4096):
            pass
    except OSError:
        pass

threading.Thread(target=status_loop, daemon=True).start()
threading.Thread(target=sequence_loop, daemon=True).start()
serve()
