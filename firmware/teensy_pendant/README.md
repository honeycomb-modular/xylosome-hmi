# Teensy Pendant Firmware

Firmware and Pi-side serial reader for the **Teensy 4.1 Pendant Carrier (Rev B)**.

The Teensy reads two pushbuttons, the Grayhill 62AG22-H5-P jog wheel (encoder + shaft button), and streams clean event lines over USB to the Raspberry Pi.

---

## Files

| File | Purpose |
|---|---|
| `teensy_pendant.ino` | Teensy 4.1 firmware (Arduino / Teensyduino) |
| `../../pi/services/pendant_serial.py` | Pi-side USB serial reader (Python 3, threaded) |

---

## Required Libraries

Install both from the Arduino Library Manager before compiling:

| Library | Version | Purpose |
|---|---|---|
| **Bounce2** | ≥ 2.7 | Button debounce |
| **Encoder** | ≥ 1.4.4 | Quadrature encoder counting |

---

## Flashing

1. Open `teensy_pendant.ino` in the Arduino IDE with **Teensyduino** installed.
2. Board: `Teensy 4.1`
3. USB Type: `Serial` (default)
4. Upload.

---

## Serial Protocol

**Port:** `/dev/ttyACM0` (or `/dev/ttyACM1`) — 115200 8N1

One ASCII line per event, `\n` terminated. The Teensy sends nothing when idle.

| Message | Meaning |
|---|---|
| `READY` | Teensy booted — sent once on startup |
| `BTN1 DOWN` / `BTN1 UP` | Button 1 pressed / released |
| `BTN2 DOWN` / `BTN2 UP` | Button 2 pressed / released |
| `ENC_SW DOWN` / `ENC_SW UP` | Encoder shaft button pressed / released |
| `JOG <n>` | Jog wheel moved; `n` is a signed integer, one count = one detent click |

**JOG delta:** positive = clockwise, negative = counter-clockwise.  
The Grayhill encoder produces 4 quadrature pulses per detent; the firmware divides by 4 so the Pi always receives whole detent counts.

---

## Pi-Side Usage

`pendant_serial.py` exposes a simple threaded reader:

```python
from pendant_serial import PendantSerial

def handle(event):
    if event["type"] == "jog":
        print(f"Jog: {event['delta']}")
    elif event["type"] == "button":
        print(f"{event['id']} {event['state']}")

pendant = PendantSerial(port="/dev/ttyACM0")
pendant.on_event = handle
pendant.start()
```

The `on_event` callback receives a plain dict — easy to route into whatever the application layer needs (motor jog commands, UI navigation, ClearCore dispatch, etc.).

Requires `pyserial`:
```bash
pip install pyserial
```

---

## Pin Reference

| Teensy Pin | Signal | Notes |
|---|---|---|
| D2 | BTN1 | Internal pull-up; active-low |
| D3 | BTN2 | Internal pull-up; active-low |
| D4 | ENC_A | 10kΩ pull-up to 3V3 on PCB |
| D5 | ENC_B | 10kΩ pull-up to 3V3 on PCB |
| D6 | ENC_SW | Internal pull-up; active-low |
| VIN | +5V out | Feeds encoder power (from USB) |
| 3V3 | +3V3 out | Feeds ENC_A/B pull-ups |
| GND | Ground | Common return |

---

## Hardware Notes

- The encoder supply (5V) comes from the Teensy `VIN` pin — leave the solder bridge on the Teensy's underside intact.
- ENC_A/B pull-ups and 470 pF filter caps are on the carrier PCB — no external components needed.
- The Teensy is **socketed**, not soldered — replaceable without rework.
