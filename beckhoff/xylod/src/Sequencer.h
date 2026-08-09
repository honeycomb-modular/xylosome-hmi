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
    double lineTarget   = 0.0;     // wanted lines over the arc; 0 = use lineBaseHz
    std::vector<double> profile;   // uniform samples, 0..1

    // ── static hold ──────────────────────────────────────────────────────────
    // The flange stays put and the camera scans lines anyway, so the pass is
    // measured in SECONDS, not degrees — the arc that paces a normal scan has
    // nothing to pace here. arcStartDeg is the pose to hold (the HMI sends the
    // current position, so nothing moves). Every event the capture side sees —
    // pass_start / pass_end / pass_active / the index pulse — is unchanged.
    bool   staticHold  = false;
    double durationS   = 0.0;      // pass length; required when staticHold

    // ── multi-pass structure ─────────────────────────────────────────────────
    // passCount 0 keeps the colorMode behaviour (1 BW pass / 4 colour passes).
    // An explicit N runs N passes, which is what stacking, exposure bracketing
    // and sub-pixel dithering all need and none of them could ask for before.
    int    passCount     = 0;
    // Shifts the whole arc by (pass * passOffsetDeg). Sub-pixel dither: the
    // passes are the same sweep nudged a fraction of a pixel apart.
    double passOffsetDeg = 0.0;
    // -1 keeps the per-pass filter walk (R/G/B/C). >= 0 pins one slot for every
    // pass, so an N-pass stack does not drag the wheel round between passes.
    int    filterSlot    = -1;

    // ── time-indexed profile (reversible motion) ─────────────────────────────
    // Normally the profile is indexed by POSITION along the arc, which makes the
    // sweep monotonic by construction — the axis physically cannot turn around,
    // because x = arcS/arc only ever grows. Set timeProfile and the profile is
    // indexed by TIME through the pass instead, and its samples are SIGNED, so
    // negative means reverse. That is what pendulum and party motion need.
    //
    // The pass is then bounded by durationS, not by reaching arcEndDeg (which is
    // meaningless once travel is not monotonic). arcStartDeg is still where the
    // pass begins. Travel is bounded only by the soft limits, so they are
    // enforced every cycle in this mode.
    bool   timeProfile = false;
};

struct SeqCommand {
    enum Type { Enable, Disable, Home, Jog, MoveTo, Filter, Execute,
                Pause, Resume, Stop, FaultReset, SetHome } type;
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
    int    plannedLines = 0;       // lines this pass will deliver (0 = not a curve scan)
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
    bool shutdownInput() const     { return m_bk.shutdownPressed(); }   // raw DI, main-thread poll
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

    void startMove(double target, double vel, double accel = 0.0);   // accel<=0 → scan accel
    bool stepMove(double dt);                 // trapezoid toward m_moveTarget
    void enterPass(int pass);
    double passArcStart() const;              // arcStartDeg shifted by the pass offset
    double profileAt(double x) const;         // linear interp; samples may be signed
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
    double m_dwellS = 0.0;          // elapsed time within pass, s (static hold)
    double m_setpoint = 0.0;        // current CSP target, output deg
    bool   m_spInit = false;        // adopt actual pos as setpoint on 1st OP cycle (no boot snap)
    double m_moveTarget = 0.0, m_moveVel = 0.0, m_moveVelMax = 10.0;
    double m_moveAcc = 0.0;        // accel for the current point-to-point move (set by startMove)
    double m_jogVel = 0.0;
    double m_settleLeft = 0.0;
    double m_meanAbsProfile = 1.0;  // mean |profile|, time-indexed passes only
    double m_lineCount  = 0.0;      // accumulated scanned lines this sequence
    int    m_plannedLines = 0;      // lines each pass will deliver, after the rate clamp
    long   m_blinkTick  = 0;        // last line_blink_div boundary crossed
    double m_blinkLeft  = 0.0;      // remaining pulse time, s
    double m_pauseRamp = 1.0;       // 1 running → 0 paused (slewed)
    bool   m_pausing = false;
    double m_indexPulseLeft = 0.0;  // pass_index pulse timer, s
    bool   m_estopLatched = false;
    double m_faultResetHoldS = 0.0; // ignore the drive's fault bit while a reset lands
};
