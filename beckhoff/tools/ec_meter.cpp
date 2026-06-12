// ec_meter — pendant-to-photon demo: render the live xylod axis position as a
// dot on an EL2008's channel LEDs.
//
//   sudo ./ec_meter enp4s0 [degPerLed=1.0] [host=127.0.0.1] [port=5510]
//
// One side is a xylod TCP client (like motosome) reading posDeg from the
// status broadcasts; the other side is a SOEM master driving the EL2008.
// Works against sim xylod (sim never opens the NIC, so no master conflict):
// turn the pendant dial in capture ▸ dial-jog on the Pi and the dot walks
// across the terminal. Each degPerLed degrees of axis = one LED, wrapping.
// Ctrl-C to exit (lights out, bus back to INIT).
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
static std::atomic<bool>   g_seen{false};   // any status received yet
static std::atomic<bool>   g_run{true};

static void onSigint(int) { g_run = false; }

// xylod client: connect, say hello, parse posDeg out of status lines. Reconnects.
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
        std::printf("[xylod] connected %s:%d\n", host.c_str(), port);
        const char *hello = "{\"cmd\":\"hello\",\"client\":\"ec_meter\"}\n{\"cmd\":\"status\"}\n";
        if (write(fd, hello, strlen(hello)) < 0) { close(fd); continue; }

        std::string buf;
        char chunk[4096];
        while (g_run) {
            const ssize_t n = read(fd, chunk, sizeof(chunk));
            if (n <= 0) break;                       // daemon gone — reconnect
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

int main(int argc, char **argv) {
    const char  *iface     = argc > 1 ? argv[1] : "enp4s0";
    const double degPerLed = argc > 2 ? atof(argv[2]) : 1.0;
    const std::string host = argc > 3 ? argv[3] : "127.0.0.1";
    const int    port      = argc > 4 ? atoi(argv[4]) : 5510;
    std::signal(SIGINT, onSigint);

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); return 1; }
    ec_config_map(&IOmap);
    ec_configdc();

    int dout = 0;
    for (int i = 1; i <= ec_slavecount; i++)
        if (std::strncmp(ec_slave[i].name, "EL2008", 6) == 0) { dout = i; break; }
    if (!dout || !ec_slave[dout].outputs) {
        std::printf("no EL2008 with mapped outputs found\n"); ec_close(); return 1;
    }

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
    std::printf("OP. %.2f deg per LED — dial the pendant. Ctrl-C to quit.\n", degPerLed);

    std::thread reader(readerThread, host, port);

    const int expectedWkc = ec_group[0].outputsWKC * 2 + ec_group[0].inputsWKC;
    int lastDot = -1;
    long bad = 0;
    while (g_run) {
        uint8_t out = 0;
        if (g_seen) {
            const int dot = int(std::floor(g_posDeg / degPerLed)) % 8;
            const int d   = dot < 0 ? dot + 8 : dot;
            out = uint8_t(1u << d);
            if (d != lastDot) {
                std::printf("pos %8.2f deg -> LED %d\n", double(g_posDeg), d + 1);
                lastDot = d;
            }
        }
        *ec_slave[dout].outputs = out;
        ec_send_processdata();
        if (ec_receive_processdata(EC_TIMEOUTRET) < expectedWkc) bad++;
        usleep(10000);
    }

    *ec_slave[dout].outputs = 0;                 // lights out
    ec_send_processdata();
    ec_receive_processdata(EC_TIMEOUTRET);
    ec_slave[0].state = EC_STATE_INIT;
    ec_writestate(0);
    ec_close();
    reader.join();
    std::printf("bye (%ld bad WKC)\n", bad);
    return 0;
}
