#pragma once
// EcBackend.h — SOEM EtherCAT master for the Xylosome motion segment.
//
// Bus order (configurable in xylod.conf):
//   1  A6-EC    StepperOnline 400 W servo drive — CiA-402, CSP, 17-bit abs
//   2  EK1100   coupler
//   3  EL7031   filter-wheel stepper (velocity PDO + SW position loop)
//   4  EL2521   line-trigger pulse output (frequency mode)
//   5  EL5152   encoder echo counter (telemetry only)
//   6  EL2xxx   digital out — pass_active / pass_index → capture breakout
//   7  EL1xxx   digital in  — home / endstops / E-stop / fw index
//
// Cyclic thread: clock_nanosleep at cfg.cycleUs, optional SCHED_FIFO.
// PDO layout is verified at startup against expected sizes; offsets are
// resolved from ec_slave[].outputs/.inputs. A6-EC RxPDO/TxPDO are remapped
// via SDO to a known CSP set (see EcBackend.cpp) so byte offsets are fixed.

#include "Backend.h"
#include "Config.h"
#include <atomic>
#include <thread>
#include <string>

class EcBackend : public IBackend {
public:
    explicit EcBackend(const Config &cfg) : m_cfg(cfg) {}
    ~EcBackend() override { shutdown(); }

    bool start(CycleFn cycle) override;
    void shutdown() override;
    bool operational() const override { return m_op; }

    void   axisEnable(bool on) override { m_wantEnable = on; }
    void   axisFaultReset() override;     // also re-arms a tripped colour wheel
    void   axisSetTargetDeg(double deg) override;
    double axisPosDeg() const override;
    double axisVelDegS() const override;
    void   setHome() override;
    DriveState drive() const override;

    void fwMoveToSlot(int slot) override;
    void fwPark() override;               // colour wheel: to red, then torque off
    bool fwBusy() const override { return m_cfg.wheelEnable ? wheelBusy() : m_fwBusy; }
    int  fwSlot() const override {
        if (m_cfg.wheelEnable) return wheelBusy() ? -1 : m_whSlot;
        return m_fwBusy ? -1 : m_fwSlot;
    }

    void setLineHz(double hz) override;
    double lineHz() const override { return m_lineHzCmd; }

    DigitalIn din() const override { return m_din; }
    void setPassActive(bool on) override { m_passActive = on; }
    void setPassIndex(bool on) override { m_passIndex = on; }
    void setLineBlink(bool on) override { m_lineBlink = on; }

    int32_t echoCounts() const override { return m_echo; }
    bool    shutdownPressed() const override { return m_shutdownBit; }

private:
    bool busInit();                       // config_init/map, PDO remap, → OP
    bool remapDriveCsp(int slave);        // SDO remap 0x1600/0x1A00 for CSP
    void cyclicLoop(CycleFn cycle);
    void readInputs();
    void writeOutputs();
    void fwCycle(double dt);              // filter-wheel SW position loop

    // colour wheel on the EL7211-9014 (see Config.h)
    bool wheelPreop(int s);               // checks + PDO/sync/gains, slave in PRE-OP
    bool wheelArmDc(int s);               // INIT walk-back, re-apply, SYNC0+1, SAFE-OP
    void wheelCycle(double dt);           // state machine + trapezoid + window/trip
    bool wheelBusy() const { return m_wh != Wh::Holding && m_wh != Wh::Released; }

    double countsToDeg(int32_t c) const;      // position: zero-referenced
    double countsToDegRel(int32_t c) const;   // scale only (velocities)
    int32_t degToCounts(double d) const;

    bool loadHomeCounts(int32_t &out) const;  // taught home offset ← homeFile
    void saveHomeCounts(int32_t v) const;     //                   → homeFile

    const Config &m_cfg;
    std::atomic<bool> m_running{false};
    std::atomic<bool> m_op{false};
    std::thread m_thread;

    // ── PDO pointers (resolved after ec_config_map) ──────────────────────────
    // A6-EC, fixed layout after remap:
    struct DriveRx { uint16_t controlword; int32_t targetPos; int8_t opMode; } __attribute__((packed));
    struct DriveTx { uint16_t statusword; int32_t actualPos; int32_t actualVel;
                     uint16_t errorCode; int8_t opModeDisp; } __attribute__((packed));
    DriveRx *m_drvRx = nullptr;
    DriveTx *m_drvTx = nullptr;
    int      m_drivePos = 0;   // A6-EC slave index — auto-located by product ID in busInit()
    // EL7031 velocity-control PDO (16-bit ctrl + 16-bit velocity; status + 32-bit counter)
    struct El7031Rx { uint16_t ctrl; int16_t velocity; } __attribute__((packed));
    struct El7031Tx { uint16_t status; uint32_t counter; } __attribute__((packed));
    El7031Rx *m_fwRx = nullptr;
    El7031Tx *m_fwTx = nullptr;
    // EL2521 (16-bit ctrl + 16-bit frequency value)
    struct El2521Rx { uint16_t ctrl; int16_t freqVal; } __attribute__((packed));
    El2521Rx *m_ltRx = nullptr;
    uint32_t *m_echoIn = nullptr;         // EL5152 ch1 counter
    uint8_t  *m_dout = nullptr;
    uint8_t  *m_dinRaw = nullptr;
    uint8_t  *m_shutdownRaw = nullptr;    // dedicated shutdown-button DI (EL1008)

    // ── control-context state ────────────────────────────────────────────────
    bool   m_wantEnable = false;
    bool   m_faultReset = false;
    double m_targetDeg  = 0.0;
    bool   m_targetValid = false;         // until first set, echo actual back
    bool   m_passActive = false, m_passIndex = false, m_lineBlink = false;
    double m_lineHzCmd  = 0.0;
    double m_freqAcc    = 0.0;            // EL2521 word dither carry (see writeOutputs)

    // filter wheel
    bool   m_fwBusy = false;
    int    m_fwSlot = 3;                  // assume parked on Clear at boot
    double m_fwPosSteps = 0.0, m_fwTargetSteps = 0.0, m_fwVelCmd = 0.0;

    // colour wheel — EL7211-9014, MDP 742 CSP. PDO assignment set in PRE-OP:
    //   Rx 0x1600 controlword + 0x1606 target POSITION (default 0x1601 is
    //   VELOCITY — verified before enabling, a mis-map would be a runaway)
    //   Tx 0x1A00 FB position + 0x1A01 statusword + 0x1A03 torque
    struct WheelRx { uint16_t cw; int32_t target; } __attribute__((packed));
    struct WheelTx { int32_t pos; uint16_t sw; int16_t torque; } __attribute__((packed));
    WheelRx *m_whRx = nullptr;
    WheelTx *m_whTx = nullptr;
    int      m_whPos = 0;                 // slave index, 0 = not found / not enabled
    enum class Wh { Off, Waiting, Enabling, Holding, Moving, Tripped, Released };
    bool     m_whParkArmed = false;       // at rest after a park/boot: may release torque
    Wh       m_wh = Wh::Off;              // Off = fitted but unusable (logged why)
    long long m_whRedSt = -1;             // red, single-turn counts
    long long m_whCpr = 0;                // counts per rev (0x9008:12)
    int32_t  m_whCenter = 0;              // red in this session's counts
    int32_t  m_whWin = 0, m_whTrip = 0;   // window / trip in counts
    int32_t  m_whTarget = 0;              // where the trapezoid is heading
    double   m_whCmd = 0.0, m_whVel = 0.0;// profile position / speed (counts, counts/s)
    int      m_whSlot = -1;               // slot at rest, -1 = between slots
    int      m_whPendSlot = -1;           // requested before the drive was enabled
    int      m_whReady = 0;               // consecutive cycles in ready-to-switch-on
    double   m_whTripT = 0.0;             // time in the current state (trip: quick stop, then disable)

    // mirrored telemetry (written only in cyclic thread)
    DigitalIn m_din;
    std::atomic<bool> m_shutdownBit{false};   // cyclic-thread write, main-thread read
    int32_t   m_echo = 0;
    int       m_wkcFails = 0;

    // The drive's 17-bit absolute multiturn encoder wakes up at an arbitrary
    // count. The pose at OP entry becomes axis zero — otherwise the first
    // setpoint (0°) commands a violent snap. Hand-rotating the shaft while
    // xylod runs shifts reality, not the reference: re-start to re-zero.
    int32_t m_zeroCounts = 0;
};
