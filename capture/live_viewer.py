# live_viewer.py - minimal viewer for the live-focus stream (LIVE_PROTOCOL.md).
# Connects to the agent on :5520, shows a rolling waterfall + the focus number.
# Stand-in for the Suite's live view, so you can pull focus now.
#
# Deps:  pip install opencv-python numpy
# Run:   python "%USERPROFILE%\Desktop\dalsa manuals\live_viewer.py"
#        (q or Esc in the window to quit)

import socket, json, numpy as np, cv2

HOST, PORT = "127.0.0.1", 5520
WIDTH, HEIGHT = 1024, 500          # waterfall display size (px, lines)

def recv_exact(f, n):
    data = f.read(n)
    return data if data and len(data) == n else None

c = socket.create_connection((HOST, PORT))
f = c.makefile("rb")
c.sendall(b'{"cmd":"hello","client":"viewer"}\n')
c.sendall((json.dumps({"cmd": "live_start", "width": WIDTH, "maxHz": 30}) + "\n").encode())
print("connected; streaming. q/Esc to quit.")

water = np.zeros((HEIGHT, WIDTH), np.uint8)
focus = 0.0
try:
    while True:
        header = f.readline()
        if not header:
            print("stream closed"); break
        m = json.loads(header)
        ev = m.get("ev")
        if ev == "welcome":
            print("welcome:", m); continue
        if ev == "error":
            print("agent error:", m.get("text")); break
        if ev != "lines":
            continue

        count, w, nbytes = m["count"], m["width"], m["bytes"]
        focus = m.get("focus", 0.0)
        payload = recv_exact(f, nbytes)
        if payload is None:
            print("short payload"); break
        block = np.frombuffer(payload, np.uint8).reshape(count, w)

        # scroll waterfall up, append newest lines at the bottom
        water = np.roll(water, -count, axis=0)
        water[-count:, :] = block

        # contrast-stretch for display (data is dark), overlay focus number
        disp = cv2.normalize(water, None, 0, 255, cv2.NORM_MINMAX)
        disp = cv2.cvtColor(disp, cv2.COLOR_GRAY2BGR)
        cv2.putText(disp, f"focus {focus:.3f}", (12, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 0), 2)
        cv2.imshow("live focus  (q/Esc to quit)", disp)
        k = cv2.waitKey(1) & 0xFF
        if k in (ord('q'), 27):
            break
finally:
    try: c.sendall(b'{"cmd":"live_stop"}\n')
    except Exception: pass
    c.close()
    cv2.destroyAllWindows()
