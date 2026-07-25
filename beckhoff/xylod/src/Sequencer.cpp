// Sequencer.cpp — control-context state machine. See Sequencer.h.
#include "Sequencer.h"
#include "Log.h"
#include <algorithm>
#include <chrono>
#include <cmath>

static const char *kFilterNames[4] = {"R", "G", "B", "C"};

long long Sequencer::nowMs() const {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void Sequencer::event(const std::string &json) { m_events.push_back(json); }

const char *Sequencer::stName(St s) const {
    switch (s) {
        case St::Idle:          return "idle";
        case St::Homing:        return "homing";
        case St::Moving:        return "moving";
        case St::Jogging:       return "jogging";
        case St::FilterMove:    return "filter";
        case St::SeqFilter:     return "filter";
        case St::SeqReposition: return "moving";
        case St::SeqSettle:     return "settle";
        case St::SeqRun:        return "running";
        case St::SeqPaused:     return "paused";
        case St::Estop:         return "estop";
        case St::Fault:         return "fault";
    }
    return "?";
}

double Sequencer::profileAt(double x) const {
    const auto &p = m_job.profile;
    if (p.size() < 2) return 1.0;
    x = std::max(0.0, std::min(1.0, x));
    const double f = x * double(p.size() - 1);
    const size_t i = std::min(p.size() - 2, size_t(f));
    const double t = f - double(i);
    return p[i] * (1.0 - t) + p[i + 1] * t;
}

void Sequencer::startMove(double target, double vel, double accel) {
    m_moveTarget = target;
    m_moveVelMax = std::max(0.5, vel);
    m_moveVel = 0.0;
    m_moveAcc = (accel > 0.0) ? accel : m_cfg.accLimitDegS2;
}

// trapezoidal point-to-point on m_setpoint; true when arrived
bool Sequencer::stepMove(double dt) {
    const double err = m_moveTarget - m_setpoint;
    if (std::fabs(err) < 0.005 && std::fabs(m_moveVel) < 0.5) {
        m_setpoint = m_moveTarget;
        m_moveVel = 0.0;
        return true;
    }
    const double dir = err > 0 ? 1.0 : -1.0;
    const double vStop = std::sqrt(2.0 * m_moveAcc * std::fabs(err));
    const double vWant = dir * std::min(m_moveVelMax, vStop);
    const double dvMax = m_moveAcc * dt;
    m_moveVel += std::max(-dvMax, std::min(dvMax, vWant - m_moveVel));
    m_setpoint += m_moveVel * dt;
    return false;
}

void Sequencer::enterPass(int pass) {
    m_pass = pass;
    m_st = St::SeqFilter;
    const int slot = (m_job.colorMode == 1) ? 3 : pass;   // BW → Clear
    m_bk.fwMoveToSlot(slot);
}

void Sequencer::cycle(double dt) {
    // On the first operational cycle, adopt the backend's actual position as the
    // setpoint so we HOLD instead of snapping. Critical with absolute home, where
    // boot position ≠ 0; harmless with wake-zero (actual == 0).
    if (!m_spInit && m_bk.operational()) {
        m_setpoint = m_bk.axisPosDeg();
        m_moveTarget = m_setpoint;
        m_spInit = true;
    }

    // ── drain commands ───────────────────────────────────────────────────────
    std::deque<SeqCommand> cmds;
    { std::lock_guard<std::mutex> l(m_mx); cmds.swap(m_cmds); }

    const DigitalIn din = m_bk.din();
    const DriveState drv = m_bk.drive();

    // ── safety first: E-stop input + drive fault dominate everything ────────
    if (!din.estopOk && m_st != St::Estop) {
        m_estopLatched = true;
        m_bk.axisEnable(false);
        m_bk.setLineHz(0.0);
        m_bk.setPassActive(false);
        m_st = St::Estop;
        event("{\"ev\":\"fault\",\"text\":\"E-stop\"}");
        LOGW("seq: E-STOP");
    }
    // A fault reset is an edge on the controlword; the drive takes a few cycles
    // to drop bit 3. Without this hold the very next cycle re-reads the stale
    // fault bit and re-latches, so every reset had to be sent twice. If the
    // cause is still present the drive stays faulted and we latch again below.
    if (m_faultResetHoldS > 0.0) m_faultResetHoldS -= dt;
    if (drv.fault && m_faultResetHoldS <= 0.0 && m_st != St::Fault && m_st != St::Estop) {
        m_bk.setLineHz(0.0);
        m_bk.setPassActive(false);
        m_st = St::Fault;
        char b[96];
        std::snprintf(b, sizeof b, "{\"ev\":\"fault\",\"text\":\"drive fault 0x%04X\"}", drv.errorCode);
        event(b);
        LOGW("seq: drive fault 0x%04X", drv.errorCode);
    }

    for (const auto &c : cmds) {
        switch (c.type) {
        case SeqCommand::Enable:     m_bk.axisEnable(true);  break;
        case SeqCommand::Disable:    m_bk.axisEnable(false); m_st = St::Idle; break;
        case SeqCommand::FaultReset:
            m_bk.axisFaultReset();
            if (din.estopOk) m_estopLatched = false;
            if (m_st == St::Fault || (m_st == St::Estop && !m_estopLatched)) m_st = St::Idle;
            m_faultResetHoldS = 0.5;
            break;
        case SeqCommand::Stop:
            m_bk.setLineHz(0.0);
            m_bk.setPassActive(false);
            if (m_st != St::Estop && m_st != St::Fault) {
                startMove(m_setpoint, m_moveVelMax);   // decel-in-place via trapezoid
                m_st = St::Idle;
                m_pass = -1;
            }
            break;
        default: break;
        }
        if (m_st == St::Estop || m_st == St::Fault) continue;   // motion cmds blocked

        switch (c.type) {
        case SeqCommand::Home:
            m_bk.axisEnable(true);
            startMove(m_cfg.homeDeg, c.a > 0 ? c.a : m_cfg.homeVelDegS);
            m_st = St::Homing;
            break;
        case SeqCommand::Jog:
            m_bk.axisEnable(true);
            m_jogVel = c.a;
            m_st = (std::fabs(c.a) < 1e-6) ? St::Idle : St::Jogging;
            break;
        case SeqCommand::SetHome:
            // teach current pose as 0° — only at rest; re-sync setpoint so we hold
            if (m_st == St::Idle) {
                m_bk.setHome();
                m_setpoint = m_bk.axisPosDeg();
                m_moveTarget = m_setpoint;
            }
            break;
        case SeqCommand::MoveTo:
            m_bk.axisEnable(true);
            startMove(c.a, c.b > 0 ? c.b : 20.0, m_cfg.jogAccDegS2);   // snappy dial-step jog
            m_st = St::Moving;
            break;
        case SeqCommand::Filter:
            m_bk.fwMoveToSlot(c.slot);
            if (m_st == St::Idle) m_st = St::FilterMove;
            break;
        case SeqCommand::Execute: {
            m_job = c.job;
            // The HMI sets image aspect by line COUNT (the sensor fixes one axis at
            // 8k; the sweep builds the other), so it asks for a total, not a rate.
            // Over a pass, lines = lineBaseHz * arc / maxVelDegS: the sweep duration
            // cancels, because the same velocity that paces the trigger is the one
            // integrated into the arc. So a slower scan does NOT yield more lines —
            // only this rate does. Invert for the rate the artist's aspect implies,
            // then clamp; a clamped rate just means fewer lines, which plannedLines
            // reports so the capture side can size its frame to what will arrive.
            const double arcAbs = std::max(1e-6, std::fabs(m_job.arcEndDeg - m_job.arcStartDeg));
            if (m_job.staticHold) {
                // No sweep to integrate: the artist picks a line count and a
                // duration, so the rate is simply one divided by the other.
                const double want = (m_job.lineTarget > 0.0)
                                  ? m_job.lineTarget / std::max(1e-6, m_job.durationS)
                                  : m_job.lineBaseHz;
                m_job.lineBaseHz = std::min(want, m_cfg.lineMaxHz);
                if (want > m_cfg.lineMaxHz)
                    LOGW("seq: %.0f lines in %.1f s needs %.0f Hz > line_max_hz %.0f "
                         "— clamped, delivering %.0f lines",
                         m_job.lineTarget, m_job.durationS, want, m_cfg.lineMaxHz,
                         m_cfg.lineMaxHz * m_job.durationS);
            }
            else if (m_job.lineCurve && m_job.lineTarget > 0.0) {
                const double want = m_job.lineTarget * m_job.maxVelDegS / arcAbs;
                m_job.lineBaseHz = std::min(want, m_cfg.lineMaxHz);
                if (want > m_cfg.lineMaxHz)
                    LOGW("seq: %.0f lines over %.1f deg needs %.0f Hz > line_max_hz %.0f "
                         "— clamped, delivering %.0f lines",
                         m_job.lineTarget, arcAbs, want, m_cfg.lineMaxHz,
                         m_cfg.lineMaxHz * arcAbs / std::max(1e-6, m_job.maxVelDegS));
            }
            m_plannedLines = m_job.staticHold
                ? int(m_job.lineBaseHz * m_job.durationS + 0.5)
                : m_job.lineCurve
                ? int(m_job.lineBaseHz * arcAbs / std::max(1e-6, m_job.maxVelDegS) + 0.5)
                : 0;   // fixed-rate mode: lines depend on duration, not arc — unknown here
            m_passCount = (m_job.colorMode == 1) ? 1 : 4;
            m_bk.axisEnable(true);
            m_pauseRamp = 1.0; m_pausing = false;
            m_lineCount = 0.0; m_blinkTick = 0; m_blinkLeft = 0.0;
            enterPass(0);
            LOGI("seq: execute — %d pass(es), arc %.1f→%.1f deg, %zu profile samples, "
                 "line %.0f Hz -> %d lines",
                 m_passCount, m_job.arcStartDeg, m_job.arcEndDeg, m_job.profile.size(),
                 m_job.lineBaseHz, m_plannedLines);
            break;
        }
        case SeqCommand::Pause:
            if (m_st == St::SeqRun) { m_pausing = true; m_st = St::SeqPaused; }
            break;
        case SeqCommand::Resume:
            if (m_st == St::SeqPaused) { m_pausing = false; m_st = St::SeqRun; }
            break;
        default: break;
        }
    }

    // ── state machine ────────────────────────────────────────────────────────
    // axisEnable(true) is only a REQUEST: the CiA-402 walk to Operation Enabled
    // takes several cycles. Anything the state machine ramps meanwhile is a CSP
    // target the drive has to swallow whole the moment it enables. With no
    // filter wheel fitted (pos_el7031 = 0) SeqFilter falls through on the next
    // cycle, so [execute] from a cold restart begins the reposition to
    // arcStartDeg — at return velocity, full accel — about 1 ms after the
    // request. Hold the target on the actual pose until the drive really is
    // enabled; the sequence simply waits those few cycles.
    if (!drv.enabled) {
        m_setpoint = m_bk.axisPosDeg();
        m_moveVel  = 0.0;
    }
    // The filter wheel is a separate stepper, so its state still runs.
    const St stRun = (drv.enabled || m_st == St::FilterMove) ? m_st : St::Idle;

    switch (stRun) {
    case St::Idle:
    case St::Estop:
    case St::Fault:
        break;

    case St::Homing:
        if (stepMove(dt)) {
            m_homed = true;
            m_st = St::Idle;
            event("{\"ev\":\"homed\"}");
        }
        break;

    case St::Moving:
        if (stepMove(dt)) m_st = St::Idle;
        break;

    case St::Jogging: {
        const double dvMax = m_cfg.jogAccDegS2 * dt;
        m_moveVel += std::max(-dvMax, std::min(dvMax, m_jogVel - m_moveVel));
        m_setpoint += m_moveVel * dt;
        m_setpoint = std::min(m_cfg.softMaxDeg, std::max(m_cfg.softMinDeg, m_setpoint));
        break;
    }

    case St::FilterMove:
        if (!m_bk.fwBusy()) m_st = St::Idle;
        break;

    case St::SeqFilter:
        if (!m_bk.fwBusy()) {
            startMove(m_job.arcStartDeg, m_job.returnVelDegS);
            m_st = St::SeqReposition;
        }
        break;

    case St::SeqReposition:
        if (stepMove(dt)) {
            m_settleLeft = m_job.settleMs * 1e-3;
            m_st = St::SeqSettle;
        }
        break;

    case St::SeqSettle:
        m_settleLeft -= dt;
        if (m_settleLeft <= 0.0) {
            m_arcS = 0.0;
            m_dwellS = 0.0;
            m_bk.setPassActive(true);
            m_bk.setPassIndex(true);
            m_indexPulseLeft = 0.050;
            const int slot = (m_job.colorMode == 1) ? 3 : m_pass;
            char b[128];
            std::snprintf(b, sizeof b,
                "{\"ev\":\"pass_start\",\"pass\":%d,\"filter\":\"%s\",\"tMs\":%lld}",
                m_pass, kFilterNames[slot], nowMs());
            event(b);
            m_st = St::SeqRun;
        }
        break;

    case St::SeqPaused:
    case St::SeqRun: {
        // pause ramp: slew 1→0 (paused) or 0→1 (running) in ~250 ms
        const double rampTarget = (m_st == St::SeqPaused) ? 0.0 : 1.0;
        const double dr = dt / 0.25;
        m_pauseRamp += std::max(-dr, std::min(dr, rampTarget - m_pauseRamp));

        double lineHzNow = 0.0;
        bool   passDone  = false;

        if (m_job.staticHold) {
            // Hold the pose and run the trigger flat; the pass ends on the clock.
            // Paused time does not count, so a pause lengthens the wall-clock
            // capture without shortening the image.
            m_setpoint = m_job.arcStartDeg;
            lineHzNow  = m_job.lineBaseHz * m_pauseRamp;
            m_dwellS  += dt * m_pauseRamp;
            passDone   = m_dwellS >= m_job.durationS;
        } else {
            const double arc = m_job.arcEndDeg - m_job.arcStartDeg;     // signed
            const double arcAbs = std::max(1e-6, std::fabs(arc));
            const double x = m_arcS / arcAbs;                            // 0..1
            const double vProf = std::max(m_job.minVelDegS,
                                          profileAt(x) * m_job.maxVelDegS);
            const double v = vProf * m_pauseRamp;
            m_arcS += v * dt;
            m_setpoint = m_job.arcStartDeg + (arc > 0 ? m_arcS : -m_arcS);

            // line trigger follows the velocity (the third creative axis)
            lineHzNow = m_job.lineCurve
                ? m_job.lineBaseHz * (v / std::max(1e-6, m_job.maxVelDegS))
                : (m_st == St::SeqRun ? m_job.lineBaseHz : 0.0);
            passDone = m_arcS >= arcAbs;
        }
        m_bk.setLineHz(lineHzNow);

        // line-count blink: a snappy pulse every line_blink_div scanned lines
        if (m_st == St::SeqRun && m_cfg.lineBlinkDiv > 0.0) {
            m_lineCount += lineHzNow * dt;
            const long tick = long(m_lineCount / m_cfg.lineBlinkDiv);
            if (tick != m_blinkTick) { m_blinkTick = tick; m_blinkLeft = m_cfg.lineBlinkMs * 1e-3; }
        }

        if (passDone) {
            if (!m_job.staticHold) m_setpoint = m_job.arcEndDeg;
            m_bk.setLineHz(0.0);
            m_bk.setPassActive(false);
            char b[96];
            std::snprintf(b, sizeof b, "{\"ev\":\"pass_end\",\"pass\":%d,\"tMs\":%lld}",
                          m_pass, nowMs());
            event(b);

            if (m_pass + 1 < m_passCount) {
                enterPass(m_pass + 1);
            } else {
                startMove(m_job.arcStartDeg, m_job.returnVelDegS);
                m_st = St::Moving;
                m_pass = -1;
                char e[64];
                std::snprintf(e, sizeof e, "{\"ev\":\"seq_done\",\"passes\":%d}", m_passCount);
                event(e);
            }
        }
        break;
    }
    }

    // pass_index pulse shaping
    if (m_indexPulseLeft > 0.0) {
        m_indexPulseLeft -= dt;
        if (m_indexPulseLeft <= 0.0) m_bk.setPassIndex(false);
    }

    // line-count blink pulse (drives the EL2008 channel LED / a light)
    if (m_blinkLeft > 0.0) m_blinkLeft -= dt;
    m_bk.setLineBlink(m_blinkLeft > 0.0);

    // ── push setpoint + publish status ───────────────────────────────────────
    m_bk.axisSetTargetDeg(m_setpoint);
    publish();
}

void Sequencer::publish() {
    SeqStatus s;
    s.state       = stName(m_st);
    s.operational = m_bk.operational();
    const DriveState d = m_bk.drive();
    s.enabled    = d.enabled;
    s.homed      = m_homed;
    s.estopOk    = m_bk.din().estopOk;
    s.pass       = m_pass;
    s.posDeg     = m_bk.axisPosDeg();
    s.velDegS    = m_bk.axisVelDegS();
    s.lineHz     = m_bk.lineHz();
    s.plannedLines = m_plannedLines;
    s.filterSlot = m_bk.fwSlot();
    s.driveSw    = d.statusword;
    s.driveFault = d.errorCode;
    s.echo       = m_bk.echoCounts();
    if (m_st == St::SeqRun || m_st == St::SeqPaused) {
        if (m_job.staticHold) {
            s.progress = std::min(1.0, m_dwellS / std::max(1e-6, m_job.durationS));
        } else {
            const double arcAbs = std::max(1e-6, std::fabs(m_job.arcEndDeg - m_job.arcStartDeg));
            s.progress = std::min(1.0, m_arcS / arcAbs);
        }
    }
    std::lock_guard<std::mutex> l(m_mx);
    m_status = std::move(s);
}
