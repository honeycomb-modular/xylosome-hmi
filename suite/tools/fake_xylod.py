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
