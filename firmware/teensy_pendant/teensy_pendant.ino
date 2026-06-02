// teensy_pendant.ino - XYLOSOME pendant controller
// USB CDC serial to the Pi @ 115200. One ASCII line per event:
//   READY, BTN1 DOWN/UP, BTN2 DOWN/UP, ENC_SW DOWN/UP, JOG 1, JOG -1
//
// ENCODER DECODE — read this before "fixing" the jog feel:
//   The Grayhill 62AG22 (and the 61C11 test unit) have detents that are
//   mechanically OFFSET from their optical code by one position per cycle.
//   Per 4 clicks the raw quadrature reads:  clean(+1) clean(+1) DEAD(0) DOUBLE(+2).
//   The DEAD click makes no electrical change; the next click sweeps two states
//   (00->10->11) in <1 ms. This is a HARDWARE CHARACTERISTIC, not a wiring,
//   ground, solder, or board fault — all verified clean. See
//   electronics/.../WIRING.md "Encoder detent quirk". DO NOT re-troubleshoot it.
//
//   DECODE CHOICE (feel over count): emit exactly ONE step per detent landing.
//   The "double" detent is CAPPED to a single step (no 2-forward jump). The
//   paired "dead" detent still produces nothing (no signal exists for it). So
//   most clicks move one item; ~1 in 4 is a no-op. Absolute position can drift
//   over a long continuous spin — accepted, because menu nav wants an even
//   one-step-per-click feel, not exact position tracking.
#include <Bounce2.h>

static constexpr int PIN_BTN1   = 2;
static constexpr int PIN_BTN2   = 3;
static constexpr int PIN_ENC_A  = 4;
static constexpr int PIN_ENC_B  = 5;
static constexpr int PIN_ENC_SW = 6;

// Dwell (ms) after the last A/B change that marks the knob as "landed" on a
// detent. One JOG is emitted per landing. ~10-20 ms is imperceptible and well
// under the gap between tactile clicks.
static constexpr unsigned long SETTLE_MS = 15;

// Standard quadrature transition table, indexed by (prevAB << 2) | curAB.
static const int8_t QTAB[16] = { 0, 1, -1, 0,  -1, 0, 0, 1,
                                 1, 0, 0, -1,   0, -1, 1, 0 };

Bounce btn1, btn2, encSw;
static constexpr unsigned int DEBOUNCE_MS = 5;

static uint8_t prevAB = 0;
static long count = 0;        // running quadrature count (direction reference)
static long lastLanding = 0;  // count at the last settled detent
static elapsedMillis sinceChange;
static bool landed = true;

// (B,A) order so clockwise = +1. If rotation drives the UI the wrong way, swap
// PIN_ENC_B / PIN_ENC_A here.
static inline uint8_t readAB() {
    return (digitalRead(PIN_ENC_B) << 1) | digitalRead(PIN_ENC_A);
}

void setup() {
    Serial.begin(115200);
    btn1.attach(PIN_BTN1,    INPUT_PULLUP); btn1.interval(DEBOUNCE_MS);
    btn2.attach(PIN_BTN2,    INPUT_PULLUP); btn2.interval(DEBOUNCE_MS);
    encSw.attach(PIN_ENC_SW, INPUT_PULLUP); encSw.interval(DEBOUNCE_MS);
    pinMode(PIN_ENC_A, INPUT_PULLUP);
    pinMode(PIN_ENC_B, INPUT_PULLUP);
    prevAB = readAB();
    lastLanding = count;
    Serial.println("READY");
}

void loop() {
    btn1.update(); btn2.update(); encSw.update();
    if (btn1.fell())  Serial.println("BTN1 DOWN");
    if (btn1.rose())  Serial.println("BTN1 UP");
    if (btn2.fell())  Serial.println("BTN2 DOWN");
    if (btn2.rose())  Serial.println("BTN2 UP");
    if (encSw.fell()) Serial.println("ENC_SW DOWN");
    if (encSw.rose()) Serial.println("ENC_SW UP");

    uint8_t ab = readAB();
    if (ab != prevAB) {                 // moving — accumulate, reset dwell
        count += QTAB[(prevAB << 2) | ab];
        prevAB = ab;
        sinceChange = 0;
        landed = false;
    }
    else if (!landed && sinceChange >= SETTLE_MS) {
        landed = true;                  // settled on a detent
        if (count != lastLanding) {     // it moved -> ONE step, capped (no double)
            Serial.println(count > lastLanding ? "JOG 1" : "JOG -1");
            lastLanding = count;
        }
    }
}
