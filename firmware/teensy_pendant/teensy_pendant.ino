// teensy_pendant.ino
// Xylosome pendant hard-controls — Teensy 4.1 firmware
//
// Hardware (carrier PCB Rev B):
//   D2  BTN1        pushbutton, active-low (internal pull-up)
//   D3  BTN2        pushbutton, active-low (internal pull-up)
//   D4  ENC_A       Grayhill 62AG22-H5-P output A (10k pull-up to 3V3 on-board)
//   D5  ENC_B       Grayhill 62AG22-H5-P output B (10k pull-up to 3V3 on-board)
//   D6  ENC_SW      encoder shaft pushbutton, active-low (internal pull-up)
//
// Required libraries (Arduino Library Manager):
//   Bounce2   >= 2.7
//   Encoder   >= 1.4.4   (uses Teensy 4.1 hardware interrupt pins — D4/D5 qualify)
//
// Protocol — USB CDC serial, 115200 8N1, one ASCII line per event:
//
//   READY              sent once on boot
//   BTN1 DOWN / UP
//   BTN2 DOWN / UP
//   ENC_SW DOWN / UP
//   JOG <delta>        signed integer, one count = one encoder detent
//                      (Grayhill 62AG = 4 quadrature pulses/detent → divide by 4)
//
// The Teensy sends nothing when idle — Pi side just reads lines as they arrive.
// All messages are terminated with \n.

#include <Bounce2.h>
#include <Encoder.h>

// ── Pin definitions ───────────────────────────────────────────────────────────
static constexpr int PIN_BTN1   = 2;
static constexpr int PIN_BTN2   = 3;
static constexpr int PIN_ENC_A  = 4;
static constexpr int PIN_ENC_B  = 5;
static constexpr int PIN_ENC_SW = 6;

// ── Encoder ───────────────────────────────────────────────────────────────────
// Encoder library counts all 4 quadrature edges per detent.
// Dividing by 4 gives one integer count per physical click.
Encoder jog(PIN_ENC_A, PIN_ENC_B);
static long encLast = 0;

// ── Buttons ───────────────────────────────────────────────────────────────────
Bounce btn1;
Bounce btn2;
Bounce encSw;

static constexpr unsigned int DEBOUNCE_MS = 5;

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);

    btn1.attach(PIN_BTN1,   INPUT_PULLUP);  btn1.interval(DEBOUNCE_MS);
    btn2.attach(PIN_BTN2,   INPUT_PULLUP);  btn2.interval(DEBOUNCE_MS);
    encSw.attach(PIN_ENC_SW, INPUT_PULLUP); encSw.interval(DEBOUNCE_MS);

    // ENC_A/B have hard pull-ups on the PCB; plain INPUT is correct.
    pinMode(PIN_ENC_A, INPUT);
    pinMode(PIN_ENC_B, INPUT);

    encLast = jog.read();

    Serial.println("READY");
}

// ── Main loop ─────────────────────────────────────────────────────────────────
void loop() {
    // Buttons
    btn1.update();
    btn2.update();
    encSw.update();

    if (btn1.fell())  Serial.println("BTN1 DOWN");
    if (btn1.rose())  Serial.println("BTN1 UP");
    if (btn2.fell())  Serial.println("BTN2 DOWN");
    if (btn2.rose())  Serial.println("BTN2 UP");
    if (encSw.fell()) Serial.println("ENC_SW DOWN");
    if (encSw.rose()) Serial.println("ENC_SW UP");

    // Encoder — report relative delta per detent
    long raw = jog.read();
    long delta = (raw - encLast) / 4;       // 4 pulses per detent
    if (delta != 0) {
        Serial.print("JOG ");
        Serial.println(delta);
        encLast += delta * 4;               // keep remainder for sub-detent noise
    }
}
