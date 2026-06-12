// ec_step — first spin of a stepper on the EL7047, velocity-direct mode.
//
//   sudo ./ec_step enp4s0 [rev_per_s=0.5] [seconds=10] [mA=300]
//
// Sequence: + spin, stop, - spin, stop, disable. Ctrl-C aborts safely.
// mA capped at 1000 (Hanpose 20HT24 rated current per vendor page) — raise
// the cap in code only for a bigger motor. Speed range (0x8012:05) is chosen
// automatically from rev_per_s, so speeds beyond 10 rev/s "just work".
//
// All object indices verified against Beckhoff infosys EL70x7 docs 2026-06-11:
//  - Default predefined PDO assignment = "Velocity control compact":
//      SM2: 0x1600 ENC Ctrl compact (4 B) + 0x1602 STM Control (2 B)
//           + 0x1604 STM Velocity (2 B int16)            -> Obytes = 8
//      SM3: 0x1A00 ENC Status compact (6 B) + 0x1A03 STM Status (2 B)
//                                                        -> Ibytes = 8
//  - STM Control bits: 0 Enable, 1 Reset, 2 Reduce torque
//  - STM Status  bits: 0 Ready-to-enable, 1 Ready, 2 Warning, 3 Error,
//                      4 Moving+, 5 Moving-, 7 Motor stall
//  - Velocity int16: +/-32767 = +/-100% of speed range (0x8012:05,
//    default 1 = 2000 fullsteps/s)
//  - CoE 0x8010:01 maximal current [mA]  ** DEFAULT IS 5000 - MUST LOWER **
//        0x8010:02 reduced current [mA], 0x8010:03 nominal voltage [10 mV]
//        0x8012:01 operation mode (1 = velocity direct)
//
// Motor: Hanpose 20HT24 NEMA 8 (200 fullsteps/rev assumed = 0x8010:06 default).
// Current limited to 300 mA - conservative for an unloaded NEMA 8.
#include <ethercat.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <csignal>
#include <unistd.h>

static char IOmap[4096];
static volatile sig_atomic_t g_stop = 0;
static void onSigint(int) { g_stop = 1; }

static constexpr int FULLSTEPS_REV = 200;
// 0x8012:05 speed ranges per EL70x7 docs: index -> fullsteps/s
static constexpr int RANGES[6] = { 1000, 2000, 4000, 8000, 16000, 32000 };

static bool sdoU16(uint16 slave, uint16 idx, uint8 sub, uint16 val) {
    const int wkc = ec_SDOwrite(slave, idx, sub, FALSE, sizeof(val), &val, EC_TIMEOUTRXM);
    std::printf("  SDO 0x%04X:%02X = %u %s\n", idx, sub, val, wkc ? "ok" : "FAILED");
    return wkc > 0;
}
static bool sdoU8(uint16 slave, uint16 idx, uint8 sub, uint8 val) {
    const int wkc = ec_SDOwrite(slave, idx, sub, FALSE, sizeof(val), &val, EC_TIMEOUTRXM);
    std::printf("  SDO 0x%04X:%02X = %u %s\n", idx, sub, val, wkc ? "ok" : "FAILED");
    return wkc > 0;
}

int main(int argc, char **argv) {
    const char  *iface   = argc > 1 ? argv[1] : "enp4s0";
    const double revps   = argc > 2 ? atof(argv[2]) : 0.5;
    const int    seconds = argc > 3 ? atoi(argv[3]) : 10;
    int          mA      = argc > 4 ? atoi(argv[4]) : 300;
    if (mA > 1000) { std::printf("capping current at 1000 mA (motor rating)\n"); mA = 1000; }
    if (mA < 50)   mA = 50;
    std::signal(SIGINT, onSigint);

    const double fsps = revps * FULLSTEPS_REV;            // fullsteps/s wanted
    uint8 rangeIdx = 0;
    while (rangeIdx < 5 && std::fabs(fsps) > RANGES[rangeIdx]) rangeIdx++;
    const int rangeFs = RANGES[rangeIdx];
    if (std::fabs(fsps) > rangeFs) {
        std::printf("rev_per_s too high (max %.0f rev/s)\n", 32000.0 / FULLSTEPS_REV);
        return 1;
    }
    const int16 velCmd = int16(lround(fsps / rangeFs * 32767.0));

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); return 1; }

    int drv = 0;
    for (int i = 1; i <= ec_slavecount; i++)
        if (std::strncmp(ec_slave[i].name, "EL7047", 6) == 0) { drv = i; break; }
    if (!drv) { std::printf("no EL7047 found\n"); ec_close(); return 1; }
    std::printf("EL7047 at position %d — configuring (PRE-OP):\n", drv);

    // Motor protection FIRST. Defaults are sized for a 5 A motor — ours is not.
    bool ok = true;
    ok &= sdoU16(drv, 0x8010, 0x01, uint16(mA));       // maximal current [mA]
    ok &= sdoU16(drv, 0x8010, 0x02, uint16(mA / 2));   // reduced current [mA]
    ok &= sdoU16(drv, 0x8010, 0x03, 2400);             // nominal voltage 24.00 V
    ok &= sdoU8 (drv, 0x8012, 0x01, 1);                // operation mode: velocity direct
    ok &= sdoU8 (drv, 0x8012, 0x05, rangeIdx);         // speed range for requested rev/s
    if (!ok) { std::printf("CoE config failed — not spinning a motor on defaults\n"); ec_close(); return 1; }
    std::printf("  speed range %d fullsteps/s, command %d/32767\n", rangeFs, velCmd);

    ec_config_map(&IOmap);
    ec_configdc();
    if (ec_slave[drv].Obytes != 8 || ec_slave[drv].Ibytes != 8) {
        std::printf("unexpected PDO sizes (O=%u I=%u, expected 8/8) — aborting\n",
                    unsigned(ec_slave[drv].Obytes), unsigned(ec_slave[drv].Ibytes));
        ec_close(); return 1;
    }
    // Offsets per default assignment: out: ENC[0..3] CTL[4..5] VEL[6..7]
    //                                 in:  ENC[0..5] STATUS[6..7]
    uint8  *out   = ec_slave[drv].outputs;
    uint16 *ctl   = reinterpret_cast<uint16*>(out + 4);
    int16  *vel   = reinterpret_cast<int16*>(out + 6);
    uint16 *stat  = reinterpret_cast<uint16*>(ec_slave[drv].inputs + 6);

    ec_statecheck(0, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE);
    ec_send_processdata();
    ec_receive_processdata(EC_TIMEOUTRET);
    ec_slave[0].state = EC_STATE_OPERATIONAL;
    ec_writestate(0);
    int chk = 200;
    do {
        ec_send_processdata();
        ec_receive_processdata(EC_TIMEOUTRET);
        ec_statecheck(0, EC_STATE_OPERATIONAL, 50000);
    } while (chk-- && ec_slave[0].state != EC_STATE_OPERATIONAL);
    if (ec_slave[0].state != EC_STATE_OPERATIONAL) {
        std::printf("failed to reach OP\n"); ec_close(); return 1;
    }

    // n x 10 ms with ctl/vel. abortOnErr only during motion phases — during
    // reset/enable the error bit may legitimately still be latched.
    auto cycle = [&](int n, uint16 c, int16 v, bool abortOnErr) {
        for (int i = 0; i < n && !g_stop; i++) {
            *ctl = c; *vel = v;
            ec_send_processdata();
            ec_receive_processdata(EC_TIMEOUTRET);
            if (i % 100 == 0)
                std::printf("  status=0x%04X  rdy2en=%d rdy=%d warn=%d err=%d mov=%d%d stall=%d\n",
                            *stat, *stat & 1, (*stat >> 1) & 1, (*stat >> 2) & 1,
                            (*stat >> 3) & 1, (*stat >> 4) & 1, (*stat >> 5) & 1,
                            (*stat >> 7) & 1);
            if (abortOnErr && ((*stat >> 3) & 1)) {
                std::printf("  ERROR bit set — stopping\n"); g_stop = 1;
            }
            usleep(10000);
        }
    };

    // Dump 0xA010 STM diag flags (read raw; names best-effort from EL70x7 docs)
    auto dumpDiag = [&]() {
        static const char *names[] = { "?", "saturated", "over temperature",
            "torque overload", "under voltage", "over voltage",
            "short circuit A", "short circuit B", "no control power",
            "misc error", "config error", "motor stall" };
        std::printf("  STM diag (0xA010):");
        for (uint8 sub = 1; sub <= 11; sub++) {
            uint8 v = 0; int sz = sizeof(v);
            if (ec_SDOread(drv, 0xA010, sub, FALSE, &sz, &v, EC_TIMEOUTRXM) > 0 && v)
                std::printf("  [%02X %s=1]", sub, names[sub]);
        }
        std::printf("\n");
    };

    std::printf("OP. Reset pulse, then enable...\n");
    if ((*stat >> 3) & 1) dumpDiag();                  // name the boot error
    cycle(30, 0x0002, 0, false);                       // reset pulse (clears latched errors)
    cycle(30, 0x0000, 0, false);
    if ((*stat >> 3) & 1) {                            // still in error after reset?
        std::printf("  error persists after reset:\n");
        dumpDiag();
        std::printf("  not spinning. (Power LED off = motor supply missing at 3'/7'.)\n");
        ec_slave[0].state = EC_STATE_INIT; ec_writestate(0); ec_close(); return 1;
    }
    cycle(50, 0x0001, 0, false);                       // enable, let Ready come up
    if (!((*stat >> 1) & 1) && !g_stop)
        std::printf("  note: Ready not set yet — check Power LED / motor supply\n");

    std::printf("spin +%.2f rev/s (%d) for %d s\n", revps, velCmd, seconds);
    cycle(seconds * 100, 0x0001, velCmd, true);
    std::printf("stop 1 s\n");
    cycle(100, 0x0001, 0, true);
    std::printf("spin -%.2f rev/s for %d s\n", revps, seconds);
    cycle(seconds * 100, 0x0001, int16(-velCmd), true);
    std::printf("stop + disable\n");
    cycle(50, 0x0001, 0, true);
    cycle(20, 0x0000, 0, false);
    if (g_stop) dumpDiag();                            // name whatever stopped us

    ec_slave[0].state = EC_STATE_INIT;
    ec_writestate(0);
    ec_close();
    std::printf("done\n");
    return 0;
}
