// ec_scan — list everything on the EtherCAT segment.
//   sudo ./ec_scan eth1
#include <ethercat.h>
#include <cstdio>

int main(int argc, char **argv) {
    const char *iface = argc > 1 ? argv[1] : "eth1";
    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); return 1; }

    std::printf("%d slave(s) on %s:\n", ec_slavecount, iface);
    std::printf("pos  name                  man/id            Obits  Ibits\n");
    for (int i = 1; i <= ec_slavecount; i++)
        std::printf("%3d  %-20s  %08x/%08x  %5d  %5d\n",
                    i, ec_slave[i].name,
                    unsigned(ec_slave[i].eep_man), unsigned(ec_slave[i].eep_id),
                    ec_slave[i].Obits, ec_slave[i].Ibits);
    ec_close();
    return 0;
}
