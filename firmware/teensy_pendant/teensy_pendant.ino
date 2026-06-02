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
//   ground, solder, or board fault — all of those were verified clean. See
//   electronics/.../WIRING.md "Encoder detent quirk". DO NOT re-troubleshoot it
//   as an electrical fault.
//
//   Decode strategy below: keep an exact quadrature count (full transition
//   table, polled — never drifts), then emit at most one step per MIN_GAP_MS so
//   the DOUBLE is spread into two quick steps instead of a visible jump. The
//   DEAD click stays inert (no real-time signal exists for it). Position is
//   always correct; the once-per-cycle stutter is the encoder's, not ours.
#include <Bounce2.h>

static constexpr int PIN_BTN1   = 2;
static constexpr int PIN_BTN2   = 3;
static constexpr int PIN_ENC_A  = 4;
static constexpr int PIN_ENC_B  = 5;
static constexpr int PIN_ENC_SW = 6;

// Min spacing between emitted jog steps. Spreads a "double" into two quick
// steps. Set to 0 for instant emission (position still correct, but the
// double-state click will visibly jump two). 60-80 ms feels smooth for menus.
static constexpr unsigned long MIN_GAP_MS = 70;

// Standard quadrature transition table, indexed by (prevAB << 2) | curAB.
static const int8_t QTAB[16] = { 0, 1, -1, 0,  -1, 0, 0, 1,
                                 1, 0, 0, -1,   0, -1, 1, 0 };

Bounce btn1, btn2, encSw;
static constexpr unsigned int DEBOUNCE_MS = 5;

static uint8_t prevAB = 0;
static long count = 0;     // true position (full quadrature, never drifts)
static long shown = 0;     // emitted position; follows count, rate-limited
static elapsedMillis sinceEmit;

// (B,A) order so clockwise = +1 (matches the original Encoder(B,A) convention).
// If rotation drives the UI the wrong way, swap PIN_ENC_B / PIN_ENC_A here.
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

    // Track exact position from every quadrature transition (polled).
    uint8_t ab = readAB();
    if (ab != prevAB) {
        count += QTAB[(prevAB << 2) | ab];
        prevAB = ab;
    }

    // Emit one step toward the true position, rate-limited to smooth doubles.
    if (shown != count && sinceEmit >= MIN_GAP_MS) {
        if (count > shown) { Serial.println("JOG 1");  ++shown; }
        else               { Serial.println("JOG -1"); --shown; }
        sinceEmit = 0;
    }
}
