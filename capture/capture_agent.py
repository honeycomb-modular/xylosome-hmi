#!/usr/bin/env python3
# capture_agent.py - Xylosome capture agent, phase 1 (camera SETTINGS bus).
#
# Camera control/status over TCP (newline-delimited JSON), applied to the
# Piranha HS-80-08K80 via the grabber serial port (COM3, 9600-8N1).
# No Sapera / no image path yet - settings only. This is the "camera bus"
# peer of xylod's motion bus; HMI and Suite connect to both.
#
# Protocol: capture/PROTOCOL.md   (port 5521)
#
# Run:  python capture_agent.py         (PREREQ: CamExpert closed - COM3 single-occupant)

import json, socket, threading, re, sys, time
import serial  # pyserial

PORT_TCP = 5521
COM      = "COM3"
BAUD     = 9600

# --- serial layer ----------------------------------------------------------
ser_lock = threading.Lock()
ser = None

def cam_cmd(cmd):
    """Send one TLC command over COM3, return the reply text (up to 'OK>')."""
    with ser_lock:
        ser.reset_input_buffer()
        ser.write((cmd + "\r").encode())
        buf = ""
        deadline = time.time() + 3
        while time.time() < deadline:
            chunk = ser.read(4096).decode(errors="replace")
            if chunk:
                buf += chunk
                if buf.rstrip().endswith("OK>"):
                    break
    return buf

def field(text, label):
    for line in text.splitlines():
        m = re.search(re.escape(label) + r"\s*:\s*(.+?)\s*$", line)
        if m:
            return m.group(1).strip()
    return None

def read_state():
    g = cam_cmd("gcp")
    sync   = field(g, "SYNC Frequency")
    gain   = field(g, "Analog Gain (dB)")
    stages = field(g, "Stage Selection")
    return {
        "line.rate":  float(re.sub(r"[^\d.]", "", sync)) if sync else None,
        "tdi.stages": int(stages) if stages else None,
        "gain":       gain.split()[0] if gain else None,   # first tap; 'sag 0' sets all
        "scan.dir":   field(g, "CCD Direction") or "",
        "model":      field(g, "Camera Model No."),
        "clm":        field(g, "Camera Link Mode"),
    }

# --- validate + apply one param --------------------------------------------
STAGES = {16, 32, 48, 64, 80, 96}

def apply_set(key, value):
    """Validate and apply one param. Returns (ok, note)."""
    if key == "tdi.stages":
        v = int(value)
        if v not in STAGES:
            return False, "stages must be one of %s" % sorted(STAGES)
        cam_cmd("stg %d" % v); return True, "ok"
    if key == "line.rate":
        v = float(value)
        if not (3500 <= v <= 68610):
            return False, "line rate 3500..68610 Hz"
        cam_cmd("ssf %d" % int(v)); return True, "ok"
    if key == "gain":
        v = float(value)
        if not (-10 <= v <= 10):
            return False, "gain -10..10 dB"
        cam_cmd("sag 0 %s" % v); return True, "ok"
    if key == "scan.dir":
        s = str(value).lower()
        if s in ("forward", "fwd", "0"): cam_cmd("scd 0"); return True, "ok"
        if s in ("reverse", "rev", "1"): cam_cmd("scd 1"); return True, "ok"
        return False, "scan.dir forward|reverse"
    return False, "unknown key %s" % key

# --- TCP broadcast server --------------------------------------------------
clients = set()
clients_lock = threading.Lock()

def send(conn, obj):
    try:
        conn.sendall((json.dumps(obj) + "\n").encode())
    except OSError:
        pass

def broadcast(obj):
    with clients_lock:
        for c in list(clients):
            send(c, obj)

def handle(conn, addr):
    with clients_lock:
        clients.add(conn)
    print("client connected:", addr)
    f = conn.makefile("r")
    try:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                send(conn, {"ack": "?", "ok": False, "error": "bad json"}); continue
            print("recv from %s: %s" % (addr, msg))
            cmd = msg.get("cmd")
            if cmd == "hello":
                send(conn, {"ev": "welcome", "camera": read_state().get("model"), "version": "0.1"})
            elif cmd == "get":
                send(conn, dict({"ev": "state"}, **read_state()))
            elif cmd == "set":
                key, val = msg.get("key"), msg.get("value")
                ok, note = apply_set(key, val)
                print("  set %s=%s -> ok=%s (%s)" % (key, val, ok, note))
                send(conn, {"ack": "set", "ok": ok, "key": key, "value": val, "note": note})
                if ok:
                    broadcast(dict({"ev": "state"}, **read_state()))
            else:
                send(conn, {"ack": cmd, "ok": False, "error": "unknown cmd"})
    except (OSError, ConnectionError):
        pass  # client hung up mid-read; normal teardown
    finally:
        with clients_lock:
            clients.discard(conn)
        conn.close()
        print("client gone:", addr)

def main():
    global ser
    try:
        ser = serial.Serial(COM, BAUD, timeout=0.3)
    except serial.SerialException as e:
        print("Could not open %s (CamExpert holding it?): %s" % (COM, e)); sys.exit(1)
    print("Camera serial open on %s. State: %s" % (COM, read_state()))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT_TCP)); srv.listen(8)
    print("Capture agent (camera bus) listening on :%d  (Ctrl+C to stop)" % PORT_TCP)
    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=handle, args=(conn, addr), daemon=True).start()
    except KeyboardInterrupt:
        print("shutting down")
    finally:
        ser.close(); srv.close()

if __name__ == "__main__":
    main()
