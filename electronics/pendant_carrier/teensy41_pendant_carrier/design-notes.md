# Teensy 4.1 Pendant Carrier — Design Document

**Board:** Pendant Hard-Controls Carrier
**Rev:** B  (updated for Grayhill 62AG22-H5-P encoder)
**Date:** 2026-05-14

A small 2-layer carrier board that hosts a socketed Teensy 4.1 and breaks out
**2 pushbuttons** and **1 Grayhill 62AG22-H5-P optical encoder (jog wheel)** to
keyed JST connectors. The Teensy's own micro-USB port carries data + power to
the Raspberry Pi that runs the UI — so there is **no power supply circuitry on
this board**. It is bus-powered from the Pi.

---

## 1. The encoder drives the design — Grayhill 62AG22-H5-P

Part number decode:

| Field | Value | Meaning |
|---|---|---|
| 62 | Series 62 | Value optical rotary encoder |
| AG | Style | **5.0 Vdc supply** (the VG style would be 3.3 V) |
| 22 | Angle of throw | 22.5° per step → **16 detent positions** |
| H | Torque | High torque detent |
| 5 | Pushbutton | **Has a 510 g integrated pushbutton** |
| P | Termination | **.050″ (1.27 mm) pin header**, 6 pins, ~0.185″ long |

Key electrical facts from the Series 62AG/VG datasheet (Rev. 02/2024):

- **Supply: 5.0 V ±0.25 V, 30 mA max.** Comes from the Teensy `VIN` pin (≈5 V
  off USB) — no regulator needed.
- **Outputs A & B are open-collector phototransistors.** The datasheet states a
  **10 kΩ pull-up resistor is *required* for operation.** Because the output is
  open-collector, we pull it up to **3.3 V**, not 5 V — so the encoder outputs
  swing 0–3.3 V and are **directly safe for the Teensy 4.1's 3.3 V GPIO. No
  level shifter is needed.**
- The datasheet's recommended circuit also shows a **noise-filter capacitor
  (<1000 pF)** from each output to GND. We fit 470 pF — cheap insurance.
- **Pushbutton is an isolated normally-open switch** on pins 5 & 6 (rated
  10 mA @ 5 V, <4 ms bounce). One side to a GPIO with internal pull-up, other
  side to GND.
- Quadrature / 2-bit Gray code output, code repeats every 4 positions,
  100 rpm max — trivially slow for the Teensy.

> **Note on the "P" termination:** the encoder ships with six stiff 1.27 mm-pitch
> pins, not a cable or a friction-lock connector. For a panel-mounted encoder in
> a pendant you'll make a short **adapter cable**: a 1.27 mm 6-way socket (or
> wires soldered straight to the encoder pins) on one end, a JST-XH 6-way housing
> on the other. If you'd rather avoid that, Grayhill sells the same encoder with
> a factory cable+connector (`...-H5-C`) or stripped flying leads (`...-H5-S`).

---

## 2. Design summary

| Item | Choice | Why |
|---|---|---|
| Host | Teensy 4.1, **socketed** on 2× 24-pin female headers | Removable; never solder the expensive part |
| Layers | 2-layer, 1.6 mm FR4 | This circuit is trivial — cheapest stack-up is fine |
| Size | ~70 × 30 mm | Teensy 4.1 is 61 × 18 mm; connectors live on one edge |
| Connectors | JST-XH (2.5 mm pitch) | Keyed, robust, cheap, easy to crimp |
| Encoder power | +5 V tapped from Teensy `VIN` | Encoder needs 5 V; USB already supplies it |
| Encoder outputs | 10 kΩ pull-ups **to 3.3 V** + 470 pF filter caps | Required by datasheet; 3.3 V keeps Teensy GPIO safe |
| Buttons + enc. switch | Teensy internal `INPUT_PULLUP` | Zero external parts for the switch inputs |

---

## 3. Pin assignment (Teensy 4.1)

| Signal | Teensy pin | Mode | Notes |
|---|---|---|---|
| BTN1 | 2 | `INPUT_PULLUP` | External button, pulls to GND when pressed |
| BTN2 | 3 | `INPUT_PULLUP` | External button, pulls to GND when pressed |
| ENC_A | 4 | `INPUT` | Encoder output A — pulled up to 3V3 by R1 on-board |
| ENC_B | 5 | `INPUT` | Encoder output B — pulled up to 3V3 by R2 on-board |
| ENC_SW | 6 | `INPUT_PULLUP` | Encoder's integrated pushbutton |
| +5 V (VIN) | VIN | power out | ~5 V from USB → feeds encoder pin 1 |
| 3V3 | 3.3 V | power out | Feeds R1/R2 pull-ups only (~0.7 mA total) |
| GND | GND | — | Common return |

All five input pins are adjacent on one header edge for clean routing. On the
Teensy 4.1 every digital pin is interrupt-capable, so pins 4/5 work fine with
the `Encoder` library if you want hardware-quality counting.

---

## 4. Connectors

JST-XH, placed along one long edge so every cable leaves in the same direction.

### J1 — Button 1 (2-pin XH)
| Pin | Net |
|---|---|
| 1 | D2 (BTN1) |
| 2 | GND |

### J2 — Button 2 (2-pin XH)
| Pin | Net |
|---|---|
| 1 | D3 (BTN2) |
| 2 | GND |

### J3 — Grayhill 62AG22-H5-P encoder (6-pin XH)

> **Cable note:** The Grayhill 62AG22-H5-P has a **2×3 pin header** (two rows of
> 3, 1.27 mm pitch). The adapter cable converts this to a single-row 6-pin
> JST-XH by connecting **row 2 first (encoder pins 4, 5, 6 → J3 pins 1, 2, 3)**
> then **row 1 (encoder pins 1, 2, 3 → J3 pins 4, 5, 6)**. The cable is **NOT**
> straight-through pin-for-pin.

| J3 pin | Encoder pin | Net | On-board |
|---|---|---|---|
| 1 | 6 — switch return | GND | — |
| 2 | 5 — switch NO | ENC_SW → D6 | (Teensy internal pull-up) |
| 3 | 4 — OUTPUT B | ENC_B → D5 | R2 10 kΩ → 3V3, C2 470 pF → GND |
| 4 | 1 — POWER +5 V | +5 V (VIN) | — |
| 5 | 2 — OUTPUT A | ENC_A → D4 | R1 10 kΩ → 3V3, C1 470 pF → GND |
| 6 | 3 — GROUND | GND | — |

---

## 5. Bill of materials

| Qty | Ref | Part | Fitted? | Notes |
|---|---|---|---|---|
| 1 | U1 | Teensy 4.1 | — | Sits in sockets, not soldered |
| 2 | — | 24-pin female header, 0.1″ pitch | yes | Sockets for the Teensy (rows 0.6″ apart) |
| 2 | J1, J2 | JST-XH 2-pin, vertical, TH | yes | Buttons |
| 1 | J3 | JST-XH 6-pin, vertical, TH | yes | Encoder |
| 2 | R1, R2 | 10 kΩ resistor, 0805 | **yes — required** | Pull-ups for encoder open-collector outputs A/B |
| 2 | C1, C2 | 470 pF capacitor, 0805 | yes (recommended) | Noise filter on A/B per datasheet (<1000 pF) |
| 1 | C5 | 10 µF capacitor, 0805/1206 | optional | Bulk decoupling on the +5 V feed near J3 |
| 2 | C3, C4 | 100 nF capacitor, 0805 | optional / DNP | Hardware debounce on BTN1/BTN2 if firmware debounce isn't enough |
| 1 | PCB | 2-layer, 1.6 mm, ~70 × 30 mm | — | — |
| 4 | — | M3 standoffs/screws | optional | Corner mounting holes |

Plus: JST-XH housings + crimp contacts for the cables, and a 1.27 mm 6-way
socket (or direct-solder) for the encoder-side end of the J3 adapter cable.

---

## 6. PCB layout guidance

- **Teensy placement:** oriented so its **micro-USB connector faces a board
  edge** (the cable to the Pi). Leave ~10 mm clearance past the USB jack.
- **`VIN` check:** the encoder's 5 V comes from the Teensy `VIN` pin, which is
  joined to USB 5 V by the pad on the bottom of the Teensy — leave that pad
  intact (it is, by default). Don't also feed VIN from an external supply.
- **Sockets:** two 24-pin female headers, rows on 0.6″ (15.24 mm) centers,
  0.1″ pitch — matches the Teensy 4.1 outline.
- **Pull-ups/caps:** keep R1/R2 and C1/C2 close to J3 so the filtered node is
  short. Route ENC_A/ENC_B from J3 → R/C node → D4/D5.
- **Connectors J1–J3:** line them up along one long edge, friction-lock tabs
  outward. Silkscreen: `BTN1`, `BTN2`, `ENC` — and print the J3 pin table
  next to it.
- **Ground:** ground pour on the bottom layer; all connector GNDs and Teensy
  GND pins drop straight in. Signal traces on top, 10 mil is plenty.
- **Mounting holes:** 3.2 mm in the 4 corners with a keep-out ring.
- No impedance control, no high speed — this is an afternoon's routing.

---

## 7. Firmware sketch (starting point)

```cpp
#include <Bounce2.h>
#include <Encoder.h>

Encoder jog(4, 5);            // ENC_A=D4, ENC_B=D5  (open-collector, pulled to 3V3)
Bounce  btn1  = Bounce();
Bounce  btn2  = Bounce();
Bounce  encSw = Bounce();

void setup() {
  // Encoder A/B already have hard 10k pull-ups on the board — plain INPUT.
  pinMode(4, INPUT);
  pinMode(5, INPUT);
  btn1.attach(2,  INPUT_PULLUP); btn1.interval(5);
  btn2.attach(3,  INPUT_PULLUP); btn2.interval(5);
  encSw.attach(6, INPUT_PULLUP); encSw.interval(5);   // encoder's pushbutton
  Serial.begin(115200);          // USB CDC to the Pi
}

void loop() {
  btn1.update(); btn2.update(); encSw.update();

  if (btn1.fell())  Serial.println("BTN1");
  if (btn2.fell())  Serial.println("BTN2");
  if (encSw.fell()) Serial.println("ENC_SW");

  static long last = 0;
  long pos = jog.read();
  if (pos != last) { Serial.print("JOG "); Serial.println(pos); last = pos; }
}
```

The 62AG is 16 detents/rev with quadrature; the `Encoder` library will report
4 counts per detent — divide by 4 in firmware if you want one count per click.
Swap the `Serial.println` calls for `Joystick`/`Keyboard` HID reports later if
you want the Pi to see a real input device instead of a serial stream.

---

## 8. Open questions / confirm before fab

1. **Encoder cabling** — happy to make the 1.27 mm-header → JST-XH adapter
   cable yourself, or would you rather I respec J3 to mate the encoder some
   other way (e.g. order the encoder's `-C` cable+connector variant instead)?
2. **Connector exit direction** — vertical (up) JST or right-angle? Right-angle
   is usually tidier inside a pendant shell.
3. **Mounting** — do you want the 4 corner holes, or another retention method?
4. **USB to the Pi** — use the Teensy's own micro-USB jack directly, or run a
   panel-mount USB on the enclosure (a short pigtail handles that — no board
   change)?
5. Want me to generate the actual **KiCad project** (schematic + routed 2-layer
   board, fab-ready) from this?
