# Usage: python cam_raw.py "gcp" ["gla 1 8192" ...]   (needs the agent's raw pass-through)
# Sends allowlisted camera serial commands through the capture agent's :5521
# settings bus (the agent owns COM3) and prints each reply. Used for flat-field
# calibration, checklist §7: ccf / ccp / wfc / wpc / epc / wus / gla / gcp.
import json, socket, sys
HOST = "127.0.0.1"; PORT = 5521
s = socket.create_connection((HOST, PORT), timeout=150); f = s.makefile("r")
for line in sys.argv[1:]:
    s.sendall((json.dumps({"cmd": "raw", "line": line}) + "\n").encode())
    for msg in f:
        m = json.loads(msg)
        if m.get("ack") == "raw": break      # skip state broadcasts from other clients' sets
    print("> %s  [ok=%s]" % (line, m.get("ok")))
    print(m.get("reply", "(no reply field - agent without the raw pass-through?)").strip())
s.close()
