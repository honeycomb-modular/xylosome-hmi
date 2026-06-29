// EcBackend.cpp — SOEM master implementation.
#include "EcBackend.h"
#include "Cia402.h"
#include "Log.h"

#include <ethercat.h>     // SOEM

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>

static char s_ioMap[4096];

// ── unit conversion ───────────────────────────────────────────────────────────
// Positions are zero-referenced to the wake-up pose (absolute multiturn
// encoder reads arbitrary counts at power-on); velocities are scale-only.
double EcBackend::countsToDegRel(int32_t c) const {
    const double cpd = m_cfg.motorCountsPerRev * m_cfg.gearRatio / 360.0;
    const double d = double(c) / cpd;
    return m_cfg.invertAxis ? -d : d;
}
double EcBackend::countsToDeg(int32_t c) const {
    return countsToDegRel(int32_t(c - m_zeroCounts));
}
int32_t EcBackend::degToCounts(double d) const {
    const double cpd = m_cfg.motorCountsPerRev * m_cfg.gearRatio / 360.0;
    return int32_t(std::llround((m_cfg.invertAxis ? -d : d) * cpd)) + m_zeroCounts;
}

// ── absolute home ──────────────────────────────────────────────────────────────
// Teach: the current shaft pose becomes 0°, persisted so it survives reboot
// (only meaningful once the drive is in multiturn-absolute mode + battery).
void EcBackend::setHome() {
    if (!m_drvTx) return;
    m_zeroCounts = m_drvTx->actualPos;
    saveHomeCounts(m_zeroCounts);
    LOGI("ec: home taught — current pose is now 0° (%d counts)", int(m_zeroCounts));
}

bool EcBackend::loadHomeCounts(int32_t &out) const {
    FILE *f = std::fopen(m_cfg.homeFile.c_str(), "r");
    if (!f) return false;
    long v = 0;
    const int n = std::fscanf(f, "%ld", &v);
    std::fclose(f);
    if (n != 1) return false;
    out = int32_t(v);
    return true;
}

void EcBackend::saveHomeCounts(int32_t v) const {
    const std::string &p = m_cfg.homeFile;
    const auto slash = p.find_last_of('/');
    if (slash != std::string::npos && slash > 0)
        ::mkdir(p.substr(0, slash).c_str(), 0755);   // create state dir; ignore EEXIST
    FILE *f = std::fopen(p.c_str(), "w");
    if (!f) { LOGW("ec: cannot write home file %s — home not persisted", p.c_str()); return; }
    std::fprintf(f, "%ld\n", long(v));
    std::fclose(f);
    LOGI("ec: home offset saved (%d counts) → %s", int(v), p.c_str());
}

// ── SDO helpers ───────────────────────────────────────────────────────────────
template <typename T>
static bool sdoWrite(int slave, uint16_t idx, uint8_t sub, T val) {
    return ec_SDOwrite(slave, idx, sub, FALSE, sizeof(T), &val, EC_TIMEOUTRXM) > 0;
}

// Remap the A6-EC PDOs to a fixed CSP set so DriveRx/DriveTx match exactly.
//   RxPDO 0x1600: 6040:00/16  607A:00/32  6060:00/8
//   TxPDO 0x1A00: 6041:00/16  6064:00/32  606C:00/32  603F:00/16  6061:00/8
bool EcBackend::remapDriveCsp(int s) {
    bool ok = true;
    ok &= sdoWrite<uint8_t >(s, 0x1C12, 0x00, 0);
    ok &= sdoWrite<uint8_t >(s, 0x1C13, 0x00, 0);

    ok &= sdoWrite<uint8_t >(s, 0x1600, 0x00, 0);
    ok &= sdoWrite<uint32_t>(s, 0x1600, 0x01, 0x60400010);
    ok &= sdoWrite<uint32_t>(s, 0x1600, 0x02, 0x607A0020);
    ok &= sdoWrite<uint32_t>(s, 0x1600, 0x03, 0x60600008);
    ok &= sdoWrite<uint8_t >(s, 0x1600, 0x00, 3);

    ok &= sdoWrite<uint8_t >(s, 0x1A00, 0x00, 0);
    ok &= sdoWrite<uint32_t>(s, 0x1A00, 0x01, 0x60410010);
    ok &= sdoWrite<uint32_t>(s, 0x1A00, 0x02, 0x60640020);
    ok &= sdoWrite<uint32_t>(s, 0x1A00, 0x03, 0x606C0020);
    ok &= sdoWrite<uint32_t>(s, 0x1A00, 0x04, 0x603F0010);
    ok &= sdoWrite<uint32_t>(s, 0x1A00, 0x05, 0x60610008);
    ok &= sdoWrite<uint8_t >(s, 0x1A00, 0x00, 5);

    ok &= sdoWrite<uint16_t>(s, 0x1C12, 0x01, 0x1600);
    ok &= sdoWrite<uint8_t >(s, 0x1C12, 0x00, 1);
    ok &= sdoWrite<uint16_t>(s, 0x1C13, 0x01, 0x1A00);
    ok &= sdoWrite<uint8_t >(s, 0x1C13, 0x00, 1);

    if (!ok) LOGE("ec: A6-EC PDO remap failed — check drive manual / slave %d", s);
    return ok;
}

bool EcBackend::busInit() {
    if (!ec_init(m_cfg.ecIface.c_str())) {
        LOGE("ec: ec_init(%s) failed — NIC name? CAP_NET_RAW / root?", m_cfg.ecIface.c_str());
        return false;
    }
    if (ec_config_init(FALSE) <= 0) {
        LOGE("ec: no slaves found on %s", m_cfg.ecIface.c_str());
        return false;
    }
    LOGI("ec: %d slaves found", ec_slavecount);
    for (int i = 1; i <= ec_slavecount; i++)
        LOGI("ec:   %d: %-20s 0x%08x", i, ec_slave[i].name, uint32_t(ec_slave[i].eep_id));

    // Locate the A6-EC drive by its product ID (0x715), wherever it sits — so
    // adding/removing terminals never shifts it out from under us. pos_drive in
    // the conf is now only a fallback if the ID match ever fails.
    m_drivePos = 0;
    for (int i = 1; i <= ec_slavecount; i++)
        if (uint32_t(ec_slave[i].eep_id) == 0x00000715u) { m_drivePos = i; break; }
    if (m_drivePos > 0)
        LOGI("ec: A6-EC drive auto-located at slave %d (product 0x715)", m_drivePos);
    else if (m_cfg.posDrive > 0) {
        m_drivePos = m_cfg.posDrive;
        LOGW("ec: drive 0x715 not found — falling back to pos_drive=%d", m_drivePos);
    } else {
        LOGE("ec: A6-EC drive not found (no product 0x715; pos_drive unset)");
        return false;
    }

    // position ≤ 0 in the conf = device not fitted (bench configs)
    const int need = std::max({m_drivePos, m_cfg.posEk1100, m_cfg.posEl7031,
                               m_cfg.posEl2521, m_cfg.posEl5152, m_cfg.posElDout, m_cfg.posElDin});
    if (ec_slavecount < need) {
        LOGE("ec: expected %d slaves (config positions), found %d", need, ec_slavecount);
        return false;
    }

    // PDO config is legal ONLY in PRE-OP (drive manual 8.3.1) — enforce; an
    // unclean previous exit leaves the drive elsewhere and it rejects remap.
    ec_slave[m_drivePos].state = EC_STATE_PRE_OP;
    ec_writestate(uint16(m_drivePos));
    ec_statecheck(uint16(m_drivePos), EC_STATE_PRE_OP, EC_TIMEOUTSTATE * 4);
    if (ec_slave[m_drivePos].state != EC_STATE_PRE_OP) {
        LOGE("ec: drive not in PRE-OP (al=0x%02x) — power-cycle the drive",
             unsigned(ec_slave[m_drivePos].state));
        return false;
    }

    if (!remapDriveCsp(m_drivePos)) return false;
    sdoWrite<int8_t>(m_drivePos, 0x6060, 0x00, 8);            // CSP
    // SM sync config: DC-SYNC0 at the cycle time. TwinCAT writes these from
    // the ESI; SOEM leaves them to us. Bench-proven vs Er74.1 (DEVLOG
    // 2026-06-12); drive panel C13.05 must be 2 for a userspace master.
    sdoWrite<uint16_t>(m_drivePos, 0x1C32, 0x01, 2);
    sdoWrite<uint32_t>(m_drivePos, 0x1C32, 0x02, uint32_t(m_cfg.cycleUs) * 1000u);
    sdoWrite<uint16_t>(m_drivePos, 0x1C33, 0x01, 2);
    sdoWrite<uint32_t>(m_drivePos, 0x1C33, 0x02, uint32_t(m_cfg.cycleUs) * 1000u);
    // EL7031 — velocity direct mode (0x8012:01 = 0). Verify on bench.
    if (m_cfg.posEl7031 > 0)
        sdoWrite<uint8_t>(m_cfg.posEl7031, 0x8012, 0x01, 0);

    // DC measurement + SYNC0 BEFORE the SAFE-OP transition — the drive
    // samples its sync configuration on PREOP→SAFEOP.
    ec_configdc();
    ec_dcsync0(uint16(m_drivePos), TRUE, uint32_t(m_cfg.cycleUs) * 1000u, 0);

    ec_config_map(s_ioMap);
    ec_statecheck(0, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 4);

    // ── resolve PDO pointers (position ≤ 0 stays nullptr = feature absent) ───
    auto outOf = [](int s) { return ec_slave[s].outputs; };
    auto inOf  = [](int s) { return ec_slave[s].inputs;  };

    m_drvRx  = reinterpret_cast<DriveRx *>(outOf(m_drivePos));
    m_drvTx  = reinterpret_cast<DriveTx *>(inOf(m_drivePos));
    m_fwRx   = m_cfg.posEl7031 > 0 ? reinterpret_cast<El7031Rx *>(outOf(m_cfg.posEl7031)) : nullptr;
    m_fwTx   = m_cfg.posEl7031 > 0 ? reinterpret_cast<El7031Tx *>(inOf(m_cfg.posEl7031))  : nullptr;
    m_ltRx   = m_cfg.posEl2521 > 0 ? reinterpret_cast<El2521Rx *>(outOf(m_cfg.posEl2521)) : nullptr;
    m_echoIn = m_cfg.posEl5152 > 0 ? reinterpret_cast<uint32_t *>(inOf(m_cfg.posEl5152))  : nullptr;
    m_dout   = m_cfg.posElDout > 0 ? outOf(m_cfg.posElDout) : nullptr;
    m_dinRaw = m_cfg.posElDin  > 0 ? inOf(m_cfg.posElDin)   : nullptr;
    m_shutdownRaw = m_cfg.posShutdown > 0 ? inOf(m_cfg.posShutdown) : nullptr;

    auto check = [](const char *n, int s, int obytes, int ibytes) {
        if (s <= 0) return;                                   // not fitted
        if (int(ec_slave[s].Obytes) < obytes || int(ec_slave[s].Ibytes) < ibytes)
            LOGW("ec: slave %d (%s) PDO size O=%d I=%d — smaller than expected O>=%d I>=%d; "
                 "verify PDO assignment", s, n, int(ec_slave[s].Obytes), int(ec_slave[s].Ibytes),
                 obytes, ibytes);
    };
    check("A6-EC",  m_drivePos,  int(sizeof(DriveRx)),  int(sizeof(DriveTx)));
    check("EL7031", m_cfg.posEl7031, int(sizeof(El7031Rx)), int(sizeof(El7031Tx)));
    check("EL2521", m_cfg.posEl2521, int(sizeof(El2521Rx)), 0);
    check("EL5152", m_cfg.posEl5152, 0, 4);
    check("ELxxxx-dout", m_cfg.posElDout, 1, 0);
    check("ELxxxx-din",  m_cfg.posElDin,  0, 1);

    if (int(ec_slave[m_drivePos].Obytes) != int(sizeof(DriveRx)) ||
        int(ec_slave[m_drivePos].Ibytes) != int(sizeof(DriveTx))) {
        LOGE("ec: drive process image mismatch O=%d I=%d (want %zu/%zu) — refusing to run",
             int(ec_slave[m_drivePos].Obytes), int(ec_slave[m_drivePos].Ibytes),
             sizeof(DriveRx), sizeof(DriveTx));
        return false;
    }

    mlockall(MCL_CURRENT | MCL_FUTURE);
    // The OP transition happens in the cyclic thread: the drive needs frames
    // GAP-FREE at the cycle time from before the OP request (Er74.1 otherwise),
    // and a thread handoff after OP would be exactly such a gap.
    LOGI("ec: SAFE-OP — handing off to phase-locked cyclic thread");
    return true;
}

bool EcBackend::start(CycleFn cycle) {
    if (!busInit()) return false;
    m_running = true;
    m_thread = std::thread([this, cycle] { cyclicLoop(cycle); });   // sets m_op at OP
    return true;
}

void EcBackend::shutdown() {
    if (!m_running) return;
    m_running = false;
    if (m_thread.joinable()) m_thread.join();
    if (m_drivePos > 0) ec_dcsync0(uint16(m_drivePos), FALSE, 0, 0);
    ec_slave[0].state = EC_STATE_INIT;       // clean slate: PDO remap needs PRE-OP
    ec_writestate(0);
    ec_close();
    m_op = false;
}

// ── control-context accessors ────────────────────────────────────────────────
void EcBackend::axisSetTargetDeg(double deg) {
    m_targetDeg = std::min(m_cfg.softMaxDeg, std::max(m_cfg.softMinDeg, deg));
    m_targetValid = true;
}
double EcBackend::axisPosDeg()  const { return m_drvTx ? countsToDeg(m_drvTx->actualPos) : 0.0; }
double EcBackend::axisVelDegS() const { return m_drvTx ? countsToDegRel(m_drvTx->actualVel) : 0.0; }

DriveState EcBackend::drive() const {
    DriveState d;
    if (m_drvTx) {
        d.statusword = m_drvTx->statusword;
        d.errorCode  = m_drvTx->errorCode;
        d.opModeDisp = m_drvTx->opModeDisp;
        const auto st = cia402::state(d.statusword);
        d.enabled = (st == cia402::State::OperationEnabled);
        d.fault   = (st == cia402::State::Fault || st == cia402::State::FaultReactionActive);
    }
    return d;
}

void EcBackend::fwMoveToSlot(int slot) {
    slot = std::max(0, std::min(3, slot));
    if (!m_fwRx) {                      // filter hardware not fitted: instant
        m_fwSlot = slot;                // "arrival" so sequences don't stall
        m_fwBusy = false;
        return;
    }
    // shortest path around the wheel
    const double rev = m_cfg.fwStepsPerRev;
    double target = m_cfg.fwSlotOffset[slot] * rev;
    double cur = std::fmod(m_fwPosSteps, rev); if (cur < 0) cur += rev;
    double delta = target - cur;
    if (delta >  rev / 2) delta -= rev;
    if (delta < -rev / 2) delta += rev;
    m_fwTargetSteps = m_fwPosSteps + delta;
    m_fwSlot = slot;
    m_fwBusy = true;
}

void EcBackend::setLineHz(double hz) {
    m_lineHzCmd = std::max(0.0, std::min(m_cfg.lineMaxHz, hz));
}

// ── cyclic ───────────────────────────────────────────────────────────────────
void EcBackend::readInputs() {
    if (m_dinRaw) {
        const uint8_t b = *m_dinRaw;
        auto bit = [&](int i) { return (b >> i) & 1; };
        m_din.home    = bit(m_cfg.diHome);
        m_din.endMin  = bit(m_cfg.diEndMin);
        m_din.endMax  = bit(m_cfg.diEndMax);
        m_din.fwIndex = bit(m_cfg.diFwIndex);
        const bool raw = bit(m_cfg.diEstop);
        m_din.estopOk = m_cfg.estopActiveLow ? raw : !raw;   // active-low: HIGH = safe
    }
    if (m_echoIn) m_echo = int32_t(*m_echoIn);
    if (m_shutdownRaw) m_shutdownBit = ((*m_shutdownRaw >> m_cfg.diShutdown) & 1) != 0;
}

void EcBackend::fwCycle(double dt) {
    // trapezoidal SW position loop → velocity command on the EL7031
    const double err = m_fwTargetSteps - m_fwPosSteps;
    if (m_fwBusy && std::fabs(err) < 2.0 && std::fabs(m_fwVelCmd) < 1.0) {
        m_fwBusy = false; m_fwVelCmd = 0.0;
    }
    if (m_fwBusy) {
        const double dir   = err > 0 ? 1.0 : -1.0;
        const double vStop = std::sqrt(2.0 * m_cfg.fwAccStepsS2 * std::fabs(err));
        double vWant = dir * std::min({m_cfg.fwVelStepsS, vStop});
        const double dvMax = m_cfg.fwAccStepsS2 * dt;
        m_fwVelCmd += std::max(-dvMax, std::min(dvMax, vWant - m_fwVelCmd));
    } else {
        m_fwVelCmd = 0.0;
    }
    m_fwPosSteps += m_fwVelCmd * dt;   // open-loop integration (stepper)

    if (m_fwRx) {
        m_fwRx->ctrl = 0x0001;                       // enable
        // EL7031 velocity is int16, ±32767 = ±max (terminal CoE speed range)
        const double frac = m_fwVelCmd / m_cfg.fwVelStepsS;
        m_fwRx->velocity = int16_t(std::max(-1.0, std::min(1.0, frac)) * 32767.0);
    }
}

void EcBackend::writeOutputs() {
    if (m_drvRx && m_drvTx) {
        if (!m_targetValid) m_targetDeg = axisPosDeg();   // bumpless until first cmd
        m_drvRx->opMode    = 8;                           // CSP
        m_drvRx->targetPos = degToCounts(m_targetDeg);
        m_drvRx->controlword = cia402::step(m_drvTx->statusword, m_wantEnable, m_faultReset);
        m_faultReset = false;
    }
    if (m_ltRx) {
        m_ltRx->ctrl = 0;
        const double frac = m_lineHzCmd / m_cfg.el2521BaseHz;
        m_ltRx->freqVal = int16_t(std::max(0.0, std::min(1.0, frac)) * 32767.0);
    }
    if (m_dout) {
        uint8_t b = 0;
        if (m_passActive) b |= (1 << m_cfg.doPassActive);
        if (m_passIndex)  b |= (1 << m_cfg.doPassIndex);
        if (m_lineBlink)  b |= (1 << m_cfg.doLineBlink);
        *m_dout = b;
    }
}

void EcBackend::cyclicLoop(CycleFn cycle) {
    if (m_cfg.rtPrio > 0) {
        sched_param sp{}; sp.sched_priority = m_cfg.rtPrio;
        if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp))
            LOGW("ec: SCHED_FIFO %d failed (run as root / set limits) — continuing best-effort",
                 m_cfg.rtPrio);
    }

    const long periodNs = long(m_cfg.cycleUs) * 1000L;
    const double dt = m_cfg.cycleUs * 1e-6;

    // DC phase alignment (classic SOEM PI): frames gap-free at the cycle time,
    // aimed ~1/4 cycle after SYNC0. Required by the A6-EC (Er74.1 otherwise).
    int64 toff = 0, integral = 0;
    auto dcAlign = [&]() {
        int64 delta = (ec_DCtime - periodNs / 4) % periodNs;
        if (delta > periodNs / 2) delta -= periodNs;
        integral += (delta > 0) - (delta < 0);
        toff = -(delta / 100) - (integral / 20);
    };
    timespec next; clock_gettime(CLOCK_MONOTONIC, &next);
    auto cycleSleep = [&]() {
        long ns = next.tv_nsec + periodNs + long(toff);
        next.tv_sec += ns / 1000000000L; ns %= 1000000000L;
        if (ns < 0) { ns += 1000000000L; next.tv_sec--; }
        next.tv_nsec = ns;
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, nullptr);
    };

    // phase-lock in SAFE-OP, then request OP without ever pausing frames
    for (int i = 0; i < 500 && m_running; i++) {
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        dcAlign(); cycleSleep();
    }
    ec_slave[0].state = EC_STATE_OPERATIONAL;
    ec_writestate(0);
    for (int w = 0; w < 5000 && m_running && ec_slave[0].state != EC_STATE_OPERATIONAL; w++) {
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        dcAlign(); cycleSleep();
        if (w % 200 == 199) ec_readstate();
    }
    if (ec_slave[0].state != EC_STATE_OPERATIONAL) {
        LOGE("ec: segment did not reach OPERATIONAL");
        m_op = false;
        return;
    }
    // Absolute home: with the drive in multiturn-absolute mode (C00.07=2) + battery,
    // a taught offset maps to the same physical 0° every boot. No home file yet =
    // fall back to wake-zero (current pose becomes 0°). Either way the sequencer
    // adopts actual position as its setpoint on cycle 1, so no boot snap.
    int32_t savedHome = 0;
    if (loadHomeCounts(savedHome)) {
        m_zeroCounts = savedHome;
        LOGI("ec: absolute home loaded (%d counts) from %s", int(savedHome), m_cfg.homeFile.c_str());
    } else if (m_drvTx) {
        m_zeroCounts = m_drvTx->actualPos;
        LOGI("ec: no home file (%s) — wake-zero to current pose", m_cfg.homeFile.c_str());
    }
    m_op = true;
    LOGI("ec: OPERATIONAL (phase-locked) — cycle %d us, axis zero @ %d counts",
         m_cfg.cycleUs, int(m_zeroCounts));

    const int expectedWkc = ec_group[0].outputsWKC * 2 + ec_group[0].inputsWKC;

    while (m_running) {
        ec_send_processdata();
        const int wkc = ec_receive_processdata(EC_TIMEOUTRET);

        if (wkc < expectedWkc) {
            if (++m_wkcFails == 10) { LOGE("ec: working counter low (%d<%d) — segment degraded",
                                            wkc, expectedWkc); m_op = false; }
        } else {
            if (m_wkcFails >= 10) { LOGI("ec: working counter recovered"); m_op = true; }
            m_wkcFails = 0;
        }

        readInputs();
        fwCycle(dt);
        cycle(dt);           // Sequencer: consumes inputs, sets targets
        writeOutputs();

        dcAlign(); cycleSleep();
    }

    // safe exit: drop torque request, zero outputs
    if (m_drvRx) m_drvRx->controlword = 0x0006;
    if (m_dout)  *m_dout = 0;
    if (m_ltRx)  m_ltRx->freqVal = 0;
    ec_send_processdata();
    ec_receive_processdata(EC_TIMEOUTRET);
}
