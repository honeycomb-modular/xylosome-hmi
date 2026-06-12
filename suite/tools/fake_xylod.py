#!/usr/bin/env python3
"""fake_xylod — minimal xylod protocol emulator for suite UI development.

Speaks just enough of beckhoff/PROTOCOL.md: welcome, 10 Hz status,
pass_start/pass_end/seq_done. Runs a 4-pass sequence every 15 s, forever.
No dependencies. Usage:  python3 fake_xylod.py  (listens on :5510)
"""
import json, socket, threading, time

PORT = 5510
PASS_S = 6.0        # seconds per pass
GAP_S = 2.0         # filter/settle gap between passes
IDLE_S = 15.0       # idle time between sequences
FILTERS = ["R", "G", "B", "C"]

clients = []
lock = threading.Lock()
t0 = time.monotonic()

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
    while True:
        time.sleep(IDLE_S)
        for p, f in enumerate(FILTERS):
            state.update(state="filter", pass_=None)
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
