#pragma once
// Config.h — xylod configuration. Plain key=value file (see config/xylod.conf).
// Everything hardware-specific lives here so bench changes never touch code.
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

    // ── line trigger (EL2521) ────────────────────────────────────────────────
    double el2521BaseHz = 50000.0;           // CoE 0x8000:02 base frequency
    double lineMaxHz    = 20000.0;           // absolute clamp

    // ── digital I/O bit map ──────────────────────────────────────────────────
    int diHome = 0, diEndMin = 1, diEndMax = 2, diEstop = 3, diFwIndex = 4;
    int doPassActive = 0, doPassIndex = 1;
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
    double shutdownHoldS = 2.0;   // hold time to trigger

    bool load(const std::string &path);      // missing file → defaults, warn
    static Config fromArgs(int argc, char **argv, bool &sim);
};
