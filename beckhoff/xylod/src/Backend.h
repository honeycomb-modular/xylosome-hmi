#pragma once
// Backend.h — hardware abstraction the Sequencer talks to.
// Two implementations: EcBackend (SOEM / real EtherCAT segment) and
// SimBackend (--sim, pure software — lets the Pi HMI be developed end-to-end
// with no hardware on the bench).
//
// Threading contract: the backend owns the cyclic thread (cfg.cycleUs). Each
// cycle it calls the registered callback AFTER inputs are fresh and BEFORE
// outputs are sent. All Backend methods below are only legal inside that
// callback (single-threaded control context — no locks needed there).

#include <cstdint>
#include <functional>

struct DriveState {
    uint16_t statusword = 0;
    uint16_t errorCode  = 0;
    int8_t   opModeDisp = 0;
    bool     enabled    = false;   // CiA-402 Operation Enabled reached
    bool     fault      = false;
};

struct DigitalIn {
    bool home = false, endMin = false, endMax = false;
    bool estopOk = true;           // already polarity-corrected: true = safe
    bool fwIndex = false;
};

class IBackend {
public:
    virtual ~IBackend() = default;

    using CycleFn = std::function<void(double dtSec)>;
    virtual bool start(CycleFn cycle) = 0;   // bring segment to OPERATIONAL, start thread
    virtual void shutdown() = 0;

    virtual bool operational() const = 0;    // EtherCAT segment healthy

    // ── scan axis (CiA-402, CSP) — output-side degrees ───────────────────────
    virtual void   axisEnable(bool on) = 0;
    virtual void   axisFaultReset() = 0;
    virtual void   axisSetTargetDeg(double deg) = 0;   // CSP setpoint, every cycle
    virtual double axisPosDeg() const = 0;             // actual position
    virtual double axisVelDegS() const = 0;
    virtual void   setHome() = 0;                      // current pose → 0°, persisted
    virtual DriveState drive() const = 0;

    // ── filter wheel (EL7031) ────────────────────────────────────────────────
    virtual void fwMoveToSlot(int slot) = 0;           // 0=R 1=G 2=B 3=C
    virtual bool fwBusy() const = 0;
    virtual int  fwSlot() const = 0;                   // -1 while moving/unknown

    // ── line trigger (EL2521) ────────────────────────────────────────────────
    virtual void setLineHz(double hz) = 0;
    virtual double lineHz() const = 0;

    // ── digital I/O ──────────────────────────────────────────────────────────
    virtual DigitalIn din() const = 0;
    virtual void setPassActive(bool on) = 0;
    virtual void setPassIndex(bool on) = 0;            // sequencer shapes the pulse

    // ── telemetry ────────────────────────────────────────────────────────────
    virtual int32_t echoCounts() const = 0;            // EL5152 ch1
    virtual bool    shutdownPressed() const = 0;       // dedicated shutdown DI (raw, no debounce)
};
