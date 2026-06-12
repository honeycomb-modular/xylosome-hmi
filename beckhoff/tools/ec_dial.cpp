// ec_dial — pendant-to-steel: the stepper on the EL7047 follows the live
// xylod axis position. Turn the pendant dial (capture ▸ dial-jog on the Pi),
// the leadscrew turns.
//
//   sudo ./ec_dial enp4s0 [gear=50] [host=127.0.0.1] [port=5510]
//
// gear = motor revolutions per axis revolution (default 50, like the harmonic
// drive: one 1.0-degree dial click ~= 1/7 motor rev).
//
// One side: xylod TCP client reading posDeg from status broadcasts (ec_meter
// pattern). Other side: EL7047 velocity-direct mode (ec_step pattern, same
// doc-verified CoE config, 300 mA limit). In between: a P velocity controller
// tracking the target position with an open-loop position estimate
// (integrated commanded velocity — fine for an unloaded stepper demo).
// Ctrl-C: stop, disable, INIT.
#include <ethercat.h>
#include <nlohmann/json.hpp>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <string>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <csignal>

static char IOmap[4096];
static std::atomic<double> g_posDeg{0.0};
static std::atomic<bool>   g_seen{false};
static std::atomic<bool>   g_run{true};
static void onSigint(int) { g_run = false; }

static constexpr double SPEED_RANGE_FS = 2000.0;  // 0x8012:05 default
static constexpr double FULLSTEPS_REV  = 200.0;
static constexpr double MAX_FS         = 600.0;   // velocity clamp (3 rev/s)
static constexpr double KP             = 6.0;     // 1/s: vel = KP * pos error
static constexpr double DT             = 0.01;    // 10 ms cycle
static constexpr uint16 MAX_CURRENT_MA = 300;

static void readerThread(std::string host, int port) {
    while (g_run) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port   = htons(uint16_t(port));
        inet_pton(AF_INET, host.c_str(), &addr.sin_addr);
        if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
            close(fd);
            std::printf("[xylod] connect %s:%d failed — retrying\n", host.c_str(), port);
            for (int i = 0; i < 20 && g_run; i++) usleep(100000);
            continue;
        }
        std::printf("[xylod] connected %s:%d — dial away\n", host.c_str(), port);
        const char *hello = "{\"cmd\":\"hello\",\"client\":\"ec_dial\"}\n{\"cmd\":\"status\"}\n";
        if (write(fd, hello, strlen(hello)) < 0) { close(fd); continue; }
        std::string buf;
        char chunk[4096];
        while (g_run) {
            const ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n <= 0) break;
            buf.append(chunk, size_t(n));
            size_t nl;
            while ((nl = buf.find('\n')) != std::string::npos) {
                const std::string line = buf.substr(0, nl);
                buf.erase(0, nl + 1);
                const auto j = nlohmann::json::parse(line, nullptr, false);
                if (j.is_discarded() || !j.is_object()) continue;
                if (j.value("ev", "") == "status" && j.contains("posDeg")) {
                    g_posDeg = j["posDeg"].get<double>();
                    g_seen = true;
                }
            }
        }
        close(fd);
        std::printf("[xylod] disconnected\n");
    }
}

static bool sdoU16(uint16 slave, uint16 idx, uint8 sub, uint16 val) {
    return ec_SDOwrite(slave, idx, sub, FALSE, sizeof(val), &val, EC_TIMEOUTRXM) > 0;
}
static bool sdoU8(uint16 slave, uint16 idx, uint8 sub, uint8 val) {
    return ec_SDOwrite(slave, idx, sub, FALSE, sizeof(val), &val, EC_TIMEOUTRXM) > 0;
}

int main(int argc, char **argv) {
    const char  *iface = argc > 1 ? argv[1] : "enp4s0";
    const double gear  = argc > 2 ? atof(argv[2]) : 50.0;
    const std::string host = argc > 3 ? argv[3] : "127.0.0.1";
    const int    port  = argc > 4 ? atoi(argv[4]) : 5510;
    std::signal(SIGINT, onSigint);

    const double fsPerDeg = gear * FULLSTEPS_REV / 360.0;

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); return 1; }
    int drv = 0;
    for (int i = 1; i <= ec_slavecount; i++)
        if (std::strncmp(ec_slave[i].name, "EL7047", 6) == 0) { drv = i; break; }
    if (!drv) { std::printf("no EL7047 found\n"); ec_close(); return 1; }

    bool ok = true;
    ok &= sdoU16(drv, 0x8010, 0x01, MAX_CURRENT_MA);
    ok &= sdoU16(drv, 0x8010, 0x02, MAX_CURRENT_MA / 2);
    ok &= sdoU16(drv, 0x8010, 0x03, 2400);
    ok &= sdoU8 (drv, 0x8012, 0x01, 1);                 // velocity direct
    if (!ok) { std::printf("CoE config failed — aborting\n"); ec_close(); return 1; }
    std::printf("EL7047 at position %d configured (%.0f mA, gear %.1f)\n",
                drv, double(MAX_CURRENT_MA), gear);

    ec_config_map(&IOmap);
    ec_configdc();
    if (ec_slave[drv].Obytes != 8 || ec_slave[drv].Ibytes != 8) {
        std::printf("unexpected PDO sizes — aborting\n"); ec_close(); return 1;
    }
    uint8  *out  = ec_slave[drv].outputs;
    uint16 *ctl  = reinterpret_cast<uint16*>(out + 4);
    int16  *vel  = reinterpret_cast<int16*>(out + 6);
    uint16 *stat = reinterpret_cast<uint16*>(ec_slave[drv].inputs + 6);

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

    auto frames = [&](int n, uint16 c, int16 v) {
        for (int i = 0; i < n; i++) {
            *ctl = c; *vel = v;
            ec_send_processdata();
            ec_receive_processdata(EC_TIMEOUTRET);
            usleep(10000);
        }
    };
    std::printf("OP. reset + enable...\n");
    frames(30, 0x0002, 0);
    frames(30, 0x0000, 0);
    if ((*stat >> 3) & 1) {
        std::printf("error persists after reset (control power?) — aborting\n");
        ec_slave[0].state = EC_STATE_INIT; ec_writestate(0); ec_close(); return 1;
    }
    frames(50, 0x0001, 0);

    std::thread reader(readerThread, host, port);
    std::printf("following xylod axis (Ctrl-C to quit)\n");

    double estFs = 0.0, originDeg = 0.0;
    bool   origin = false;
    int    tick = 0;
    while (g_run) {
        double v = 0.0;
        if (g_seen) {
            if (!origin) { originDeg = g_posDeg; origin = true; }  // start from here
            const double targetFs = (g_posDeg - originDeg) * fsPerDeg;
            const double err = targetFs - estFs;
            v = err * KP;
            if (v >  MAX_FS) v =  MAX_FS;
            if (v < -MAX_FS) v = -MAX_FS;
            if (std::fabs(err) < 0.5) v = 0.0;
            estFs += v * DT;
            if (++tick % 100 == 0 && std::fabs(err) > 0.5)
                std::printf("target %.1f fs  est %.1f fs  vel %.0f fs/s\n", targetFs, estFs, v);
        }
        *ctl = 0x0001;
        *vel = int16(lround(v / SPEED_RANGE_FS * 32767.0));
        ec_send_processdata();
        ec_receive_processdata(EC_TIMEOUTRET);
        if ((*stat >> 3) & 1) { std::printf("EL7047 ERROR — stopping\n"); break; }
        usleep(10000);
    }

    frames(30, 0x0001, 0);
    frames(20, 0x0000, 0);
    ec_slave[0].state = EC_STATE_INIT;
    ec_writestate(0);
    ec_close();
    g_run = false;
    reader.join();
    std::printf("bye\n");
    return 0;
}
