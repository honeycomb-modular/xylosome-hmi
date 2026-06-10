#pragma once
// SimBackend.h — software twin of the EtherCAT segment. `xylod --sim`.
// The scan axis tracks its CSP target through a 1st-order lag, the filter
// wheel "moves" at fwVelStepsS, DIs are permanently safe. Lets the full
// Pi-HMI ⇄ xylod protocol run on any laptop.
#include "Backend.h"
#include "Config.h"
#include <atomic>
#include <thread>

class SimBackend : public IBackend {
public:
    explicit SimBackend(const Config &cfg) : m_cfg(cfg) {}
    ~SimBackend() override { shutdown(); }

    bool start(CycleFn cycle) override;
    void shutdown() override;
    bool operational() const override { return m_running; }

    void   axisEnable(bool on) override { m_enabled = on; }
    void   axisFaultReset() override {}
    void   axisSetTargetDeg(double deg) override { m_target = deg; }
    double axisPosDeg() const override { return m_pos; }
    double axisVelDegS() const override { return m_vel; }
    DriveState drive() const override {
        DriveState d; d.enabled = m_enabled;
        d.statusword = m_enabled ? 0x1237 : 0x1231;
        return d;
    }

    void fwMoveToSlot(int slot) override { m_fwTarget = slot; m_fwTimer = 0.4; }
    bool fwBusy() const override { return m_fwTimer > 0.0; }
    int  fwSlot() const override { return fwBusy() ? -1 : m_fwTarget; }

    void setLineHz(double hz) override { m_lineHz = hz; }
    double lineHz() const override { return m_lineHz; }

    DigitalIn din() const override { DigitalIn d; d.estopOk = true; return d; }
    void setPassActive(bool on) override { m_passActive = on; }
    void setPassIndex(bool) override {}

    int32_t echoCounts() const override { return int32_t(m_pos * 1000.0); }

private:
    void loop(CycleFn cycle);

    const Config &m_cfg;
    std::atomic<bool> m_running{false};
    std::thread m_thread;

    bool   m_enabled = false, m_passActive = false;
    double m_target = 0.0, m_pos = 0.0, m_vel = 0.0, m_lineHz = 0.0;
    int    m_fwTarget = 3;
    double m_fwTimer = 0.0;
};
