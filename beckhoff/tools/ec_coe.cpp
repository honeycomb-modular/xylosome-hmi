// ec_coe — read the EL2521's CoE configuration. READ-ONLY, writes nothing.
//   sudo ./ec_coe enp4s0 5
//
// The EL2521 exposes two object layouts depending on which PDO profile it is
// running (Beckhoff EL252x docs):
//   Normal / legacy MDP 252  -> 0x8000 + 0x8001
//   Enhanced MDP 253/511     -> 0x8010
// Which one is live decides where output mode, base frequency and the ramp
// settings actually live, so read both and see which answers.
#include <ethercat.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void show(int slave, uint16_t idx, uint8_t sub, const char *what) {
    uint8_t buf[8] = {0};
    int size = int(sizeof buf);
    if (ec_SDOread(slave, idx, sub, FALSE, &size, buf, EC_TIMEOUTRXM) > 0) {
        uint32_t v = 0;
        std::memcpy(&v, buf, size > 4 ? 4 : size);
        std::printf("  0x%04X:%02X  %-26s = %-10u (%d byte%s)\n",
                    idx, sub, what, unsigned(v), size, size == 1 ? "" : "s");
    } else {
        std::printf("  0x%04X:%02X  %-26s   -- absent\n", idx, sub, what);
    }
}

int main(int argc, char **argv) {
    const char *iface = argc > 1 ? argv[1] : "enp4s0";
    const int   slave = argc > 2 ? std::atoi(argv[2]) : 5;

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); ec_close(); return 1; }
    if (slave < 1 || slave > ec_slavecount) {
        std::printf("slave %d out of range (1..%d)\n", slave, ec_slavecount); ec_close(); return 1;
    }
    std::printf("slave %d: %s  (%d slaves on %s)\n\n",
                slave, ec_slave[slave].name, ec_slavecount, iface);

    std::printf("PDO assignment (which profile is mapped)\n");
    show(slave, 0x1C12, 0x00, "RxPDO assign count");
    for (uint8_t i = 1; i <= 4; i++) show(slave, 0x1C12, i, "  RxPDO");
    show(slave, 0x1C13, 0x00, "TxPDO assign count");
    for (uint8_t i = 1; i <= 4; i++) show(slave, 0x1C13, i, "  TxPDO");

    std::printf("\nNormal / legacy profile (0x8000 + 0x8001)\n");
    show(slave, 0x8000, 0x0E, "output mode");        // 0=freq mod 1=pulse/dir 2=enc sim
    show(slave, 0x8000, 0x06, "ramp active");
    show(slave, 0x8000, 0x07, "ramp base freq select");
    show(slave, 0x8001, 0x02, "base frequency 1");
    show(slave, 0x8001, 0x03, "base frequency 2");
    show(slave, 0x8001, 0x04, "ramp time constant rising");
    show(slave, 0x8001, 0x05, "ramp time constant falling");

    std::printf("\nEnhanced profile (0x8010)\n");
    show(slave, 0x8010, 0x0E, "output mode");
    show(slave, 0x8010, 0x06, "ramp active");
    show(slave, 0x8010, 0x07, "ramp base freq select");
    show(slave, 0x8010, 0x12, "base frequency 1");
    show(slave, 0x8010, 0x13, "base frequency 2");
    show(slave, 0x8010, 0x14, "ramp time constant rising");
    show(slave, 0x8010, 0x15, "ramp time constant falling");

    std::printf("\noutput mode: 0 = frequency modulation, 1 = pulse/direction, "
                "2 = incremental encoder simulation (drives A and B)\n");
    ec_close();
    return 0;
}
