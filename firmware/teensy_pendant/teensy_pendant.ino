// teensy_pendant.ino - XYLOSOME pendant controller
// USB CDC serial to the Pi @ 115200. One ASCII line per event:
//   READY, BTN1 DOWN/UP, BTN2 DOWN/UP, ENC_SW DOWN/UP, JOG 1, JOG -1
#include <Bounce2.h>
#include <Encoder.h>

static constexpr int PIN_BTN1   = 2;
static constexpr int PIN_BTN2   = 3;
static constexpr int PIN_ENC_A  = 4;
static constexpr int PIN_ENC_B  = 5;
static constexpr int PIN_ENC_SW = 6;

static constexpr long COUNTS_PER_DETENT = 2;  // 61C11 = ~2; two JOGs/click -> 4

Encoder jog(PIN_ENC_B, PIN_ENC_A);  // B,A so clockwise = +1
static long encLast = 0;

Bounce btn1, btn2, encSw;
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
    btn1.update(); btn2.update(); encSw.update();
    if (btn1.fell())  Serial.println("BTN1 DOWN");
    if (btn1.rose())  Serial.println("BTN1 UP");
    if (btn2.fell())  Serial.println("BTN2 DOWN");
    if (btn2.rose())  Serial.println("BTN2 UP");
    if (encSw.fell()) Serial.println("ENC_SW DOWN");
    if (encSw.rose()) Serial.println("ENC_SW UP");
    long raw = jog.read();
    long delta = raw - encLast;
    while (delta >=  COUNTS_PER_DETENT) { Serial.println("JOG 1");  encLast += COUNTS_PER_DETENT; delta -= COUNTS_PER_DETENT; }
    while (delta <= -COUNTS_PER_DETENT) { Serial.println("JOG -1"); encLast -= COUNTS_PER_DETENT; delta += COUNTS_PER_DETENT; }
}
