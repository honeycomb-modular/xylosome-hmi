// ec_blink — visual bus proof: bring the segment to OP and chase a light
// pattern across an EL2008's channel LEDs.
//   sudo ./ec_blink enp4s0 [seconds]
//
// What it proves: master → EK1100 → E-bus → EL2008 process data, cyclically,
// with working-counter verification. RUN LEDs on ALL terminals go solid green
// in OP. NOTE: the EL2008 channel LEDs are fed from the power contacts (Up) —
// without 24 V on Up they stay dark even though the bus traffic is real.
#include <ethercat.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

static char IOmap[4096];

int main(int argc, char **argv) {
    const char *iface = argc > 1 ? argv[1] : "enp4s0";
    const int seconds = argc > 2 ? atoi(argv[2]) : 15;

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); return 1; }
    ec_config_map(&IOmap);
    ec_configdc();
    std::printf("%d slaves, mapped %u output bytes / %u input bytes\n",
                ec_slavecount, unsigned(ec_group[0].Obytes), unsigned(ec_group[0].Ibytes));

    // find the EL2008 by name — position-independent
    int dout = 0;
    for (int i = 1; i <= ec_slavecount; i++)
        if (std::strncmp(ec_slave[i].name, "EL2008", 6) == 0) { dout = i; break; }
    if (!dout || !ec_slave[dout].outputs) {
        std::printf("no EL2008 with mapped outputs found\n"); ec_close(); return 1;
    }
    std::printf("EL2008 at position %d\n", dout);

    // SAFE-OP → OP (one valid process-data frame required before the request)
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
    std::printf("OP — all RUN LEDs solid green. Chasing for %d s...\n", seconds);

    const int expectedWkc = ec_group[0].outputsWKC * 2 + ec_group[0].inputsWKC;
    const int cycles = seconds * 100;            // 10 ms cycle
    int bad = 0, pos = 0, dir = 1;
    for (int c = 0; c < cycles; c++) {
        uint8_t out;
        if (c < cycles - 300) {                  // Knight-Rider chase
            if (c % 8 == 0) {                    // step every 80 ms
                pos += dir;
                if (pos >= 7) dir = -1;
                if (pos <= 0) dir = 1;
            }
            out = uint8_t(1u << pos);
        } else {                                 // finale: triple all-flash
            out = ((c / 50) % 2) ? 0xFF : 0x00;
        }
        *ec_slave[dout].outputs = out;
        ec_send_processdata();
        if (ec_receive_processdata(EC_TIMEOUTRET) < expectedWkc) bad++;
        usleep(10000);
    }
    *ec_slave[dout].outputs = 0;                 // lights out
    ec_send_processdata();
    ec_receive_processdata(EC_TIMEOUTRET);

    std::printf("done: %d cycles, %d bad WKC\n", cycles, bad);
    ec_slave[0].state = EC_STATE_INIT;
    ec_writestate(0);
    ec_close();
    return 0;
}
