# pendant_serial.py
# Minimal USB serial reader for the Teensy pendant.
#
# Reads event lines from the Teensy and dispatches them via callbacks.
# Intended to run as a thread inside the larger Pi application.
#
# Protocol lines (from Teensy):
#   READY
#   BTN1 DOWN / UP
#   BTN2 DOWN / UP
#   ENC_SW DOWN / UP
#   JOG <signed int>
#
# Usage:
#   pendant = PendantSerial(port="/dev/ttyACM0")
#   pendant.on_event = my_handler   # fn(event: dict)
#   pendant.start()
#   ...
#   pendant.stop()
#
# Event dict shape:
#   { "type": "button", "id": "BTN1",  "state": "down" }
#   { "type": "button", "id": "BTN2",  "state": "up"   }
#   { "type": "button", "id": "ENC_SW","state": "down" }
#   { "type": "jog",    "delta": 1                     }
#   { "type": "ready"                                   }

import serial
import threading
import logging

log = logging.getLogger(__name__)


class PendantSerial:
    BAUD = 115200

    def __init__(self, port: str = "/dev/ttyACM0", timeout: float = 1.0):
        self.port    = port
        self.timeout = timeout
        self.on_event = None          # callable(event: dict) — set before start()
        self._thread  = None
        self._running = False

    # ── Public API ─────────────────────────────────────────────────────────────

    def start(self):
        self._running = True
        self._thread  = threading.Thread(target=self._run, daemon=True, name="pendant-serial")
        self._thread.start()
        log.info("PendantSerial: reader thread started on %s", self.port)

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=3.0)
        log.info("PendantSerial: stopped")

    # ── Internal ──────────────────────────────────────────────────────────────

    def _run(self):
        while self._running:
            try:
                with serial.Serial(self.port, self.BAUD, timeout=self.timeout) as ser:
                    log.info("PendantSerial: connected to %s", self.port)
                    while self._running:
                        raw = ser.readline()
                        if not raw:
                            continue        # timeout — loop again
                        line = raw.decode("ascii", errors="ignore").strip()
                        if line:
                            self._dispatch(line)
            except serial.SerialException as exc:
                log.warning("PendantSerial: serial error (%s) — retrying in 2 s", exc)
                import time; time.sleep(2.0)

    def _dispatch(self, line: str):
        event = self._parse(line)
        if event is None:
            log.debug("PendantSerial: unrecognised line: %r", line)
            return
        log.debug("PendantSerial: event %s", event)
        if callable(self.on_event):
            try:
                self.on_event(event)
            except Exception:
                log.exception("PendantSerial: on_event handler raised")

    @staticmethod
    def _parse(line: str) -> dict | None:
        parts = line.split()
        if not parts:
            return None

        if parts[0] == "READY":
            return {"type": "ready"}

        if parts[0] == "JOG" and len(parts) == 2:
            try:
                return {"type": "jog", "delta": int(parts[1])}
            except ValueError:
                return None

        if parts[0] in ("BTN1", "BTN2", "ENC_SW") and len(parts) == 2:
            state = parts[1].lower()
            if state in ("down", "up"):
                return {"type": "button", "id": parts[0], "state": state}

        return None


# ── Quick smoke test ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    import time
    logging.basicConfig(level=logging.DEBUG, format="%(levelname)s  %(message)s")

    def handle(event):
        print("EVENT:", event)

    p = PendantSerial()
    p.on_event = handle
    p.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        p.stop()
