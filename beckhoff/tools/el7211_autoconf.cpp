// el7211_autoconf — read the connected motor's OCT type plate and write the
// terminal's motor settings from it. Does what Beckhoff's autoconfig is
// supposed to do and, on this terminal, does not.
//
//   sudo ./el7211_autoconf <iface> <slave> [--write] [velLimitRpm]
//
// Without --write it only REPORTS: identity, what is currently configured, and
// what it would change. Nothing is written unless you ask.
//
// Why this exists: 0x8008:01 "Enable autoconfig" reads 1 on this terminal, the
// nameplate is read into 0x9008/0x9009 — and 0x8011 stays at factory defaults
// anyway. See QUIRKS.md. Swapping to a SMALLER motor while the previous, larger
// motor's rated current is still configured leaves the I2T thermal model
// protecting a motor that is not connected, so reconfigure BEFORE enabling.
#include <ethercat.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static char ioMap[4096];

// Motors this terminal may drive (manual p.20). Anything else has no supported
// feedback path and must not be energised.
static const char *APPROVED[] = {
    "AM8111", "AM8112", "AM8113", "AM8121", "AM8122",
    "AM8131", "AM8132", "AM8133", "AM8141", nullptr
};

static long rd(int s, uint16_t i, uint8_t sub) {
    uint32_t v = 0; int sz = sizeof(v);
    return ec_SDOread(s, i, sub, FALSE, &sz, &v, EC_TIMEOUTRXM) > 0 ? long(v) : -1;
}

static void rdStr(int s, uint16_t i, uint8_t sub, char *out, int outLen) {
    uint8_t buf[64] = {0}; int sz = int(sizeof buf);
    out[0] = 0;
    if (ec_SDOread(s, i, sub, FALSE, &sz, buf, EC_TIMEOUTRXM) <= 0) return;
    int n = 0;
    for (int k = 0; k < sz && k < outLen - 1 && buf[k]; k++)
        out[n++] = (buf[k] >= 0x20 && buf[k] < 0x7F) ? char(buf[k]) : '.';
    out[n] = 0;
}

template <typename T> static bool wr(int s, uint16_t i, uint8_t sub, T v) {
    const bool ok = ec_SDOwrite(s, i, sub, FALSE, sizeof(T), &v, EC_TIMEOUTRXM) > 0;
    if (!ok) {
        std::printf("    WRITE 0x%04X:%02X FAILED", i, sub);
        while (EcatError) std::printf("  [%s]", ec_elist2string());
        std::printf("\n");
    }
    return ok;
}

// log2 for exact powers of two — encoder resolution and range are always 2^n.
static int bitsOf(long v) {
    int b = 0;
    while (v > 1) { v >>= 1; b++; }
    return b;
}

int main(int argc, char **argv) {
    const char *iface = argc > 1 ? argv[1] : "enp4s0";   // xylosome C6920
    const int   sl    = argc > 2 ? std::atoi(argv[2]) : 8;        // EL7211-9014 at 8
    bool doWrite = false;
    long velLimit = 1000;                      // conservative bench default
    for (int i = 3; i < argc; i++) {
        if (!std::strcmp(argv[i], "--write")) doWrite = true;
        else velLimit = std::atol(argv[i]);
    }

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); ec_close(); return 1; }
    if (sl < 1 || sl > ec_slavecount) {
        std::printf("slave %d out of range (1..%d)\n", sl, ec_slavecount); ec_close(); return 1;
    }
    ec_config_map(ioMap);
    ec_slave[sl].state = EC_STATE_PRE_OP;      // config objects are writable in PRE-OP
    ec_writestate(sl);
    ec_statecheck(sl, EC_STATE_PRE_OP, EC_TIMEOUTSTATE * 4);

    char vendor[64], type[64], serial[64], order[64], constr[64], fbType[64];
    rdStr(sl, 0x9009, 0x01, vendor, sizeof vendor);
    rdStr(sl, 0x9009, 0x02, type,   sizeof type);
    rdStr(sl, 0x9009, 0x03, serial, sizeof serial);
    rdStr(sl, 0x9009, 0x04, order,  sizeof order);
    rdStr(sl, 0x9009, 0x05, constr, sizeof constr);
    rdStr(sl, 0x9008, 0x14, fbType, sizeof fbType);

    std::printf("slave %d: %s\n\n", sl, ec_slave[sl].name);
    std::printf("=== MOTOR TYPE PLATE (read from the motor itself) ===\n");
    std::printf("  vendor        %s\n  type          %s\n  order code    %s\n",
                vendor, type, order);
    std::printf("  serial        %s\n  construction  %s\n  feedback      %s\n\n",
                serial, constr, fbType);

    if (!order[0]) {
        std::printf("NO TYPE PLATE READ. Either no motor is connected, the OCT pair\n"
                    "(White->1, Blue->9) is not wired, or it is not an OCT motor.\n");
        ec_close(); return 1;
    }

    bool approved = false;
    for (int i = 0; APPROVED[i]; i++)
        if (!std::strncmp(order, APPROVED[i], std::strlen(APPROVED[i]))) approved = true;
    if (!approved) {
        std::printf("*** '%s' IS NOT ON THE APPROVED MOTOR LIST (manual p.20) ***\n"
                    "This terminal may only drive AM8111/8112/8113/8121/8122/8131/8132/\n"
                    "8133/8141. Refusing to configure it.\n", order);
        ec_close(); return 1;
    }

    // Nameplate -> settings.
    const long ratedI  = rd(sl, 0x9009, 0x08);      // mA rms
    const long peakI   = rd(sl, 0x9009, 0x09);      // mA rms
    const long poles   = rd(sl, 0x9009, 0x06);
    const long torqueK = rd(sl, 0x9009, 0x0E);      // mNm/A
    const long inertia = rd(sl, 0x9009, 0x14);      // g cm^2
    const long ld      = rd(sl, 0x9009, 0x11);      // 0.1 mH
    const long maxRpm  = rd(sl, 0x9009, 0x13);      // rpm
    const long resol   = rd(sl, 0x9008, 0x12);      // steps/rev
    const long range   = rd(sl, 0x9008, 0x13);      // revolutions

    // The EL7211 delivers 4.5 A rms / 9 A peak. A larger motor's nameplate peak
    // must NOT be written through blindly.
    const long TERMINAL_PEAK_MA = 9000;
    const long useMaxI = peakI > TERMINAL_PEAK_MA ? TERMINAL_PEAK_MA : peakI;

    const int stBits = bitsOf(resol);
    int mtBits = bitsOf(range);
    // A SINGLE-TURN encoder reports range = 1 revolution, i.e. 0 multi-turn
    // bits — and writing that faithfully makes the reported position wrap every
    // revolution, which makes multi-revolution moves dangerous (a wrap mid-move
    // looks to the drive like the axis jumped a full turn backwards).
    //
    // Measured on the bench: allocating 12 multi-turn bits anyway makes the
    // TERMINAL count revolutions itself — verified continuous across 8 turns by
    // hand with a single-turn EKS36. The encoder still cannot know turns across
    // a power cycle, so absolute position after power-up is only valid within
    // one revolution; but motion within a session works normally.
    const bool singleTurn = (mtBits == 0);
    if (singleTurn) mtBits = 12;

    // Velocity loop proportional gain scales with rotor inertia for constant
    // loop bandwidth. Beckhoff's default is 150, which is stable on a 52 g cm^2
    // AM8112 but RINGS on the 33 g cm^2 AM8111 — measured as +/-1000 per-mille
    // torque oscillation at standstill, audible as a loud buzz. Scaling by
    // inertia predicts ~95, and 100 measured 6x quieter than 150 (peak-to-peak
    // torque ripple 6 vs 40) with the buzz completely gone.
    //
    // 150 / 52 g cm^2 = 2.885 per g cm^2 is therefore the empirical reference.
    long velGain = long(2.885 * double(inertia) + 0.5);
    if (velGain < 20)  velGain = 20;
    if (velGain > 300) velGain = 300;

    std::printf("=== NAMEPLATE -> SETTINGS ===\n");
    std::printf("  %-28s %10s   %10s\n", "", "currently", "from plate");
    struct Row { const char *name; uint16_t idx; uint8_t sub; long want; int size; };
    const Row rows[] = {
        { "0x8011:11 max current (mA)",   0x8011, 0x11, useMaxI,  4 },
        { "0x8011:12 rated current (mA)", 0x8011, 0x12, ratedI,   4 },
        { "0x8011:13 pole pairs",         0x8011, 0x13, poles,    1 },
        { "0x8011:15 commutation offset", 0x8011, 0x15, -90,      2 },
        { "0x8011:16 torque const mNm/A", 0x8011, 0x16, torqueK,  4 },
        { "0x8011:18 rotor inertia",      0x8011, 0x18, inertia,  4 },
        { "0x8011:19 winding inductance", 0x8011, 0x19, ld,       2 },
        { "0x8011:1B motor speed limit",  0x8011, 0x1B, maxRpm,   4 },
        { "0x8000:12 single-turn bits",   0x8000, 0x12, stBits,   1 },
        { "0x8000:13 multi-turn bits",    0x8000, 0x13, mtBits,   1 },
        { "0x8010:31 velocity limit rpm", 0x8010, 0x31, velLimit, 4 },
        { "0x8010:15 velocity loop gain", 0x8010, 0x15, velGain,  4 },
    };
    const int nRows = int(sizeof rows / sizeof rows[0]);
    for (int i = 0; i < nRows; i++) {
        const long cur = rd(sl, rows[i].idx, rows[i].sub);
        std::printf("  %-28s %10ld   %10ld %s\n", rows[i].name, cur, rows[i].want,
                    cur == (rows[i].want < 0 ? (rows[i].want & 0xFFFF) : rows[i].want)
                      ? "" : "<- CHANGE");
    }
    if (peakI > TERMINAL_PEAK_MA)
        std::printf("\n  note: nameplate peak %ld mA exceeds the terminal's %ld mA — clamped.\n",
                    peakI, TERMINAL_PEAK_MA);
    if (singleTurn)
        std::printf("\n  SINGLE-TURN encoder (nameplate range = 1 rev). Allocating 12 multi-turn\n"
                    "  bits anyway so the TERMINAL counts revolutions — verified on the bench.\n"
                    "  Absolute position across a power cycle is only valid within one rev.\n");
    std::printf("\n  commutation offset is ALWAYS -90 deg for this terminal (manual p.155).\n");
    std::printf("  velocity limit set to %ld rpm — pass a number to change it.\n", velLimit);

    if (!doWrite) {
        std::printf("\nDRY RUN. Nothing written. Re-run with --write to apply.\n");
        ec_slave[sl].state = EC_STATE_INIT; ec_writestate(sl); ec_close();
        return 0;
    }

    std::printf("\n=== WRITING ===\n");
    bool ok = true;
    for (int i = 0; i < nRows; i++) {
        const Row &r = rows[i];
        if      (r.size == 1) ok &= wr<uint8_t>(sl, r.idx, r.sub, uint8_t(r.want));
        else if (r.size == 2) ok &= wr<uint16_t>(sl, r.idx, r.sub, uint16_t(r.want));
        else                  ok &= wr<uint32_t>(sl, r.idx, r.sub, uint32_t(r.want));
    }
    std::printf("\n=== VERIFY ===\n");
    for (int i = 0; i < nRows; i++)
        std::printf("  %-28s = %ld\n", rows[i].name, rd(sl, rows[i].idx, rows[i].sub));

    std::printf("\n%s\n", ok ? "All writes accepted. Power-cycle the drive, then run el7211_csp."
                             : "SOME WRITES FAILED — do not enable the drive.");
    ec_slave[sl].state = EC_STATE_INIT; ec_writestate(sl); ec_close();
    return ok ? 0 : 1;
}
