# Usage: python tdi_sync_sweep.py 145,150,155 out.json 10800 [--stages 96] [--range 146:153:0.5] [--arc -28:28]
#        (lines/deg list, output, constant line rate Hz; --range replaces the list)
# Moves the scan axis 14 -> 158 deg (or the --arc given) once per value. Cart must be clear.
# Drive xylod directly: one constant-speed single pass per lines/deg value,
# wait for the capture agent to save the TIFF, record the mapping.
#
# --stages N sets the camera's TDI stage count on the capture agent's bus
# (:5521) before the first pass and records it in the output. Smear is
# stages x (lines/deg error), so a sweep at 96 stages has a peak six times
# narrower than one at 16 and pins the value to a fraction of a percent -
# which is also the accuracy 96 stages need to look sharp. Score with
# tdi_sync_score.py --fit.
import json, re, socket, sys, time
HOST, PORT = "192.168.2.2", 5510
CAM_HOST, CAM_PORT = "127.0.0.1", 5521
LOG = r"C:\dev\capture_agent.log"
ARC0, ARC1, VEL = 14.0, 158.0, 72.0
argv = sys.argv[1:]
stages = int(argv[argv.index("--stages") + 1]) if "--stages" in argv else 0
if "--arc" in argv: ARC0, ARC1 = (float(x) for x in argv[argv.index("--arc") + 1].split(":"))
pos = [a for i, a in enumerate(argv) if not a.startswith("--") and (i == 0 or argv[i - 1] not in ("--stages", "--range", "--arc"))]
if "--range" in argv:
    a, b, step = (float(x) for x in argv[argv.index("--range") + 1].split(":"))
    vals = [round(a + i * step, 3) for i in range(int(round((b - a) / step)) + 1)]
else:
    vals = [float(v) for v in pos.pop(0).split(",")]
if not pos: raise SystemExit(__doc__ or "usage: see the header")
out = pos[0]
RATE = float(pos[1]) if len(pos) > 1 else 0.0   # constant line rate: vel = RATE/lpd
print("sweep: %d values %s -> %s%s" % (len(vals), vals, out, (" at %d stages" % stages) if stages else ""), flush=True)
if "--dry" in argv:   # show the plan, touch nothing
    for lpd in vals:
        print("  lpd %.2f: %d lines over %.0f deg at %.2f deg/s" % (lpd, int(round(lpd * (ARC1 - ARC0))), ARC1 - ARC0, RATE / lpd if RATE else VEL))
    sys.exit(0)

if stages:
    c = socket.create_connection((CAM_HOST, CAM_PORT), timeout=30)
    cf = c.makefile("r")
    c.sendall((json.dumps({"cmd": "hello", "client": "claude-sweep"}) + "\n").encode())
    c.sendall((json.dumps({"cmd": "set", "key": "tdi.stages", "value": stages}) + "\n").encode())
    t0 = time.time()
    while time.time() - t0 < 30:
        m = json.loads(cf.readline() or "{}")
        if m.get("ack") == "set":
            if not m.get("ok"): raise SystemExit("camera refused tdi.stages %d: %s" % (stages, m))
            print("camera: tdi.stages = %d (%s)" % (stages, m.get("note")), flush=True)
            break
    else:
        raise SystemExit("no ack from the capture agent for tdi.stages")
    c.close()
    time.sleep(2.0)   # let the camera settle on the new stage count

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
        # a single pass is p0 whatever the filter letter (monochrome shoots through red: p0_R)
        mm = re.search(r"saved (scan_\d+_p0_[A-Z]\.tif) \| motion (\d+)ms -> (\d+)/(\d+) lines \| peak (\d+)", txt)
        if mm: saved = mm
        else: time.sleep(1)
    if not saved: raise SystemExit("no TIFF saved for lpd %.1f" % lpd)
    r = {"lpd": lpd, "vel": round(vel, 2), "lines": lines, "file": saved.group(1), "got": int(saved.group(3)),
         "motion_ms": int(saved.group(2)), "peak": int(saved.group(5)), "stages": stages or None}
    print(r, flush=True)
    results.append(r)
    json.dump(results, open(out, "w"), indent=1)
