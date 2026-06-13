// motor_test — minimal CiA-402 CSP bring-up for the A6-EC, standalone SOEM.
// The grown-up version of the bench motor test program: walks the DS402 state
// machine, then sweeps the axis ±N output-degrees with a sine velocity.
//
//   sudo ./motor_test eth1 [slavePos=1] [sweepDeg=10] [seconds=10]
//
// Uses the same PDO remap as xylod, so a motor that runs here runs there.
#include <ethercat.h>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <sched.h>
#include <sys/mman.h>

static char ioMap[4096];
static volatile bool run_ = true;
static void stop(int) { run_ = false; }

struct Rx { uint16_t cw; int32_t target; int8_t mode; } __attribute__((packed));
struct Tx { uint16_t sw; int32_t pos; int32_t vel; uint16_t err; int8_t modeDisp; } __attribute__((packed));

template <typename T> static bool sdo(int s, uint16_t i, uint8_t sub, T v) {
    const bool ok = ec_SDOwrite(s, i, sub, FALSE, sizeof(T), &v, EC_TIMEOUTRXM) > 0;
    if (!ok) {
        std::printf("  SDO write 0x%04X:%02X FAILED", i, sub);
        while (EcatError) std::printf("  [%s]", ec_elist2string());
        std::printf("\n");
    }
    return ok;
}

static const double COUNTS_PER_DEG = 131072.0 * 50.0 / 360.0;   // 17-bit abs × 50:1

int main(int argc, char **argv) {
    const char *iface = argc > 1 ? argv[1] : "eth1";
    const int   sl    = argc > 2 ? std::atoi(argv[2]) : 1;
    const double sweep = argc > 3 ? std::atof(argv[3]) : 10.0;
    const double secs  = argc > 4 ? std::atof(argv[4]) : 10.0;
    std::signal(SIGINT, stop);

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves\n"); return 1; }
    std::printf("slave %d: %s\n", sl, ec_slave[sl].name);

    // PDO config is legal ONLY in PRE-OP (manual 8.3.1: "2 displayed on the
    // panel"). Don't trust config_init — enforce and verify.
    ec_slave[sl].state = EC_STATE_PRE_OP;
    ec_writestate(sl);
    ec_statecheck(sl, EC_STATE_PRE_OP, EC_TIMEOUTSTATE * 4);
    if (ec_slave[sl].state != EC_STATE_PRE_OP) {
        std::printf("drive not in PRE-OP (al=0x%02X) — power-cycle it and retry\n",
                    unsigned(ec_slave[sl].state));
        ec_close(); return 1;
    }
    std::printf("drive in PRE-OP — remapping PDOs\n");

    // remap to fixed CSP PDOs (same set as xylod). Every write is verified —
    // if the drive refuses remapping, we must NOT touch the motor with a
    // misaligned process image.
    bool ok = true;
    ok &= sdo<uint8_t>(sl, 0x1C12, 0, 0); ok &= sdo<uint8_t>(sl, 0x1C13, 0, 0);
    ok &= sdo<uint8_t>(sl, 0x1600, 0, 0);
    ok &= sdo<uint32_t>(sl, 0x1600, 1, 0x60400010);
    ok &= sdo<uint32_t>(sl, 0x1600, 2, 0x607A0020);
    ok &= sdo<uint32_t>(sl, 0x1600, 3, 0x60600008);
    ok &= sdo<uint8_t>(sl, 0x1600, 0, 3);
    ok &= sdo<uint8_t>(sl, 0x1A00, 0, 0);
    ok &= sdo<uint32_t>(sl, 0x1A00, 1, 0x60410010);
    ok &= sdo<uint32_t>(sl, 0x1A00, 2, 0x60640020);
    ok &= sdo<uint32_t>(sl, 0x1A00, 3, 0x606C0020);
    ok &= sdo<uint32_t>(sl, 0x1A00, 4, 0x603F0010);
    ok &= sdo<uint32_t>(sl, 0x1A00, 5, 0x60610008);
    ok &= sdo<uint8_t>(sl, 0x1A00, 0, 5);
    ok &= sdo<uint16_t>(sl, 0x1C12, 1, 0x1600); ok &= sdo<uint8_t>(sl, 0x1C12, 0, 1);
    ok &= sdo<uint16_t>(sl, 0x1C13, 1, 0x1A00); ok &= sdo<uint8_t>(sl, 0x1C13, 0, 1);
    ok &= sdo<int8_t>(sl, 0x6060, 0, 8);                 // CSP
    if (!ok) {
        std::printf("PDO remap rejected by drive — aborting before motion.\n"
                    "(Drive may use fixed PDOs; we adapt the tool, not push on.)\n");
        ec_close(); return 1;
    }

    ec_config_map(ioMap);
    if (ec_slave[sl].Obytes != sizeof(Rx) || ec_slave[sl].Ibytes != sizeof(Tx)) {
        std::printf("process image mismatch: O=%u (want %zu) I=%u (want %zu) — aborting.\n",
                    unsigned(ec_slave[sl].Obytes), sizeof(Rx),
                    unsigned(ec_slave[sl].Ibytes), sizeof(Tx));
        ec_close(); return 1;
    }
    ec_configdc();
    // The drive (Er74.1 "no sync signal", 2026-06-12) requires DC SYNC0 at the
    // cycle time — ec_configdc alone only measures the topology, it doesn't
    // start the slave's sync pulse.
    ec_dcsync0(uint16(sl), TRUE, 1000000, 0);            // SYNC0 @ 1 ms
    // Keep our frames inside the sync window: RT priority + locked memory.
    mlockall(MCL_CURRENT | MCL_FUTURE);
    sched_param sp{}; sp.sched_priority = 60;
    if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0)
        std::printf("note: SCHED_FIFO unavailable (run with sudo) — continuing best-effort\n");
    ec_statecheck(0, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 4);

    auto *rx = reinterpret_cast<Rx *>(ec_slave[sl].outputs);
    auto *tx = reinterpret_cast<Tx *>(ec_slave[sl].inputs);

    // ── DC phase-locked cyclic engine ────────────────────────────────────────
    // Er74.1 round 2 (2026-06-12): SYNC0 + C13.05=2 was not enough — the drive
    // faulted entering OP. DC drives need frames GAP-FREE at the cycle time
    // from before the OP request, phase-aligned to DC time (classic SOEM PI).
    // No blocking statechecks or SDO mailbox traffic once the cadence starts.
    static int64 integral = 0;
    int64 toff = 0;
    auto dcAlign = [&]() {
        int64 delta = (ec_DCtime - 250000) % 1000000;   // aim ~250 us after SYNC0
        if (delta > 500000) delta -= 1000000;
        integral += (delta > 0) - (delta < 0);
        toff = -(delta / 100) - (integral / 20);
    };
    timespec next; clock_gettime(CLOCK_MONOTONIC, &next);
    auto cycleSleep = [&]() {
        long ns = next.tv_nsec + 1000000L + long(toff);
        next.tv_sec += ns / 1000000000L; ns %= 1000000000L;
        if (ns < 0) { ns += 1000000000L; next.tv_sec--; }
        next.tv_nsec = ns;
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, nullptr);
    };

    for (int i = 0; i < 500 && run_; i++) {        // phase-lock in SAFE-OP first
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        dcAlign(); cycleSleep();
    }
    ec_slave[0].state = EC_STATE_OPERATIONAL;
    ec_writestate(0);
    for (int w = 0; w < 5000 && run_ && ec_slave[0].state != EC_STATE_OPERATIONAL; w++) {
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        dcAlign(); cycleSleep();
        if (w % 200 == 199) ec_readstate();        // non-blocking-ish state poll
    }
    if (ec_slave[0].state != EC_STATE_OPERATIONAL) { std::printf("no OP\n"); return 1; }
    std::printf("OPERATIONAL (phase-locked), expected WKC=%d — enabling drive…\n",
                ec_group[0].outputsWKC * 2 + ec_group[0].inputsWKC);

    const int32_t startPos = tx->pos;
    double t = 0.0;
    bool enabled = false;

    double tEn = -1.0;
    while (run_ && t < secs + 5.0) {
        t += 0.001;                                  // wall clock — always runs
        ec_send_processdata();
        const int wkc = ec_receive_processdata(EC_TIMEOUTRET);

        // DS402 walk
        const uint16_t sw = tx->sw;
        uint16_t cw = 0x0006;
        if      ((sw & 0x004F) == 0x0008) cw = 0x0080;            // fault → reset
        else if ((sw & 0x004F) == 0x0040) cw = 0x0006;            // shutdown
        else if ((sw & 0x006F) == 0x0021) cw = 0x0007;            // switch on
        else if ((sw & 0x006F) == 0x0023) cw = 0x000F;            // enable op
        else if ((sw & 0x006F) == 0x0027) { cw = 0x000F; if (!enabled) { enabled = true; tEn = t; } }
        rx->cw = cw;
        rx->mode = 8;

        // sine sweep once enabled (sine clock starts at the enable moment)
        int32_t target = startPos;
        if (enabled) {
            const double deg = sweep * std::sin(2.0 * M_PI * (t - tEn) / 8.0);   // 8 s period
            target = startPos + int32_t(deg * COUNTS_PER_DEG);
        }
        rx->target = target;

        if (int(t * 1000) % 250 == 0)
            std::printf("\rsw=0x%04X pos=%+9.3f deg vel=%+8.2f deg/s err=0x%04X wkc=%d al=0x%02X  ",
                        sw, (tx->pos - startPos) / COUNTS_PER_DEG,
                        tx->vel / COUNTS_PER_DEG, tx->err, wkc,
                        unsigned(ec_slave[sl].state));
        std::fflush(stdout);

        dcAlign(); cycleSleep();
    }

    std::printf("\ndisabling…\n");
    rx->cw = 0x0006;
    ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
    ec_dcsync0(uint16(sl), FALSE, 0, 0);
    ec_slave[0].state = EC_STATE_INIT;               // clean slate for next run —
    ec_writestate(0);                                 // PDO remap needs PRE-OP
    ec_close();
    return 0;
}
