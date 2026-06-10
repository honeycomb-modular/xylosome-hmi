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
    void   axisFaultReset() override { m_faultReset = true; }
    void   axisSetTargetDeg(double deg) override;
    double axisPosDeg() const override;
    double axisVelDegS() const override;
    DriveState drive() const override;

    void fwMoveToSlot(int slot) override;
    bool fwBusy() const override { return m_fwBusy; }
    int  fwSlot() const override { return m_fwBusy ? -1 : m_fwSlot; }

    void setLineHz(double hz) override;
    double lineHz() const override { return m_lineHzCmd; }

    DigitalIn din() const override { return m_din; }
    void setPassActive(bool on) override { m_passActive = on; }
    void setPassIndex(bool on) override { m_passIndex = on; }

    int32_t echoCounts() const override { return m_echo; }

private:
    bool busInit();                       // config_init/map, PDO remap, → OP
    bool remapDriveCsp(int slave);        // SDO remap 0x1600/0x1A00 for CSP
    void cyclicLoop(CycleFn cycle);
    void readInputs();
    void writeOutputs();
    void fwCycle(double dt);              // filter-wheel SW position loop

    double countsToDeg(int32_t c) const;
    int32_t degToCounts(double d) const;

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

    // ── control-context state ────────────────────────────────────────────────
    bool   m_wantEnable = false;
    bool   m_faultReset = false;
    double m_targetDeg  = 0.0;
    bool   m_targetValid = false;         // until first set, echo actual back
    bool   m_passActive = false, m_passIndex = false;
    double m_lineHzCmd  = 0.0;

    // filter wheel
    bool   m_fwBusy = false;
    int    m_fwSlot = 3;                  // assume parked on Clear at boot
    double m_fwPosSteps = 0.0, m_fwTargetSteps = 0.0, m_fwVelCmd = 0.0;

    // mirrored telemetry (written only in cyclic thread)
    DigitalIn m_din;
    int32_t   m_echo = 0;
    int       m_wkcFails = 0;
};
