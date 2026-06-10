// teensy_pendant_analog.ino - XYLOSOME pendant, ANALOG encoder decode.
//
// Fix-2 from electronics/.../ENCODER_FIXES.md: read the encoder's A/B through
// the ADC with software hysteresis, so a marginal rest voltage (the "dead
// click") is decoded correctly instead of being left to the digital input's
// knife-edge threshold.
//
// HARDWARE PREREQUISITE - two underside jumpers on the carrier:
//   Teensy pin 4 stub  ->  pin 14 stub   (ENC_A also on A0)
//   Teensy pin 5 stub  ->  pin 15 stub   (ENC_B also on A1)
// Everything else identical to the stock pendant. D4/D5 stay connected and
// are still read (digitally) purely for diagnostics.
//
// PROTOCOL to the Pi: unchanged. READY, BTN1/2 DOWN/UP, ENC_SW DOWN/UP,
// JOG 1, JOG -1.  Extra DIAG/VOLT lines are ignored by PendantReader.
//
// BUILT-IN VOLTMETER (replaces the multimeter test T1 in ENCODER_DIAGNOSIS.md):
//   open Arduino Serial Monitor @115200, park the knob on a detent, send 'v'
//   -> prints A and B in millivolts. Do this on 4 consecutive detents
//   including the dead one and write the numbers into ENCODER_DIAGNOSIS.md.
//   send 'd' -> toggles per-landing diagnostic lines (analog vs digital).
//
// THRESHOLDS: hysteresis band chosen from the 62AG spec (low <= 1.0 V,
// high >= 3.0 V at 5 V pull-up; carrier pulls to 3.3 V). Tune after reading
// the real voltages with 'v' if needed: the band just has to separate the
// measured lows from the measured highs.

#include <Bounce2.h>

static constexpr int PIN_BTN1   = 2;
static constexpr int PIN_BTN2   = 3;
static constexpr int PIN_ENC_A  = 4;    // digital view (diagnostics only)
static constexpr int PIN_ENC_B  = 5;
static constexpr int PIN_ENC_SW = 6;
static constexpr int AIN_ENC_A  = A0;   // pin 14 - jumpered to pin 4
static constexpr int AIN_ENC_B  = A1;   // pin 15 - jumpered to pin 5

// Software Schmitt trigger (millivolts, 3.3 V ADC reference)
static constexpr int LOW_BELOW_MV  = 700;   // below this  -> logic 0
static constexpr int HIGH_ABOVE_MV = 1300;  // above this  -> logic 1
                                            // in between  -> hold last state
// Tuned 2026-06-10 to measured levels: clean low 0-160 mV, WEAK high 1558 mV
// (the historical "dead click" - a half-open optical window), strong high ~3300 mV.

// Dwell after the last decoded state change that marks "landed on a detent".
// Datasheet optical rise/fall is up to 30 ms - stay above it.
static constexpr unsigned long SETTLE_MS = 45;

// Quadrature transition table, indexed by (prevAB << 2) | curAB.
static const int8_t QTAB[16] = { 0, 1, -1, 0,  -1, 0, 0, 1,
                                 1, 0, 0, -1,   0, -1, 1, 0 };

Bounce btn1, btn2, encSw;
static constexpr unsigned int DEBOUNCE_MS = 5;

static uint8_t levelA = 0, levelB = 0;   // hysteresis outputs
static uint8_t prevAB = 0;
static long count = 0;
static long lastLanding = 0;
static elapsedMillis sinceChange;
static bool landed = true;
static bool diag = false;

static inline int readMv(int pin) {
    // 10-bit, 3.3 V reference, x4 averaging set in setup()
    return int(analogRead(pin) * 3300L / 1023L);
}

// Hysteresis: commit only outside the dead band, hold inside it.
static inline uint8_t schmitt(int mv, uint8_t prev) {
    if (mv < LOW_BELOW_MV)  return 0;
    if (mv > HIGH_ABOVE_MV) return 1;
    return prev;
}

void setup() {
    Serial.begin(115200);
    btn1.attach(PIN_BTN1,    INPUT_PULLUP); btn1.interval(DEBOUNCE_MS);
    btn2.attach(PIN_BTN2,    INPUT_PULLUP); btn2.interval(DEBOUNCE_MS);
    encSw.attach(PIN_ENC_SW, INPUT_PULLUP); encSw.interval(DEBOUNCE_MS);

    // Internal pull-ups ARE the system's pull-ups: the carrier's R1/R2 3V3
    // rail measures DEAD (floating) - masked for weeks by the old firmware's
    // INPUT_PULLUP. See ENCODER_DIAGNOSIS.md findings + Rev C item.
    pinMode(PIN_ENC_A, INPUT_PULLUP);
    pinMode(PIN_ENC_B, INPUT_PULLUP);
    // Analog pins: disable the digital input buffer/keeper (Teensy 4.x needs
    // this for clean ADC readings on jumpered nets).
    pinMode(AIN_ENC_A, INPUT_DISABLE);
    pinMode(AIN_ENC_B, INPUT_DISABLE);

    analogReadResolution(10);
    analogReadAveraging(4);

    levelA = schmitt(readMv(AIN_ENC_A), 0);
    levelB = schmitt(readMv(AIN_ENC_B), 0);
    prevAB = (levelB << 1) | levelA;     // (B,A) order so clockwise = +1
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

    // ── serial commands (Arduino Serial Monitor; Pi never sends these) ────
    while (Serial.available()) {
        const int c = Serial.read();
        if (c == 'v') {
            Serial.printf("VOLT A=%dmV B=%dmV (dig A=%d B=%d, state %u%u)\n",
                          readMv(AIN_ENC_A), readMv(AIN_ENC_B),
                          digitalRead(PIN_ENC_A), digitalRead(PIN_ENC_B),
                          levelB, levelA);
        } else if (c == 'd') {
            diag = !diag;
            Serial.printf("DIAG %s\n", diag ? "on" : "off");
        }
    }

    // ── analog quadrature decode ──────────────────────────────────────────
    const int mvA = readMv(AIN_ENC_A);
    const int mvB = readMv(AIN_ENC_B);
    levelA = schmitt(mvA, levelA);
    levelB = schmitt(mvB, levelB);
    const uint8_t ab = (levelB << 1) | levelA;

    if (ab != prevAB) {
        count += QTAB[(prevAB << 2) | ab];
        prevAB = ab;
        sinceChange = 0;
        landed = false;
    }
    else if (!landed && sinceChange >= SETTLE_MS) {
        landed = true;
        long delta = count - lastLanding;
        if (delta != 0) {
            // position-correct: one JOG per count, sanity-capped
            if (delta >  4) delta =  4;
            if (delta < -4) delta = -4;
            for (long i = 0; i < (delta > 0 ? delta : -delta); i++)
                Serial.println(delta > 0 ? "JOG 1" : "JOG -1");
            if (diag)
                Serial.printf("DIAG land delta=%ld A=%dmV B=%dmV dig=%d%d ana=%u%u\n",
                              delta, mvA, mvB,
                              digitalRead(PIN_ENC_B), digitalRead(PIN_ENC_A),
                              levelB, levelA);
            lastLanding = count;
        }
    }
}
