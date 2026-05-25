// teensy_pendant.ino
#include <Bounce2.h>
#include <Encoder.h>

static constexpr int PIN_BTN1   = 2;
static constexpr int PIN_BTN2   = 3;
static constexpr int PIN_ENC_A  = 4;
static constexpr int PIN_ENC_B  = 5;
static constexpr int PIN_ENC_SW = 6;

Encoder jog(PIN_ENC_A, PIN_ENC_B);
static long encLast = 0;

Bounce btn1;
Bounce btn2;
Bounce encSw;

static constexpr unsigned int DEBOUNCE_MS = 5;

void setup() {
    Serial.begin(115200);
    btn1.attach(PIN_BTN1,    INPUT_PULLUP); btn1.interval(DEBOUNCE_MS);
    btn2.attach(PIN_BTN2,    INPUT_PULLUP); btn2.interval(DEBOUNCE_MS);
    encSw.attach(PIN_ENC_SW, INPUT_PULLUP); encSw.interval(DEBOUNCE_MS);
    pinMode(PIN_ENC_A, INPUT_PULLUP);
    pinMode(PIN_ENC_B, INPUT_PULLUP);
    encLast = jog.read();
    Serial.println("READY");
}

void loop() {
    btn1.update();
    btn2.update();
    encSw.update();

    if (btn1.fell())  Serial.println("BTN1 DOWN");
    if (btn1.rose())  Serial.println("BTN1 UP");
    if (btn2.fell())  Serial.println("BTN2 DOWN");
    if (btn2.rose())  Serial.println("BTN2 UP");
    if (encSw.fell()) Serial.println("ENC_SW DOWN");
    if (encSw.rose()) Serial.println("ENC_SW UP");

    // Grayhill 61C11 = 2 quadrature pulses per detent
    long raw = jog.read();
    long delta = raw - encLast;
    if (abs(delta) >= 2) {
        Serial.print("JOG ");
        Serial.println(delta > 0 ? 1 : -1);
        encLast = raw;
    }
}