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

static char ioMap[4096];
static volatile bool run_ = true;
static void stop(int) { run_ = false; }

struct Rx { uint16_t cw; int32_t target; int8_t mode; } __attribute__((packed));
struct Tx { uint16_t sw; int32_t pos; int32_t vel; uint16_t err; int8_t modeDisp; } __attribute__((packed));

template <typename T> static bool sdo(int s, uint16_t i, uint8_t sub, T v) {
    return ec_SDOwrite(s, i, sub, FALSE, sizeof(T), &v, EC_TIMEOUTRXM) > 0;
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
    ec_statecheck(0, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 4);

    auto *rx = reinterpret_cast<Rx *>(ec_slave[sl].outputs);
    auto *tx = reinterpret_cast<Tx *>(ec_slave[sl].inputs);

    ec_slave[0].state = EC_STATE_OPERATIONAL;
    ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
    ec_writestate(0);
    for (int t = 0; t < 200 && ec_slave[0].state != EC_STATE_OPERATIONAL; t++) {
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        ec_statecheck(0, EC_STATE_OPERATIONAL, 50000);
    }
    if (ec_slave[0].state != EC_STATE_OPERATIONAL) { std::printf("no OP\n"); return 1; }
    std::printf("OPERATIONAL — enabling drive…\n");

    timespec next; clock_gettime(CLOCK_MONOTONIC, &next);
    const int32_t startPos = tx->pos;
    double t = 0.0;
    bool enabled = false;

    while (run_ && t < secs + 5.0) {
        ec_send_processdata();
        ec_receive_processdata(EC_TIMEOUTRET);

        // DS402 walk
        const uint16_t sw = tx->sw;
        uint16_t cw = 0x0006;
        if      ((sw & 0x004F) == 0x0008) cw = 0x0080;            // fault → reset
        else if ((sw & 0x004F) == 0x0040) cw = 0x0006;            // shutdown
        else if ((sw & 0x006F) == 0x0021) cw = 0x0007;            // switch on
        else if ((sw & 0x006F) == 0x0023) cw = 0x000F;            // enable op
        else if ((sw & 0x006F) == 0x0027) { cw = 0x000F; enabled = true; }
        rx->cw = cw;
        rx->mode = 8;

        // sine sweep once enabled
        int32_t target = startPos;
        if (enabled) {
            t += 0.001;
            const double deg = sweep * std::sin(2.0 * M_PI * t / 8.0);   // 8 s period
            target = startPos + int32_t(deg * COUNTS_PER_DEG);
        }
        rx->target = target;

        if (int(t * 1000) % 250 == 0)
            std::printf("\rsw=0x%04X pos=%+9.3f deg vel=%+8.2f deg/s err=0x%04X   ",
                        sw, (tx->pos - startPos) / COUNTS_PER_DEG,
                        tx->vel / COUNTS_PER_DEG, tx->err);
        std::fflush(stdout);

        next.tv_nsec += 1000000L;
        while (next.tv_nsec >= 1000000000L) { next.tv_nsec -= 1000000000L; next.tv_sec++; }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, nullptr);
    }

    std::printf("\ndisabling…\n");
    rx->cw = 0x0006;
    ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
    ec_close();
    return 0;
}
