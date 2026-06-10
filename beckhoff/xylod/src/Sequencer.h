#pragma once
// Sequencer.h — the 4-pass scan state machine. Runs entirely inside the
// backend's cyclic callback (control context). The TCP server hands it
// commands through a mutex-guarded queue; it hands back status snapshots
// and event strings the same way.
//
// One execute =
//   for each pass (R, G, B, C — or single Clear pass in BW mode):
//     filter wheel → channel
//     move axis → arcStart (returnVel)
//     settle
//     pass_index pulse + pass_active high, pass_start event
//     integrate speed profile → CSP setpoints; EL2521 follows velocity
//     pass_active low, pass_end event
//   move axis → arcStart, seq_done
//
// What the artist draws is what executes: the profile arrives pre-sampled
// from the HMI curve editor, untouched here except the velocity floor.

#include "Backend.h"
#include "Config.h"
#include <deque>
#include <mutex>
#include <string>
#include <vector>

struct ScanJob {
    int    colorMode    = 0;       // 0 color (4 passes), 1 BW (1 pass, Clear)
    double arcStartDeg  = 0.0;
    double arcEndDeg    = 90.0;
    double maxVelDegS   = 100.0;
    double minVelDegS   = 1.0;
    double settleMs     = 300.0;
    double returnVelDegS = 40.0;
    bool   lineCurve    = true;    // true: rate ∝ velocity; false: fixed baseHz
    double lineBaseHz   = 5000.0;
    std::vector<double> profile;   // uniform samples, 0..1
};

struct SeqCommand {
    enum Type { Enable, Disable, Home, Jog, MoveTo, Filter, Execute,
                Pause, Resume, Stop, FaultReset } type;
    double  a = 0.0, b = 0.0;      // vel / pos arguments
    int     slot = 0;
    ScanJob job;
};

struct SeqStatus {
    std::string state = "idle";
    bool   operational = false, enabled = false, homed = false, estopOk = true;
    int    pass = -1;
    double progress = 0.0;
    double posDeg = 0.0, velDegS = 0.0, lineHz = 0.0;
    int    filterSlot = -1;
    uint16_t driveSw = 0, driveFault = 0;
    int32_t  echo = 0;
};

class Sequencer {
public:
    Sequencer(const Config &cfg, IBackend &bk) : m_cfg(cfg), m_bk(bk) {}

    // ── server-thread API ────────────────────────────────────────────────────
    void post(const SeqCommand &c) { std::lock_guard<std::mutex> l(m_mx); m_cmds.push_back(c); }
    SeqStatus status() const       { std::lock_guard<std::mutex> l(m_mx); return m_status; }
    std::vector<std::string> drainEvents() {
        std::lock_guard<std::mutex> l(m_mx);
        std::vector<std::string> out(m_events.begin(), m_events.end());
        m_events.clear();
        return out;
    }

    // ── control-context: call once per cycle ─────────────────────────────────
    void cycle(double dt);

private:
    enum class St { Idle, Homing, Moving, Jogging, FilterMove, SeqFilter, SeqReposition,
                    SeqSettle, SeqRun, SeqPaused, Estop, Fault };

    void event(const std::string &json);
    void publish();
    const char *stName(St s) const;

    void startMove(double target, double vel);
    bool stepMove(double dt);                 // trapezoid toward m_moveTarget
    void enterPass(int pass);
    double profileAt(double x) const;         // linear interp, 0..1 → 0..1
    long long nowMs() const;

    const Config &m_cfg;
    IBackend &m_bk;

    mutable std::mutex m_mx;
    std::deque<SeqCommand> m_cmds;
    std::deque<std::string> m_events;
    SeqStatus m_status;

    // motion scratch (control context only)
    St     m_st = St::Idle;
    bool   m_homed = false;
    ScanJob m_job;
    int    m_pass = -1, m_passCount = 4;
    double m_arcS = 0.0;            // distance along arc within pass, deg
    double m_setpoint = 0.0;        // current CSP target, output deg
    double m_moveTarget = 0.0, m_moveVel = 0.0, m_moveVelMax = 10.0;
    double m_jogVel = 0.0;
    double m_settleLeft = 0.0;
    double m_pauseRamp = 1.0;       // 1 running → 0 paused (slewed)
    bool   m_pausing = false;
    double m_indexPulseLeft = 0.0;  // pass_index pulse timer, s
    bool   m_estopLatched = false;
};
