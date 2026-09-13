# Usage: python tdi_sync_sweep.py 145,150,155 out.json 10800   (lines/deg list, output, constant line rate Hz)
# Moves the scan axis 14 -> 158 deg once per value. Cart must be clear.
# Drive xylod directly: one constant-speed single pass per lines/deg value,
# wait for the capture agent to save the TIFF, record the mapping.
import json, re, socket, sys, time
HOST, PORT = "192.168.2.2", 5510
LOG = r"C:\dev\capture_agent.log"
ARC0, ARC1, VEL = 14.0, 158.0, 72.0
vals = [float(v) for v in sys.argv[1].split(",")]
out = sys.argv[2]
RATE = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0   # constant line rate: vel = RATE/lpd

s = socket.create_connection((HOST, PORT), timeout=60)
f = s.makefile("r")
st = {}
def send(o): s.sendall((json.dumps(o) + "\n").encode())
def pump(until, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        line = f.readline()
        if not line: raise SystemExit("xylod closed the connection")
        m = json.loads(line)
        if m.get("ev") == "status": st.update(m)
        if m.get("ev") == "fault": raise SystemExit("FAULT: %s" % m)
        if until(m): return m
    raise SystemExit("timeout waiting (state %s)" % st.get("state"))

send({"cmd": "hello", "client": "claude-sweep"})
pump(lambda m: m.get("ev") == "status", 10)
if st.get("state") != "idle" or st["drive"]["fault"]:
    raise SystemExit("not idle / faulted: %s" % st)
send({"cmd": "enable"})

results = []
for lpd in vals:
    lines = int(round(lpd * (ARC1 - ARC0)))
    vel = RATE / lpd if RATE else VEL
    logpos = open(LOG, "rb").seek(0, 2)
    send({"cmd": "execute", "colorMode": 1, "passes": 1,
          "arcStartDeg": ARC0, "arcEndDeg": ARC1,
          "maxVelDegS": vel, "minVelDegS": vel, "profile": [1.0] * 64,
          "settleMs": 500, "returnVelDegS": 40.0,
          "line": {"mode": "curve", "lines": lines}})
    pump(lambda m: m.get("ev") == "seq_done", 60)
    pump(lambda m: m.get("ev") == "status" and m.get("state") == "idle", 60)
    saved, t0 = None, time.time()
    while not saved and time.time() - t0 < 90:
        with open(LOG, "rb") as lf:
            lf.seek(logpos); txt = lf.read().decode(errors="replace")
        mm = re.search(r"saved (scan_\d+_p0_C\.tif) \| motion (\d+)ms -> (\d+)/(\d+) lines \| peak (\d+)", txt)
        if mm: saved = mm
        else: time.sleep(1)
    if not saved: raise SystemExit("no TIFF saved for lpd %.1f" % lpd)
    r = {"lpd": lpd, "vel": round(vel, 2), "lines": lines, "file": saved.group(1), "got": int(saved.group(3)),
         "motion_ms": int(saved.group(2)), "peak": int(saved.group(5))}
    print(r, flush=True)
    results.append(r)
    json.dump(results, open(out, "w"), indent=1)
