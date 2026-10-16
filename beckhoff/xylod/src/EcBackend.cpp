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

static long sdoRead32(int slave, uint16_t idx, uint8_t sub) {
    uint32_t v = 0; int sz = sizeof(v);
    return ec_SDOread(slave, idx, sub, FALSE, &sz, &v, EC_TIMEOUTRXM) > 0 ? long(v) : -1;
}

// ── colour wheel: EL7211-9014 PDO + sync + gains ─────────────────────────────
// Bench recipe (motionbox QUIRKS "SOLVED: bringing the EL7211-9014 to
// OPERATION ENABLED", el7211_csp.cpp). Called twice: in PRE-OP before the map,
// and again after the INIT walk-back, because a trip through INIT resets the
// PDO assignment, the mode and the sync mode (diag 0x8146 otherwise).
static bool wheelAssign(int s, const Config &c) {
    const uint32_t cyc = uint32_t(c.cycleUs) * 1000u;
    bool ok = true;
    ok &= sdoWrite<uint8_t >(s, 0x1C12, 0, 0);
    ok &= sdoWrite<uint16_t>(s, 0x1C12, 1, 0x1600);      // controlword
    ok &= sdoWrite<uint16_t>(s, 0x1C12, 2, 0x1606);      // target POSITION
    ok &= sdoWrite<uint8_t >(s, 0x1C12, 0, 2);
    ok &= sdoWrite<uint8_t >(s, 0x1C13, 0, 0);
    ok &= sdoWrite<uint16_t>(s, 0x1C13, 1, 0x1A00);      // FB position
    ok &= sdoWrite<uint16_t>(s, 0x1C13, 2, 0x1A01);      // statusword
    ok &= sdoWrite<uint16_t>(s, 0x1C13, 3, 0x1A03);      // torque actual
    ok &= sdoWrite<uint8_t >(s, 0x1C13, 0, 3);
    ok &= sdoWrite<uint8_t >(s, 0x7010, 0x03, 8);        // CSP
    ok &= sdoWrite<uint16_t>(s, 0x1C32, 1, 2);           // SM2 on DC SYNC0 (SM3 left default)
    ok &= sdoWrite<uint32_t>(s, 0x1C32, 2, cyc);
    ok &= sdoWrite<uint32_t>(s, 0x1C33, 2, cyc);
    // Tuned with the half wheel fitted. Written every start so a power cycle
    // can never quietly hand back the bare-shaft gains that made it ring.
    ok &= sdoWrite<uint32_t>(s, 0x8010, 0x15, uint32_t(c.wheelVelGain));
    ok &= sdoWrite<uint32_t>(s, 0x8010, 0x17, uint32_t(c.wheelPosGain));
    ok &= sdoWrite<uint32_t>(s, 0x8010, 0x31, uint32_t(c.wheelVelLimitRpm));
    return ok;
}

bool EcBackend::wheelPreop(int s) {
    ec_readstate();
    if (ec_slave[s].state & EC_STATE_ERROR) {             // AL errors latch — ack first
        ec_slave[s].state = EC_STATE_INIT + EC_STATE_ACK;
        ec_writestate(uint16(s));
        ec_statecheck(uint16(s), EC_STATE_INIT, EC_TIMEOUTSTATE * 4);
    }
    ec_slave[s].state = EC_STATE_PRE_OP;
    ec_writestate(uint16(s));
    ec_statecheck(uint16(s), EC_STATE_PRE_OP, EC_TIMEOUTSTATE * 4);
    if (ec_slave[s].state != EC_STATE_PRE_OP) {
        LOGE("ec: wheel slave %d not in PRE-OP (0x%02x)", s, unsigned(ec_slave[s].state));
        return false;
    }
    const long rated = sdoRead32(s, 0x8011, 0x12);
    if (rated != m_cfg.wheelRatedMa) {
        LOGE("ec: wheel motor settings missing — 0x8011:12 rated current %ld mA, expected %d "
             "(run el7211_autoconf --write)", rated, m_cfg.wheelRatedMa);
        return false;
    }
    m_whCpr = sdoRead32(s, 0x9008, 0x12);
    if (m_whCpr <= 0) { LOGE("ec: wheel counts/rev 0x9008:12 unreadable"); return false; }

    m_whRedSt = -1;
    if (FILE *f = std::fopen(m_cfg.wheelRedFile.c_str(), "r")) {
        long long v = -1;
        if (std::fscanf(f, "%lld", &v) == 1 && v >= 0 && v < m_whCpr) m_whRedSt = v;
        std::fclose(f);
    }
    if (m_whRedSt < 0) {
        LOGE("ec: wheel has no red home (%s) — teach it: el7211_csp ... --teach-red",
             m_cfg.wheelRedFile.c_str());
        return false;
    }
    if (!(m_cfg.wheelWindowDeg > 0.0 && m_cfg.wheelTripDeg > m_cfg.wheelWindowDeg &&
          m_cfg.wheelTripDeg < 90.0)) {
        LOGE("ec: wheel window %.1f / trip %.1f deg invalid (need 0 < window < trip < 90)",
             m_cfg.wheelWindowDeg, m_cfg.wheelTripDeg);
        return false;
    }
    for (int k = 0; k < 4; k++)
        if (!std::isnan(m_cfg.wheelSlotDeg[k]) && std::fabs(m_cfg.wheelSlotDeg[k]) > m_cfg.wheelWindowDeg) {
            LOGE("ec: wheel slot %d at %.1f deg lies outside the %.1f deg window",
                 k, m_cfg.wheelSlotDeg[k], m_cfg.wheelWindowDeg);
            return false;
        }
    m_whWin  = int32_t(m_cfg.wheelWindowDeg / 360.0 * double(m_whCpr));
    m_whTrip = int32_t(m_cfg.wheelTripDeg   / 360.0 * double(m_whCpr));

    if (!wheelAssign(s, m_cfg)) { LOGE("ec: wheel PDO/sync/gain config rejected"); return false; }
    LOGI("ec: wheel EL7211-9014 at slave %d — red %lld/%lld, window %.0f, trip %.0f deg, "
         "%.0f rpm %.1f rev/s^2, gains %d/%d", s, m_whRedSt, m_whCpr, m_cfg.wheelWindowDeg,
         m_cfg.wheelTripDeg, m_cfg.wheelVelRpm, m_cfg.wheelAccRps2,
         m_cfg.wheelVelGain, m_cfg.wheelPosGain);
    return true;
}

// The EL7211 validates DC on PRE-OP -> SAFE-OP, and ec_config_map() already
// requested SAFE-OP without SYNC running, so it sits latched (AL 0x0035). Walk
// it back, re-apply, let DC time propagate, arm SYNC0+SYNC1 with the ESI's
// 30 us shift, and only then ask for SAFE-OP again — with frames flowing.
bool EcBackend::wheelArmDc(int s) {
    const uint32_t cyc = uint32_t(m_cfg.cycleUs) * 1000u;
    auto frames = [&](int n) {
        for (int i = 0; i < n; i++) {
            ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
            timespec ts{0, long(cyc)}; nanosleep(&ts, nullptr);
        }
    };
    ec_slave[s].state = EC_STATE_INIT + EC_STATE_ACK;
    ec_writestate(uint16(s));
    ec_statecheck(uint16(s), EC_STATE_INIT, EC_TIMEOUTSTATE * 4);
    ec_slave[s].state = EC_STATE_PRE_OP;
    ec_writestate(uint16(s));
    ec_statecheck(uint16(s), EC_STATE_PRE_OP, EC_TIMEOUTSTATE * 4);
    if (!wheelAssign(s, m_cfg)) { LOGE("ec: wheel re-assign after INIT failed"); return false; }

    // Runaway guard: the default Rx set reads our 4-byte target as a VELOCITY.
    const long rx1 = sdoRead32(s, 0x1C12, 1), rx2 = sdoRead32(s, 0x1C12, 2);
    const long mode = sdoRead32(s, 0x7010, 0x03);
    if ((rx1 & 0xFFFF) != 0x1600 || (rx2 & 0xFFFF) != 0x1606 || (mode & 0xFF) != 8) {
        LOGE("ec: wheel mapping NOT position — 0x1C12=[0x%04lx,0x%04lx] mode %ld; refusing",
             rx1 & 0xFFFF, rx2 & 0xFFFF, mode & 0xFF);
        return false;
    }
    if (int(ec_slave[s].Obytes) != int(sizeof(WheelRx)) || int(ec_slave[s].Ibytes) != int(sizeof(WheelTx))) {
        LOGE("ec: wheel process image O=%d I=%d (want %zu/%zu); refusing",
             int(ec_slave[s].Obytes), int(ec_slave[s].Ibytes), sizeof(WheelRx), sizeof(WheelTx));
        return false;
    }
    frames(200);                                          // ec_DCtime must be live
    ec_dcsync01(uint16(s), TRUE, cyc, 0, 30000);
    ec_slave[s].state = EC_STATE_SAFE_OP;
    ec_writestate(uint16(s));
    frames(300);
    ec_statecheck(uint16(s), EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 4);
    ec_readstate();
    if (ec_slave[s].state != EC_STATE_SAFE_OP) {
        LOGE("ec: wheel did not reach SAFE-OP with DC: state 0x%02x AL 0x%04x (%s)",
             unsigned(ec_slave[s].state), unsigned(ec_slave[s].ALstatuscode),
             ec_ALstatuscode2string(ec_slave[s].ALstatuscode));
        return false;
    }
    LOGI("ec: wheel SAFE-OP with SYNC0+SYNC1 armed");
    return true;
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
    // EL2521 — nothing used to configure this terminal, so it ran factory
    // defaults: frequency modulation (channel A only) with the ramp on.
    // The grabber decodes A/B quadrature to tell the forward sweep from the
    // post-pass return; with no B it cannot, so it clocked the return as more
    // forward lines and every scan came back as its own mirror. And the ramp
    // (time constant 1000) lags the commanded frequency far enough to starve a
    // sub-second sweep, then keeps emitting into the return. The artist's speed
    // curve IS the ramp — the terminal must follow it, not smooth it.
    // Objects are the legacy/normal set (RxPDO 0x1600 is what's mapped).
    if (m_cfg.posEl2521 > 0) {
        bool ok = true;
        ok &= sdoWrite<uint8_t >(m_cfg.posEl2521, 0x8000, 0x0E, 2);   // incremental encoder sim
        ok &= sdoWrite<uint8_t >(m_cfg.posEl2521, 0x8000, 0x06, 0);   // ramp off
        ok &= sdoWrite<uint32_t>(m_cfg.posEl2521, 0x8001, 0x02,
                                 uint32_t(m_cfg.el2521BaseHz));       // base frequency 1
        if (ok) LOGI("ec: EL2521 encoder-sim, ramp off, base %.0f Hz", m_cfg.el2521BaseHz);
        else    LOGW("ec: EL2521 CoE config FAILED — scans will mirror");
    }

    // Colour wheel. Found by product code like the A6-EC. If anything about it
    // is not right it is left OFF — logged, colour moves stall rather than run
    // on a wheel we cannot vouch for — and the scan axis carries on unaffected.
    m_whPos = 0;
    m_wh = Wh::Off;
    if (m_cfg.wheelEnable) {
        int s = 0;
        for (int i = 1; i <= ec_slavecount; i++)
            if (uint32_t(ec_slave[i].eep_id) == 0x1C2B3052u) { s = i; break; }
        if (!s)                 LOGE("ec: wheel_enable=1 but no EL7211-9014 on the bus");
        else if (wheelPreop(s)) m_whPos = s;
        if (!m_whPos) LOGE("ec: colour wheel OFF — filter moves will stall until this is fixed");
    }

    // DC measurement + SYNC0 BEFORE the SAFE-OP transition — the drive
    // samples its sync configuration on PREOP→SAFEOP.
    ec_configdc();
    ec_dcsync0(uint16(m_drivePos), TRUE, uint32_t(m_cfg.cycleUs) * 1000u, 0);

    ec_config_map(s_ioMap);
    ec_statecheck(0, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 4);

    if (m_whPos && !wheelArmDc(m_whPos)) {
        m_whPos = 0;
        LOGE("ec: colour wheel OFF — filter moves will stall until this is fixed");
    }
    if (m_whPos) {
        m_whRx = reinterpret_cast<WheelRx *>(ec_slave[m_whPos].outputs);
        m_whTx = reinterpret_cast<WheelTx *>(ec_slave[m_whPos].inputs);
        m_whRx->cw = 0x0000;
        m_whRx->target = 0;
        m_wh = Wh::Waiting;
        m_whReady = 0;
        m_whTripT = 0.0;
    }

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
    if (m_whPos > 0) {
        // EL7211: INIT first, THEN release SYNC0/1 — the other order writes a
        // 0 ns cycle while configured and the terminal logs 0x8135.
        ec_statecheck(0, EC_STATE_INIT, EC_TIMEOUTSTATE * 2);
        ec_dcsync01(uint16(m_whPos), FALSE, 0, 0, 0);
    }
    ec_close();
    m_op = false;
}

// ── control-context accessors ────────────────────────────────────────────────
void EcBackend::axisSetTargetDeg(double deg) {
    // Never command a step. If the axis sits outside the soft envelope (moved by
    // hand while powered down), widen the clamp to include the current pose so
    // it can only move inward. 2026-10-10: parked at -183.6 deg, the clamp to
    // -180 was a 65k-count step on enable -> A6-EC Er87.1 on every execute.
    const double pos = axisPosDeg();
    const double lo = std::min(m_cfg.softMinDeg, pos);
    const double hi = std::max(m_cfg.softMaxDeg, pos);
    m_targetDeg = std::min(hi, std::max(lo, deg));
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

void EcBackend::axisFaultReset() {
    m_faultReset = true;
    if (m_cfg.wheelEnable && m_whRx && m_wh == Wh::Tripped) {
        // Re-arm: back through the start check (pose inside the red window),
        // then enable holding wherever the wheel now is. Never a move.
        LOGI("ec: wheel trip reset — re-checking pose before enabling");
        m_wh = Wh::Waiting;
        m_whReady = 0;
        m_whTripT = 0.0;
        m_whPendSlot = -1;
    }
}

void EcBackend::fwMoveToSlot(int slot) {
    slot = std::max(0, std::min(3, slot));
    if (m_cfg.wheelEnable) {
        static const char kName[] = "RGBC";
        const double deg = m_cfg.wheelSlotDeg[slot];
        if (std::isnan(deg)) {
            LOGW("ec: wheel has no %c filter — staying where it is", kName[slot]);
            return;
        }
        if (m_wh == Wh::Holding) {
            int32_t t = m_whCenter + int32_t(std::llround(deg / 360.0 * double(m_whCpr)));
            t = std::max(m_whCenter - m_whWin, std::min(m_whCenter + m_whWin, t));
            m_whSlot = slot;
            if (std::llabs((long long)t - (long long)std::llround(m_whCmd)) < 2) return;  // already there
            m_whTarget = t;
            m_whVel = 0.0;
            m_wh = Wh::Moving;
            LOGI("ec: wheel -> %c (%+.1f deg)", kName[slot], deg);
        } else if (m_wh == Wh::Moving || m_wh == Wh::Waiting || m_wh == Wh::Enabling) {
            m_whPendSlot = slot;      // never reverse mid-move: queue it for arrival
        } else {
            LOGW("ec: wheel unavailable (%s) — %c ignored",
                 m_wh == Wh::Tripped ? "tripped, needs fault_reset" : "off", kName[slot]);
        }
        return;
    }
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

// ── colour wheel, one cycle ──────────────────────────────────────────────────
// Off      fitted but unusable: controlword 0, never energised
// Waiting  drive coming up; once position is valid, judge the pose vs red
// Enabling walk to operation enabled, target glued to the actual position
// Holding  at rest, accepts a slot
// Moving   trapezoid to the slot, new slots queue until arrival
// Tripped  quick stop 200 ms, then disabled; latched until fault_reset
void EcBackend::wheelCycle(double dt) {
    if (!m_whRx || !m_whTx) return;
    const uint16_t sw  = m_whTx->sw;
    const int32_t  pos = m_whTx->pos;
    const bool     opEn = (sw & 0x006F) == 0x0027;
    const double   cpr = double(m_whCpr);
    auto stDelta = [&](long long a) {                       // -cpr/2 .. cpr/2-1
        long long d = ((a % m_whCpr) + m_whCpr) % m_whCpr;
        return d >= m_whCpr / 2 ? d - m_whCpr : d;
    };
    auto degFromRed = [&](int32_t p) { return double(p - m_whCenter) * 360.0 / cpr; };
    m_whTripT += dt;

    // Measured, not commanded: whatever the cause, a wheel outside the trip
    // band gets quick stop + disable. Checked whenever torque may be on.
    if ((m_wh == Wh::Enabling || m_wh == Wh::Holding || m_wh == Wh::Moving) &&
        (pos > m_whCenter + m_whTrip || pos < m_whCenter - m_whTrip)) {
        LOGE("ec: WHEEL TRIP — %+.1f deg from red, past %.0f: quick stop + disable, "
             "latched until fault_reset", degFromRed(pos), m_cfg.wheelTripDeg);
        m_wh = Wh::Tripped; m_whTripT = 0.0;
    }
    // Drive dropped out of operation enabled by itself (fault, STO): latch.
    if ((m_wh == Wh::Holding || m_wh == Wh::Moving) && !opEn) {
        LOGE("ec: wheel drive left operation enabled (sw 0x%04X) — latched until fault_reset", sw);
        m_wh = Wh::Tripped; m_whTripT = 0.0;
    }

    uint16_t cw = 0x0006;
    int32_t  target = pos;
    switch (m_wh) {
    case Wh::Off:
        cw = 0x0000;
        break;

    case Wh::Waiting:
        if ((sw & 0x004F) == 0x0008) {                      // latched fault: pulsed reset edges
            cw = std::fmod(m_whTripT, 0.1) < 0.05 ? 0x0080 : 0x0000;
            m_whReady = 0;
            break;
        }
        // Position reads 0 in switch-on-disabled; judge only after 50 cycles
        // in ready-to-switch-on with a live position.
        m_whReady = ((sw & 0x006F) == 0x0021) ? m_whReady + 1 : 0;
        if (m_whReady >= 50 && pos != 0) {
            m_whCenter = int32_t(pos - stDelta((long long)pos - m_whRedSt));
            if (pos > m_whCenter + m_whWin || pos < m_whCenter - m_whWin) {
                LOGE("ec: wheel is %+.1f deg from red — outside the %.0f deg window, NOT enabling. "
                     "Turn it toward red by hand, then fault_reset", degFromRed(pos), m_cfg.wheelWindowDeg);
                m_wh = Wh::Tripped; m_whTripT = 1.0;        // straight to disabled
            } else {
                LOGI("ec: wheel %+.2f deg from red — enabling, holding where it is", degFromRed(pos));
                m_wh = Wh::Enabling; m_whTripT = 0.0;
            }
        }
        break;

    case Wh::Enabling:
        m_whCmd = double(pos);
        m_whVel = 0.0;
        if      ((sw & 0x006F) == 0x0021) cw = 0x0007;
        else if ((sw & 0x006F) == 0x0023) cw = 0x000F;
        else if (opEn) {
            cw = 0x000F;
            m_whTarget = pos;
            m_whSlot = -1;
            for (int k = 0; k < 4; k++) {
                const double d = m_cfg.wheelSlotDeg[k];
                if (!std::isnan(d) && std::fabs(degFromRed(pos) - d) < 0.5) m_whSlot = k;
            }
            m_wh = Wh::Holding;
            LOGI("ec: wheel enabled at %+.2f deg from red (slot %d)", degFromRed(pos), m_whSlot);
        }
        if (m_wh == Wh::Enabling && m_whTripT > 2.0) {
            LOGE("ec: wheel did not enable in 2 s (sw 0x%04X) — STO / 48 V? latched until fault_reset", sw);
            m_wh = Wh::Tripped; m_whTripT = 0.0;
        }
        break;

    case Wh::Holding:
    case Wh::Moving: {
        cw = 0x000F;
        if (m_wh == Wh::Moving) {
            const double vmax = m_cfg.wheelVelRpm / 60.0 * cpr;     // counts/s
            const double acc  = m_cfg.wheelAccRps2 * cpr;           // counts/s^2
            const double rem  = std::fabs(double(m_whTarget) - m_whCmd);
            const double dir  = double(m_whTarget) > m_whCmd ? 1.0 : -1.0;
            if (rem <= m_whVel * m_whVel / (2.0 * acc)) m_whVel -= acc * dt;   // brake
            else                                        m_whVel = std::min(m_whVel + acc * dt, vmax);
            if (m_whVel < 0.0) m_whVel = 0.0;
            const double step = m_whVel * dt;
            if (step >= rem) {
                m_whCmd = double(m_whTarget);
                m_whVel = 0.0;
                m_wh = Wh::Holding;
                LOGI("ec: wheel at slot %d (%+.2f deg from red)", m_whSlot, degFromRed(pos));
            } else {
                m_whCmd += dir * step;
            }
        }
        target = int32_t(std::llround(m_whCmd));
        break;
    }

    case Wh::Tripped:
        cw = m_whTripT < 0.2 ? 0x0002 : 0x0000;               // quick stop, then disable voltage
        break;
    }

    // Last line: with torque possibly on, never command outside the window.
    if (m_wh == Wh::Enabling || m_wh == Wh::Holding || m_wh == Wh::Moving)
        target = std::max(m_whCenter - m_whWin, std::min(m_whCenter + m_whWin, target));
    m_whRx->cw = cw;
    m_whRx->target = target;

    // A slot requested while busy runs once the wheel is at rest.
    if (m_wh == Wh::Holding && m_whPendSlot >= 0) {
        const int p = m_whPendSlot;
        m_whPendSlot = -1;
        fwMoveToSlot(p);
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
        wheelCycle(dt);      // after the sequencer: its filter request lands this cycle
        writeOutputs();

        dcAlign(); cycleSleep();
    }

    // Colour wheel exit. Park on red first — the half wheel is off-balance and
    // swings toward red under gravity the instant torque goes. Then disable
    // with frames still flowing, then step it down to SAFE-OP while still
    // cycling: stopping process data with the EL7211 in OP latches 0x8105
    // PD-watchdog, which only a power cycle clears.
    if (m_whRx && m_whTx) {
        if (m_wh != Wh::Holding && m_wh != Wh::Moving) m_whPendSlot = -1;   // nothing to park
        if (m_wh == Wh::Holding && m_whSlot != 0) fwMoveToSlot(0);
        else if (m_wh == Wh::Moving)              m_whPendSlot = 0;
        for (int i = 0; i < 5000 && (m_wh == Wh::Moving || m_whPendSlot >= 0); i++) {
            ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
            wheelCycle(dt);
            dcAlign(); cycleSleep();
        }
        for (int i = 0; i < 400; i++) {
            m_whRx->cw = 0x0006;
            m_whRx->target = m_whTx->pos;
            ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
            if (i > 50 && (m_whTx->sw & 0x006F) != 0x0027) break;
            dcAlign(); cycleSleep();
        }
        ec_slave[m_whPos].state = EC_STATE_SAFE_OP;
        ec_writestate(uint16(m_whPos));
        for (int i = 0; i < 200; i++) {
            ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
            dcAlign(); cycleSleep();
        }
        LOGI("ec: wheel parked, disabled, SAFE-OP");
    }

    // safe exit: drop torque request, zero outputs
    if (m_drvRx) m_drvRx->controlword = 0x0006;
    if (m_dout)  *m_dout = 0;
    if (m_ltRx)  m_ltRx->freqVal = 0;
    ec_send_processdata();
    ec_receive_processdata(EC_TIMEOUTRET);
}
