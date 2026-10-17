#pragma once
// Config.h — xylod configuration. Plain key=value file (see config/xylod.conf).
// Everything hardware-specific lives here so bench changes never touch code.
#include <cmath>
#include <string>
#include <map>

struct Config {
    // ── network ──────────────────────────────────────────────────────────────
    int         tcpPort        = 5510;
    std::string ecIface        = "eth1";     // MAC1 — EtherCAT segment NIC

    // ── EtherCAT slave positions (1-based, order on the bus) ─────────────────
    int posDrive  = 1;   // A6-EC servo drive
    int posEk1100 = 2;   // coupler
    int posEl7031 = 3;   // filter-wheel stepper
    int posEl2521 = 4;   // line-trigger pulse out
    int posEl5152 = 5;   // encoder echo in
    int posElDout = 6;   // EL2xxx digital out (pass / index)
    int posElDin  = 7;   // EL1xxx digital in  (home / endstop / e-stop)

    // ── scan axis (A6-EC + 50:1 harmonic drive) ──────────────────────────────
    double motorCountsPerRev = 131072.0;     // 17-bit absolute encoder
    double gearRatio         = 50.0;         // harmonic drive
    bool   invertAxis        = false;
    double accLimitDegS2     = 400.0;        // output-side accel clamp (scan moves)
    double jogAccDegS2       = 4000.0;       // higher accel for jog / dial-step moves (snappy)
    double homeDeg           = 0.0;          // home position, output degrees
    double homeVelDegS       = 10.0;
    double softMinDeg        = -10.0;        // soft travel limits, output degrees
    double softMaxDeg        = 200.0;

    // ── filter wheel (EL7031 stepper) ────────────────────────────────────────
    double fwStepsPerRev   = 12800.0;        // full steps × microstepping × any belt ratio
    double fwVelStepsS     = 4000.0;         // slew rate
    double fwAccStepsS2    = 16000.0;
    double fwSlotOffset[4] = {0.0, 0.25, 0.50, 0.75};  // R G B C, fraction of a rev

    // ── colour wheel (EL7211-9014 + AM8111, direct drive, NO hard stop) ─────
    // Half wheel, three glass filters. A full turn must be impossible: every
    // target is clamped to red ± wheelWindowDeg and a measured excursion past
    // red ± wheelTripDeg quick-stops the drive and latches until fault_reset.
    // Red is the encoder's single-turn angle, taught by hand with
    // `el7211_csp ... --teach-red` and read from wheelRedFile.
    bool   wheelEnable     = false;      // false = EL7211 left untouched (pre-2026-10-16)
    std::string wheelRedFile = "/var/lib/xylod/el7211_red";
    double wheelSlotDeg[4] = {0.0, 45.0, -45.0, NAN};   // R G B C from red; nan = not fitted
    double wheelWindowDeg  = 46.0;
    double wheelTripDeg    = 48.0;
    double wheelVelRpm     = 40.0;       // bench-proven with the wheel on, 2026-10-16
    double wheelAccRps2    = 4.0;
    int    wheelVelGain    = 1000;       // 0x8010:15 — tuned WITH the wheel fitted; 2000 hummed at standstill
    int    wheelPosGain    = 1000;       // 0x8010:17
    int    wheelVelLimitRpm = 300;       // 0x8010:31 drive-side speed cap
    int    wheelRatedMa    = 2710;       // 0x8011:12 must read this (AM8111 nameplate)
    double wheelReleaseS   = 2.0;        // parked at red this long -> torque off (0 = always hold)
    // Colour exposure match, in stops of EXTRA exposure per filter (R G B C).
    // A colour pass runs at 2^-(stops - min stops) of full speed: same arc and
    // line count, each line integrated longer. 0 0 0 = no correction.
    double colourStops[4]  = {0.0, 0.0, 0.0, 0.0};
    // Runtime override of the three stops above ("r g b"), written by the
    // {"cmd":"colour_stops"} command so the HMI's calibration page can set them
    // without root. Wins over the conf values when present.
    std::string colourStopsFile = "/var/lib/xylod/colour_stops";

    // ── line trigger (EL2521) ────────────────────────────────────────────────
    double el2521BaseHz = 50000.0;           // CoE 0x8001:02 base frequency 1
                                             // (written at startup by EcBackend)
    double lineMaxHz    = 37000.0;           // absolute clamp. Was 50000 (= el2521BaseHz,
                                             // above which freqVal saturates at 32767);
                                             // lowered for the 12-bit camera, whose
                                             // readout ceiling is 38314 Hz and whose
                                             // achieved ssf is 37986.7. Overruns are
                                             // dropped silently — keep <= that, with
                                             // margin for the camera's ssf quantisation.
    double lineLagMs    = 27.1;              // delay the trigger by the axis's lag behind the
                                             // CSP setpoint, so the rate tracks where the
                                             // subject IS, not where it was commanded. 0 = off.
    double runupMs      = 150.0;             // steady speed held BEFORE a sweep's pass opens,
                                             // after ramping up at acc_limit_degs2. 0 = off.

    // ── digital I/O bit map ──────────────────────────────────────────────────
    int diHome = 0, diEndMin = 1, diEndMax = 2, diEstop = 3, diFwIndex = 4;
    int doPassActive = 0, doPassIndex = 1;
    // line-count blink: pulse an EL2008 channel (LED) every line_blink_div lines
    int    doLineBlink  = 2;       // EL2008 channel bit (0-7); same terminal as pass LEDs
    double lineBlinkDiv = 1000;    // pulse once per this many scanned lines
    double lineBlinkMs  = 30;      // pulse width, ms (snappy/visible)
    bool estopActiveLow = true;              // true: input LOW = e-stop tripped (fail-safe)

    // ── control loop ─────────────────────────────────────────────────────────
    int    cycleUs   = 1000;                 // 1 kHz EtherCAT / control cycle
    int    rtPrio    = 60;                   // SCHED_FIFO priority (0 = no RT)
    double settleMsD = 300.0;                // default pre-pass settle

    // ── absolute home ──────────────────────────────────────────────────────────
    // Taught home offset (raw encoder counts) persisted here. Requires the drive
    // in multiturn-absolute mode (C00.07=2) + battery. Empty/missing = wake-zero.
    std::string homeFile = "/var/lib/xylod/home_counts";

    // ── shutdown button (digital input, separate from E-stop/din) ───────────────
    // A momentary on an EL1008 channel; held ≥ hold_s → clean poweroff (which
    // fires the Pi shutdown hook too). 0 = not fitted.
    int    posShutdown   = 0;     // EL1008 slave position (1-based)
    int    diShutdown    = 0;     // input bit (channel N → bit N-1)
    double shutdownHoldS = 0.1;   // press debounce (≈ a click); was a 2 s hold

    bool load(const std::string &path);      // missing file → defaults, warn
    static Config fromArgs(int argc, char **argv, bool &sim);
};
