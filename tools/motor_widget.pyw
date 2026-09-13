r"""Always-on-top desktop dial showing the xylosome scan axis position.

Read-only client of xylod: sends one `hello`, then does nothing but listen to
the 10 Hz status broadcast. It never issues a command, so it cannot disturb a
scan (xylod is multi-client — see beckhoff/PROTOCOL.md).

    pythonw tools\motor_widget.pyw [host[:port]]

Host defaults to $XYLOD_HOST or 192.168.2.2:5510.
Drag anywhere to move the widget, click the x or press Esc to close.
"""
import json
import math
import os
import socket
import sys
import threading
import time
import tkinter as tk

try:                                            # crisp text on a scaled display
    import ctypes
    ctypes.windll.shcore.SetProcessDpiAwareness(1)
except Exception:
    pass

BG, RING, DIM, TXT = "#14161a", "#2a2f38", "#8b93a1", "#e6e9ef"
NEEDLE, OK, WARN, BAD = "#e8b64c", "#4caf7d", "#e8b64c", "#d9534f"
W, H, CX, CY, R = 200, 244, 100, 104, 74
STALE_S = 1.5


def parse_host(arg):
    s = arg or os.environ.get("XYLOD_HOST") or "192.168.2.2"
    host, _, port = s.partition(":")
    return host, int(port or 5510)


class Link(threading.Thread):
    """Keeps a socket to xylod and holds the most recent status line."""

    def __init__(self, host, port):
        super().__init__(daemon=True)
        self.host, self.port = host, port
        self.lock = threading.Lock()
        self.status, self.stamp = None, 0.0

    def run(self):
        while True:
            try:
                with socket.create_connection((self.host, self.port), 4) as s:
                    s.sendall(b'{"cmd":"hello","client":"widget"}\n')
                    buf = b""
                    while True:
                        chunk = s.recv(4096)
                        if not chunk:
                            break
                        buf += chunk
                        while b"\n" in buf:
                            line, _, buf = buf.partition(b"\n")
                            self._take(line)
            except OSError:
                pass
            with self.lock:
                self.status = None
            time.sleep(2.0)

    def _take(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        if msg.get("ev") == "status":
            with self.lock:
                self.status, self.stamp = msg, time.monotonic()

    def read(self):
        with self.lock:
            if self.status is None:
                return None, 0.0
            return self.status, time.monotonic() - self.stamp


def polar(deg, r):
    """0 deg at 12 o'clock, positive clockwise — matches the arc on the rig."""
    a = math.radians(deg)
    return CX + r * math.sin(a), CY - r * math.cos(a)


class Widget:
    def __init__(self, link):
        self.link = link
        self.root = tk.Tk()
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True, "-alpha", 0.93)
        self.root.geometry("%dx%d+%d+40" % (W, H, self.root.winfo_screenwidth() - W - 40))
        self.c = tk.Canvas(self.root, width=W, height=H, bg=BG, highlightthickness=0)
        self.c.pack()
        self.draw_face()

        self.needle = self.c.create_line(CX, CY, CX, CY - R, fill=NEEDLE, width=3)
        self.travel = self.c.create_arc(CX - R + 9, CY - R + 9, CX + R - 9, CY + R - 9,
                                        start=90, extent=0, style=tk.ARC, outline=NEEDLE, width=4)
        self.c.create_oval(CX - 4, CY - 4, CX + 4, CY + 4, fill=NEEDLE, outline="")
        self.pos = self.c.create_text(CX, H - 52, text="--", fill=TXT,
                                      font=("Segoe UI", 26, "bold"))
        self.sub = self.c.create_text(CX, H - 24, text="connecting", fill=DIM,
                                      font=("Segoe UI", 9))
        self.dot = self.c.create_oval(9, 9, 17, 17, fill=BAD, outline="")
        close = self.c.create_text(W - 12, 13, text="×", fill=DIM, font=("Segoe UI", 12))
        self.c.tag_bind(close, "<Button-1>", lambda e: self.root.destroy())

        self.c.bind("<Button-1>", self.grab)
        self.c.bind("<B1-Motion>", self.drag)
        self.root.bind("<Escape>", lambda e: self.root.destroy())
        self.tick()

    def draw_face(self):
        self.c.create_oval(CX - R, CY - R, CX + R, CY + R, outline=RING, width=2)
        for deg in range(-180, 180, 15):
            major = deg % 45 == 0
            x1, y1 = polar(deg, R - (10 if major else 5))
            x2, y2 = polar(deg, R)
            self.c.create_line(x1, y1, x2, y2, fill=DIM if major else RING, width=1)
        for deg in (0, 90, 180, -90):
            x, y = polar(deg, R - 22)
            self.c.create_text(x, y, text="%d" % deg, fill=DIM, font=("Segoe UI", 7))
        # soft travel limits meet at the bottom (+/-180 deg)
        x, y = polar(180, R + 4)
        self.c.create_line(x, y - 7, x, y + 1, fill=BAD, width=2)

    def grab(self, e):
        self._dx, self._dy = e.x_root - self.root.winfo_x(), e.y_root - self.root.winfo_y()

    def drag(self, e):
        self.root.geometry("+%d+%d" % (e.x_root - self._dx, e.y_root - self._dy))

    def tick(self):
        st, age = self.link.read()
        if st is None:
            self.c.itemconfig(self.dot, fill=BAD)
            self.c.itemconfig(self.pos, text="--", fill=DIM)
            self.c.itemconfig(self.sub, text="no link to %s" % self.link.host, fill=DIM)
        else:
            deg = float(st.get("posDeg", 0.0))
            vel = float(st.get("velDegS", 0.0))
            state = str(st.get("state", "?"))
            fault = state in ("fault", "estop") or not st.get("estopOk", True)
            stale = age > STALE_S
            self.c.itemconfig(self.dot, fill=BAD if fault else WARN if stale else OK)
            self.c.itemconfig(self.pos, text="%+.1f°" % deg,
                              fill=BAD if fault else TXT)
            detail = "%s  ·  %.0f°/s" % (state, vel) if abs(vel) >= 0.05 else state
            if not st.get("enabled", True):
                detail += "  ·  no torque"
            self.c.itemconfig(self.sub, text="stale" if stale else detail,
                              fill=BAD if fault else DIM)
            x, y = polar(deg, R - 12)
            self.c.coords(self.needle, CX, CY, x, y)
            self.c.itemconfig(self.travel, extent=-max(-359.9, min(359.9, deg)))
        self.root.attributes("-topmost", True)   # re-assert after other apps go fullscreen
        self.root.after(60, self.tick)


if __name__ == "__main__":
    host, port = parse_host(sys.argv[1] if len(sys.argv) > 1 else None)
    link = Link(host, port)
    link.start()
    Widget(link).root.mainloop()
