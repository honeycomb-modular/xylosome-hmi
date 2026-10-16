// el7211_csp — CSP bring-up for the Beckhoff EL7211-9014 (MDP 742 profile).
//
//   sudo ./el7211_csp <iface> [slavePos=2] [sweepCounts=0] [seconds=10]
//
// COLOUR WHEEL GUARD: every mode is confined to +-30 deg (--max-deg=N) around
// the pose at enable, and leaving it trips quick stop + disable. Spin mode
// (negative sweep) refuses to run without --allow-spin (wheel OFF only).
//
// ⚠️ NEVER RUN ON HARDWARE. Written from the manual, not yet run against a
// real terminal. Every claim below traces to docs/manuals/EL72x1-901x_en.pdf;
// none of it has been confirmed on the bench. Treat the first run as an
// experiment, with the motor free and nothing attached to the shaft.
//
// Why this exists instead of motor_test.cpp: the -9014 speaks Beckhoff's
// MDP 742 profile, not DS402. motor_test.cpp remaps DS402 indices (0x6040,
// 0x607A, 0x6064) which this terminal does not implement — that is the -9015.
// See QUIRKS.md.
//
//   controlword      0x7010:01   (2 bytes)   via RxPDO 0x1600
//   target position  0x7010:05   (4 bytes)   via RxPDO 0x1606
//   position actual  0x6000:11   (4 bytes)   via TxPDO 0x1A00  <- FB, not DRV
//   statusword       0x6010:01   (2 bytes)   via TxPDO 0x1A01
//   modes of op      0x7010:03   (1 byte, SDO) = 8 for CSP
//
// sweepCounts defaults to 0 — enable and report, but DO NOT MOVE. The motor's
// counts-per-revolution is not known until the OCT nameplate is read, so there
// is no safe default distance. Pass an explicit count when you want motion.
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

// PDO order follows the assignment order below, so the structs must match it.
struct Rx { uint16_t cw; int32_t target; } __attribute__((packed));   // 0x1600, 0x1606
// 0x1A00 FB Position, 0x1A01 DRV Statusword, 0x1A03 DRV Torque actual value.
// Torque actual (0x6010:08) is the drive's measured current expressed as a
// per-mille of rated torque — the only way to see what the motor is actually
// drawing DURING a run, since SDO reads are impossible while in OP.
struct Tx { int32_t pos; uint16_t sw; int16_t torque; } __attribute__((packed));

template <typename T> static bool sdoW(int s, uint16_t i, uint8_t sub, T v) {
    const bool ok = ec_SDOwrite(s, i, sub, FALSE, sizeof(T), &v, EC_TIMEOUTRXM) > 0;
    if (!ok) {
        std::printf("  SDO write 0x%04X:%02X FAILED", i, sub);
        while (EcatError) std::printf("  [%s]", ec_elist2string());
        std::printf("\n");
    }
    return ok;
}

static long sdoR(int s, uint16_t i, uint8_t sub) {
    uint32_t v = 0; int sz = sizeof(v);
    return ec_SDOread(s, i, sub, FALSE, &sz, &v, EC_TIMEOUTRXM) > 0 ? long(v) : -1;
}

// --peek: raw SDO reads/writes and a timestamped diag-history dump, then exit.
// Lets us ask the drive questions (is STO actually seen? is 0x441C stale?)
// without walking the enable sequence. Items after --peek:
//   r:IDX:SUB[:N]     read N consecutive subindices (hex idx/sub)
//   w:IDX:SUB:VAL:SZ  write VAL (hex) with SZ bytes
//   diag              newest 6 records of 0x10F3 with their timestamps
static void peekRead(int sl, int idx, int sub) {
    uint8_t buf[256] = {0}; int sz = int(sizeof buf);
    std::printf("  0x%04X:%02X ", idx, sub);
    if (ec_SDOread(sl, uint16_t(idx), uint8_t(sub), FALSE, &sz, buf, EC_TIMEOUTRXM) <= 0) {
        std::printf("-- fail");
        while (EcatError) std::printf("  [%s]", ec_elist2string());
        std::printf("\n"); return;
    }
    uint64_t v = 0; std::memcpy(&v, buf, sz > 8 ? 8 : sz);
    if (sz <= 8) std::printf("= %llu (0x%llX)", (unsigned long long)v, (unsigned long long)v);
    std::printf("  [");
    for (int i = 0; i < sz; i++) std::printf("%s%02X", i ? " " : "", buf[i]);
    std::printf("]\n");
}
static void peekDiag(int sl) {
    long newest = sdoR(sl, 0x10F3, 0x02);
    std::printf("  diag newest=%ld  flags(0x10F3:05)=0x%lX\n", newest, sdoR(sl, 0x10F3, 0x05));
    for (long k = newest; k >= 6 && k > newest - 6; k--) {
        uint8_t rec[64] = {0}; int sz = int(sizeof rec);
        if (ec_SDOread(sl, 0x10F3, uint8_t(k), FALSE, &sz, rec, EC_TIMEOUTRXM) <= 0) break;
        uint16_t fl = 0, tx = 0; uint64_t ts = 0;
        std::memcpy(&fl, rec + 4, 2); std::memcpy(&tx, rec + 6, 2); std::memcpy(&ts, rec + 8, 8);
        std::printf("  0x10F3:%02lX text=0x%04X flags=0x%04X ts=%.3f s (since 2000-01-01)  params:",
                    k, tx, fl, double(ts) / 1e9);
        for (int i = 16; i < sz; i++) std::printf(" %02X", rec[i]);
        std::printf("\n");
    }
}
// od        list every object index with its name (SDO info service)
// od:IDX    list the entries of one object with names and current values
// rail      list every slave on the bus (which terminal is at which position)
static void peekOd(int sl, int only) {
    ec_ODlistt odl; std::memset(&odl, 0, sizeof odl);
    if (!ec_readODlist(uint16_t(sl), &odl)) { std::printf("  OD list failed\n"); return; }
    for (uint16_t i = 0; i < odl.Entries; i++) {
        if (only >= 0 && odl.Index[i] != only) continue;
        ec_readODdescription(i, &odl);
        std::printf("  0x%04X  %s\n", odl.Index[i], odl.Name[i]);
        if (only < 0) continue;
        ec_OElistt oel; std::memset(&oel, 0, sizeof oel);
        ec_readOE(i, &odl, &oel);
        for (int s = 0; s <= odl.MaxSub[i]; s++) {
            if (!oel.DataType[s]) continue;
            std::printf("    :%02X %-40s ", s, oel.Name[s]);
            uint8_t buf[256] = {0}; int sz = int(sizeof buf);
            if (ec_SDOread(sl, odl.Index[i], uint8_t(s), FALSE, &sz, buf, EC_TIMEOUTRXM) <= 0) {
                std::printf("(no read)\n"); while (EcatError) ec_elist2string(); continue;
            }
            uint64_t v = 0; std::memcpy(&v, buf, sz > 8 ? 8 : sz);
            if (sz <= 8) std::printf("= %llu (0x%llX)\n", (unsigned long long)v, (unsigned long long)v);
            else { std::printf("["); for (int b = 0; b < sz; b++) std::printf("%s%02X", b ? " " : "", buf[b]); std::printf("]\n"); }
        }
    }
}
static int peek(int sl, int argc, char **argv, int from) {
    for (int a = from; a < argc; a++) {
        int idx = 0, sub = 0, n = 1, size = 0; char m = 0; unsigned long val = 0;
        if (!std::strcmp(argv[a], "diag")) { peekDiag(sl); continue; }
        if (!std::strcmp(argv[a], "od"))   { peekOd(sl, -1); continue; }
        if (!std::strncmp(argv[a], "od:", 3)) { peekOd(sl, int(std::strtol(argv[a] + 3, nullptr, 16))); continue; }
        if (!std::strcmp(argv[a], "rail")) {
            for (int i = 1; i <= ec_slavecount; i++) std::printf("  slave %2d: %s\n", i, ec_slave[i].name);
            continue;
        }
        if (argv[a][0] == 'w' && std::sscanf(argv[a], "%c:%x:%x:%lx:%d", &m, &idx, &sub, &val, &size) == 5) {
            const bool ok = ec_SDOwrite(sl, uint16_t(idx), uint8_t(sub), FALSE, size, &val, EC_TIMEOUTRXM) > 0;
            std::printf("  write 0x%04X:%02X = 0x%lX (%d bytes) -> %s\n", idx, sub, val, size, ok ? "ok" : "FAIL");
            continue;
        }
        if (std::sscanf(argv[a], "%c:%x:%x:%d", &m, &idx, &sub, &n) >= 3)
            for (int s = sub; s < sub + n; s++) peekRead(sl, idx, s);
    }
    ec_close(); return 0;
}

int main(int argc, char **argv) {
    // Separate flags from positionals FIRST. Mixing them bit once already:
    // "--monitor" landed in argv[5] (the cycle time), atol() made it 0, and the
    // tool tried to write a 0 ns SYNC cycle — which the drive rejected with
    // "value of parameter written too low", sending us after the wrong thing.
    const char *pos[16];
    int nPos = 0;
    bool monitorOnly = false;
    bool allowSpin = false;
    bool teachRed = false;    // --teach-red: monitor only (no torque), save the shaft angle as RED
    bool rgb = false;         // --rgb: cycle B(-sweep/2) -> G(+sweep/2) -> R(start), 0.5 s dwell each
    bool symmetric = false;   // --symmetric: trapezoid between start-sweep/2 and start+sweep/2 (B/G about R)
    // Colour wheel on the shaft (2026-10-16): no hard stop, so a full turn must
    // be impossible in software. Every mode is confined to +-maxDeg around the
    // pose at enable; leaving it trips a quick stop. --max-deg=N changes it.
    double maxDeg = 30.0;
    double tripDeg = -1.0;   // --trip-deg=N; default maxDeg + 3. Set below maxDeg to TEST the trip.
    int peekFrom = -1;
    for (int i = 0; i < argc && nPos < 16; i++) {
        if (peekFrom >= 0) break;   // everything after --peek belongs to peek()
        if (!std::strncmp(argv[i], "--", 2)) {
            if (!std::strcmp(argv[i], "--monitor")) monitorOnly = true;
            if (!std::strcmp(argv[i], "--peek"))    peekFrom = i + 1;
            if (!std::strcmp(argv[i], "--allow-spin")) allowSpin = true;
            if (!std::strcmp(argv[i], "--symmetric"))  symmetric = true;
            if (!std::strcmp(argv[i], "--rgb"))        { rgb = true; symmetric = true; }
            if (!std::strcmp(argv[i], "--teach-red"))  { teachRed = true; monitorOnly = true; }
            if (!std::strncmp(argv[i], "--max-deg=", 10)) maxDeg = std::atof(argv[i] + 10);
            if (!std::strncmp(argv[i], "--trip-deg=", 11)) tripDeg = std::atof(argv[i] + 11);
        } else {
            pos[nPos++] = argv[i];
        }
    }
    const char  *iface = nPos > 1 ? pos[1] : "enp4s0";   // xylosome C6920
    const int    sl    = nPos > 2 ? std::atoi(pos[2]) : 8;        // EL7211-9014 at 8
    const long   sweep = nPos > 3 ? std::atol(pos[3]) : 0;
    const double secs  = nPos > 4 ? std::atof(pos[4]) : 10.0;
    // Cycle time is a parameter because AL 0x0035 names it. The drive ships
    // expecting 250000 ns (0x1C32:02 default) with a 125000 ns minimum.
    const uint32_t CYCLE_NS = nPos > 5 ? uint32_t(std::atol(pos[5])) : 1000000;
    // repeats > 0 selects TRAPEZOIDAL point-to-point: move sweepCounts away,
    // dwell, move back, repeated `repeats` times.
    const int repeats = nPos > 6 ? std::atoi(pos[6]) : 0;
    // --monitor: reach OP and stream position, but NEVER walk the enable
    // sequence. The controlword stays at 0x0006 (shutdown), so the drive cannot
    // produce torque no matter what STO is doing. Use this to observe the
    // encoder while turning the shaft by hand — relying on a person holding an
    // STO button while their other hand is on the shaft is not a safe design.
    const double TRAP_VMAX_RPM   = nPos > 7 ? std::atof(pos[7]) : 600.0;  // cruise speed
    const double TRAP_ACCEL_RPS2 = nPos > 8 ? std::atof(pos[8]) : 40.0;   // rev/s^2
    const double TRAP_DWELL_S    = 0.35;   // pause at each end, so moves are visible
    std::signal(SIGINT, stop);

    if (!ec_init(iface)) { std::printf("ec_init(%s) failed — root? NIC name?\n", iface); return 1; }
    if (ec_config_init(FALSE) <= 0) { std::printf("no slaves on %s\n", iface); return 1; }
    if (sl < 1 || sl > ec_slavecount) {
        std::printf("slave %d out of range (1..%d)\n", sl, ec_slavecount); ec_close(); return 1;
    }
    std::printf("slave %d: %s\n", sl, ec_slave[sl].name);
    if (peekFrom >= 0) return peek(sl, argc, argv, peekFrom);
    // Refuse before touching the bus state. Spin mode is continuous rotation -
    // with the colour wheel fitted that is exactly the move that must never run.
    if (sweep < 0 && !allowSpin) {
        std::printf("REFUSED: spin mode (negative sweep) rotates continuously.\n"
                    "The colour wheel must never make a full turn. Remove the wheel,\n"
                    "then pass --allow-spin if you really mean it.\n");
        ec_close(); return 1;
    }
    if (tripDeg < 0.0) tripDeg = maxDeg + 3.0;
    if (!(maxDeg > 0.0 && maxDeg < 180.0) || !(tripDeg > 0.0 && tripDeg < 180.0)) {
        std::printf("REFUSED: --max-deg must be between 0 and 180 (got %g).\n", maxDeg);
        ec_close(); return 1;
    }
    if (sweep == 0)
        std::printf("sweepCounts=0 — will enable and report, NO MOTION commanded.\n");
    else
        std::printf("sweepCounts=%ld — WILL MOVE. Motor free? Shaft clear?\n", sweep);

    // An AL error LATCHES (state shows 0x1x) and the slave refuses further
    // transitions until it is acknowledged. Clear it first — otherwise a stale
    // error from a previous run looks exactly like a fresh configuration fault.
    ec_readstate();
    if (ec_slave[sl].state & EC_STATE_ERROR) {
        std::printf("slave has a latched AL error: state=0x%02X code=0x%04X (%s) — acknowledging\n",
                    unsigned(ec_slave[sl].state), unsigned(ec_slave[sl].ALstatuscode),
                    ec_ALstatuscode2string(ec_slave[sl].ALstatuscode));
        ec_slave[sl].state = EC_STATE_INIT + EC_STATE_ACK;
        ec_writestate(sl);
        ec_statecheck(sl, EC_STATE_INIT, EC_TIMEOUTSTATE * 4);
    }

    // PDO config is only legal in PRE-OP.
    ec_slave[sl].state = EC_STATE_PRE_OP;
    ec_writestate(sl);
    ec_statecheck(sl, EC_STATE_PRE_OP, EC_TIMEOUTSTATE * 4);
    if (ec_slave[sl].state != EC_STATE_PRE_OP) {
        ec_readstate();
        std::printf("not in PRE-OP: state=0x%02X code=0x%04X (%s)\n",
                    unsigned(ec_slave[sl].state), unsigned(ec_slave[sl].ALstatuscode),
                    ec_ALstatuscode2string(ec_slave[sl].ALstatuscode));
        ec_close(); return 1;
    }

    // Report config that decides whether this will work at all.
    std::printf("OCT autoconfig 0x8008:01 = %ld  (0 = OFF; motor nameplate NOT read)\n",
                sdoR(sl, 0x8008, 0x01));

    // Assign CSP process data. The DEFAULT Rx set is 0x1600 + 0x1601
    // (controlword + target VELOCITY) — 0x1601 must be replaced by 0x1606
    // or we would command velocity while believing we command position.
    bool ok = true;
    ok &= sdoW<uint8_t>(sl, 0x1C12, 0, 0);
    ok &= sdoW<uint16_t>(sl, 0x1C12, 1, 0x1600);      // DRV Controlword
    ok &= sdoW<uint16_t>(sl, 0x1C12, 2, 0x1606);      // DRV Target position
    ok &= sdoW<uint8_t>(sl, 0x1C12, 0, 2);

    ok &= sdoW<uint8_t>(sl, 0x1C13, 0, 0);
    ok &= sdoW<uint16_t>(sl, 0x1C13, 1, 0x1A00);      // FB Position   (0x6000:11)
    ok &= sdoW<uint16_t>(sl, 0x1C13, 2, 0x1A01);      // DRV Statusword
    ok &= sdoW<uint16_t>(sl, 0x1C13, 3, 0x1A03);      // DRV Torque actual value
    ok &= sdoW<uint8_t>(sl, 0x1C13, 0, 3);

    ok &= sdoW<uint8_t>(sl, 0x7010, 0x03, 8);         // modes of operation = CSP
    if (!ok) {
        std::printf("PDO assignment rejected — aborting before any motion.\n");
        ec_close(); return 1;
    }

    // ── Distributed clocks ───────────────────────────────────────────────────
    // This terminal REQUIRES DC ("must be operated with a real-time capable
    // computer and distributed clocks", manual p.20).
    //
    // Order matters and an earlier version got it wrong: ec_config_map() must
    // come BEFORE ec_configdc(), and SYNC0 is activated only once the slave is
    // in SAFE-OP. Doing DC first yields AL 0x0030 "Invalid DC SYNC
    // configuration". The cycle written to 0x1C32:02 must also match the cycle
    // handed to ec_dcsync0 — a 1 ms SYNC0 against a 250 us SM cycle is the same
    // error.
    // Only SM2 (outputs) goes on DC SYNC0. SM3 (inputs) is LEFT ALONE at its
    // default 0x1C33:01 = 0x22, "synchronous with SM2 event" — that is how
    // Beckhoff arranges it. Forcing SM3 to DC SYNC0 as well produced AL 0x0035
    // "DC invalid sync cycle time".
    sdoW<uint16_t>(sl, 0x1C32, 1, 2);                  // SM2: DC SYNC0
    sdoW<uint32_t>(sl, 0x1C32, 2, CYCLE_NS);
    sdoW<uint32_t>(sl, 0x1C33, 2, CYCLE_NS);           // input cycle only, not the type

    ec_config_map(ioMap);
    ec_configdc();
    if (ec_slave[sl].Obytes != sizeof(Rx) || ec_slave[sl].Ibytes != sizeof(Tx)) {
        std::printf("process image mismatch: O=%u (want %zu) I=%u (want %zu) — aborting.\n",
                    unsigned(ec_slave[sl].Obytes), sizeof(Rx),
                    unsigned(ec_slave[sl].Ibytes), sizeof(Tx));
        ec_close(); return 1;
    }

    mlockall(MCL_CURRENT | MCL_FUTURE);
    sched_param sp{}; sp.sched_priority = 60;
    if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0)
        std::printf("note: SCHED_FIFO unavailable (run with sudo) — continuing best-effort\n");
    ec_statecheck(0, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 4);

    // ── THE ORDER THAT ACTUALLY MATTERS ──────────────────────────────────────
    // This drive validates its DC configuration on the PRE-OP -> SAFE-OP
    // transition, not on the way to OP. ec_config_map() requests SAFE-OP itself,
    // so by the time we would normally arm SYNC0 the drive has already rejected
    // the transition with AL 0x0035 and latched the error.
    //
    // So: walk it back to PRE-OP, acknowledge, arm SYNC0+SYNC1 there, and only
    // then ask for SAFE-OP.
    ec_readstate();
    std::printf("after ec_config_map: slave %d state=0x%02X code=0x%04X (%s)\n",
                sl, unsigned(ec_slave[sl].state), unsigned(ec_slave[sl].ALstatuscode),
                ec_ALstatuscode2string(ec_slave[sl].ALstatuscode));

    ec_slave[sl].state = EC_STATE_INIT + EC_STATE_ACK;
    ec_writestate(sl);
    ec_statecheck(sl, EC_STATE_INIT, EC_TIMEOUTSTATE * 4);
    ec_slave[sl].state = EC_STATE_PRE_OP;
    ec_writestate(sl);
    ec_statecheck(sl, EC_STATE_PRE_OP, EC_TIMEOUTSTATE * 4);
    ec_readstate();
    std::printf("walked back: slave %d state=0x%02X code=0x%04X\n", sl,
                unsigned(ec_slave[sl].state), unsigned(ec_slave[sl].ALstatuscode));

    // The trip through INIT RESETS the slave, discarding the PDO assignment and
    // the mode of operation set earlier. Leaving it that way puts the drive in
    // DC mode with its default velocity PDOs, which it rejects with diagnosis
    // Text ID 0x8146 "Sync-Mode and PDO-Configuration are not compatible".
    // Re-apply here. The process image is 6 bytes either way, so the IOmap
    // built by ec_config_map() is still valid.
    ok = true;
    ok &= sdoW<uint8_t>(sl, 0x1C12, 0, 0);
    ok &= sdoW<uint16_t>(sl, 0x1C12, 1, 0x1600);      // DRV Controlword
    ok &= sdoW<uint16_t>(sl, 0x1C12, 2, 0x1606);      // DRV Target position
    ok &= sdoW<uint8_t>(sl, 0x1C12, 0, 2);
    ok &= sdoW<uint8_t>(sl, 0x1C13, 0, 0);
    ok &= sdoW<uint16_t>(sl, 0x1C13, 1, 0x1A00);      // FB Position (0x6000:11)
    ok &= sdoW<uint16_t>(sl, 0x1C13, 2, 0x1A01);      // DRV Statusword
    ok &= sdoW<uint16_t>(sl, 0x1C13, 3, 0x1A03);      // DRV Torque actual value
    ok &= sdoW<uint8_t>(sl, 0x1C13, 0, 3);
    ok &= sdoW<uint8_t>(sl, 0x7010, 0x03, 8);         // modes of operation = CSP
    // The sync MODE resets too. Leaving 0x1C32:01 = 1 (SM-synchronous) while
    // DC SYNC0/SYNC1 is actually running is precisely the mismatch that
    // diagnosis 0x8146 complains about.
    ok &= sdoW<uint16_t>(sl, 0x1C32, 1, 2);           // SM2: DC SYNC0
    ok &= sdoW<uint32_t>(sl, 0x1C32, 2, CYCLE_NS);
    ok &= sdoW<uint32_t>(sl, 0x1C33, 2, CYCLE_NS);
    if (!ok) {
        std::printf("PDO re-assignment after walk-back failed — aborting.\n");
        ec_close(); return 1;
    }
    std::printf("PDO + sync mode re-applied after INIT reset (CSP, 0x1600+0x1606, DC)\n");

    // ── SAFETY GATE ──────────────────────────────────────────────────────────
    // Verify what is ACTUALLY mapped before we ever write a target into the
    // process image. The drive's DEFAULT RxPDO set is 0x1600 + 0x1601 =
    // controlword + target VELOCITY. Our 6-byte image is {u16 cw, i32 target}
    // with target a POSITION of order 20,000,000. If the assignment has
    // silently reverted to default, those identical bytes are read as a
    // velocity command of 20 million — a full-speed runaway.
    //
    // The assignment demonstrably reverts on any INIT transition, so this is a
    // live hazard, not a theoretical one. Refuse to run unless 0x1606 is
    // confirmed mapped.
    const long rx1 = sdoR(sl, 0x1C12, 1), rx2 = sdoR(sl, 0x1C12, 2);
    const long modes = sdoR(sl, 0x7010, 0x03);
    std::printf("SAFETY CHECK: 0x1C12 = [0x%04lX, 0x%04lX], modes of operation = %ld\n",
                rx1, rx2, modes);
    if (rx1 != 0x1600 || rx2 != 0x1606 || modes != 8) {
        std::printf("\n*** REFUSING TO RUN ***\n"
                    "Expected RxPDO [0x1600, 0x1606] and mode 8 (CSP).\n"
                    "Got [0x%04lX, 0x%04lX] mode %ld.\n"
                    "If 0x1601 (target VELOCITY) is mapped, the position value this\n"
                    "tool writes would be interpreted as a velocity command.\n", rx1, rx2, modes);
        ec_slave[0].state = EC_STATE_INIT;
        ec_writestate(0);
        ec_close();
        return 1;
    }

    // Read back what the drive ACTUALLY holds at this point — the PREOP->SAFEOP
    // transition can discard what we wrote in PRE-OP, and if 0x1C32:02 has
    // reverted then SYNC0 and the drive disagree, which is AL 0x0035.
    std::printf("at SAFE-OP: 0x1C32:01=%ld 0x1C32:02=%ld | 0x1C33:01=%ld 0x1C33:02=%ld\n",
                sdoR(sl, 0x1C32, 1), sdoR(sl, 0x1C32, 2),
                sdoR(sl, 0x1C33, 1), sdoR(sl, 0x1C33, 2));

    // ec_dcsync0() derives SYNC0's start time from ec_DCtime, and ec_DCtime is
    // only populated once process data has actually been exchanged. Calling it
    // straight after ec_configdc() — before a single frame has gone out —
    // programmes a start time from a clock that has not ticked, which the drive
    // rejects as AL 0x0035. So: run frames first, let DC propagate, then arm it.
    for (int i = 0; i < 200; i++) {
        ec_send_processdata();
        ec_receive_processdata(EC_TIMEOUTRET);
        timespec ts{0, 1000000};
        nanosleep(&ts, nullptr);
    }
    std::printf("DC time propagated (ec_DCtime=%lld) — arming SYNC0+SYNC1\n", (long long)ec_DCtime);

    // The ESI for this terminal (Beckhoff EL72xx.xml, EL7211-9014) declares:
    //     <AssignActivate>#x700</AssignActivate>
    //     <ShiftTimeSync0 Input="0">30000</ShiftTimeSync0>
    //     <CycleTimeSync1 Factor="-1">0</CycleTimeSync1>
    // 0x700 sets bits 0,1,2 of the DC activation register = cyclic + SYNC0 +
    // SYNC1. ec_dcsync0() can only ever produce 0x03 (cyclic + SYNC0), which is
    // what the register dump showed — hence AL 0x0035 at every cycle time.
    // SYNC1 is mandatory here, so use ec_dcsync01() with the ESI's 30 us shift.
    // CyclTime1 = 0, matching the ESI's <CycleTimeSync1 Factor="-1">0</...>:
    // SYNC1 is subordinate to SYNC0, firing once per SYNC0 pulse. Passing
    // CyclTime1 = CyclTime0 instead makes SOEM compute
    // TrueCyclTime = ((CyclTime1/CyclTime0)+1)*CyclTime0 = 2x the cycle, which
    // aligns the start time to the wrong boundary.
    ec_dcsync01(uint16(sl), TRUE, CYCLE_NS, 0, 30000);
    std::printf("SYNC0+SYNC1 running at %u ns, shift 30000 ns\n", unsigned(CYCLE_NS));

    // NOW request SAFE-OP, with DC already ticking.
    ec_slave[sl].state = EC_STATE_SAFE_OP;
    ec_writestate(sl);
    for (int i = 0; i < 300; i++) {
        ec_send_processdata();
        ec_receive_processdata(EC_TIMEOUTRET);
        timespec ts{0, long(CYCLE_NS)};
        nanosleep(&ts, nullptr);
    }
    ec_statecheck(sl, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 4);
    ec_readstate();
    std::printf("SAFE-OP with DC armed: slave %d state=0x%02X code=0x%04X (%s)\n",
                sl, unsigned(ec_slave[sl].state), unsigned(ec_slave[sl].ALstatuscode),
                ec_ALstatuscode2string(ec_slave[sl].ALstatuscode));

    auto *rx = reinterpret_cast<Rx *>(ec_slave[sl].outputs);
    auto *tx = reinterpret_cast<Tx *>(ec_slave[sl].inputs);

    // DC phase-locked cyclic engine. A DC drive needs gap-free frames at cycle
    // time from BEFORE the OP request — see the A6-EC note in QUIRKS.md.
    static int64 integral = 0;
    int64 toff = 0;
    auto dcAlign = [&]() {
        // Aim a quarter-cycle after the SYNC0 edge, whatever the cycle is.
        int64 delta = (ec_DCtime - int64(CYCLE_NS) / 4) % int64(CYCLE_NS);
        if (delta > int64(CYCLE_NS) / 2) delta -= int64(CYCLE_NS);
        integral += (delta > 0) - (delta < 0);
        toff = -(delta / 100) - (integral / 20);
    };
    timespec next; clock_gettime(CLOCK_MONOTONIC, &next);
    auto cycleSleep = [&]() {
        long ns = next.tv_nsec + long(CYCLE_NS) + long(toff);
        next.tv_sec += ns / 1000000000L; ns %= 1000000000L;
        if (ns < 0) { ns += 1000000000L; next.tv_sec--; }
        next.tv_nsec = ns;
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, nullptr);
    };

    // Hold the commanded position at wherever the axis already is, so the
    // transition to OP cannot produce a jump.
    for (int i = 0; i < 500 && run_; i++) {
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        rx->target = tx->pos;
        dcAlign(); cycleSleep();
    }
    ec_slave[0].state = EC_STATE_OPERATIONAL;
    ec_writestate(0);
    for (int w = 0; w < 5000 && run_ && ec_slave[0].state != EC_STATE_OPERATIONAL; w++) {
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        rx->target = tx->pos;
        dcAlign(); cycleSleep();
        if (w % 200 == 199) ec_readstate();
    }
    // Check THIS slave, not ec_slave[0] (the group aggregate). The aggregate can
    // read OPERATIONAL while the drive we care about is still stuck in PRE-OP —
    // which is exactly how an earlier version of this tool reported success it
    // had not earned.
    ec_readstate();
    if (ec_slave[sl].state != EC_STATE_OPERATIONAL) {
        std::printf("slave %d did NOT reach OP: state=0x%02X code=0x%04X (%s)\n",
                    sl, unsigned(ec_slave[sl].state), unsigned(ec_slave[sl].ALstatuscode),
                    ec_ALstatuscode2string(ec_slave[sl].ALstatuscode));
        for (int i = 1; i <= ec_slavecount; i++)
            std::printf("   slave %d %-14s state=0x%02X code=0x%04X\n", i, ec_slave[i].name,
                        unsigned(ec_slave[i].state), unsigned(ec_slave[i].ALstatuscode));
        rx->cw = 0x0000;
        ec_send_processdata(); ec_receive_processdata(EC_TIMEOUTRET);
        ec_dcsync01(uint16(sl), FALSE, 0, 0, 0);
        ec_close(); return 1;
    }
    std::printf("slave %d OPERATIONAL (phase-locked) — walking the DS402 state machine…\n", sl);

    // NOT const, and NOT trusted until the drive is actually enabled. Latching
    // it here reads the process image before the drive is producing valid data,
    // which yields 0 — and then CSP commands position 0 against an axis sitting
    // at 700-million counts. That is an instant fault, and it hid behind the
    // earlier (broken) clamp because the target chased the measured position.
    int32_t startPos = tx->pos;

    // Counts per revolution, read from the motor's own nameplate rather than
    // assumed — 0x9008:12 "Resolution, steps per revolution".
    const double CPR = double(sdoR(sl, 0x9008, 0x12));
    // Angle window in counts. Only spin mode with --allow-spin (wheel off) is exempt.
    const bool    windowed = !(sweep < 0 && allowSpin);
    const int32_t winCnt   = int32_t(maxDeg / 360.0 * CPR);
    const int32_t tripCnt  = int32_t(tripDeg / 360.0 * CPR);   // default 3 deg past the clamp
    bool   tripped = false;
    double tTrip   = 0.0;

    // RED = the colour wheel's home, taught by hand (--teach-red) and stored as
    // the encoder's SINGLE-TURN angle. The EKS36 is absolute within one turn, so
    // that angle means the same physical spot after hand-turning or a power
    // cycle; the multi-turn part of the position is only the terminal counting
    // since power-up and is ignored. With RED known, the angle window and trip
    // are centred on RED, not on wherever the shaft happens to sit at enable.
    const char *RED_FILE = "/var/lib/xylod/el7211_red";
    const long long ST = (CPR > 0.0) ? (long long)CPR : 1;
    auto stAngle = [&](long long p) { return ((p % ST) + ST) % ST; };       // 0..ST-1
    auto stDelta = [&](long long a) { long long d = stAngle(a);              // -ST/2..ST/2-1
                                      return d >= ST / 2 ? d - ST : d; };
    long long redSt = -1;
    if (!teachRed) {
        if (FILE *f = std::fopen(RED_FILE, "r")) {
            if (std::fscanf(f, "%lld", &redSt) != 1 || redSt < 0 || redSt >= ST) redSt = -1;
            std::fclose(f);
        }
        if (redSt >= 0)
            std::printf("RED home loaded: single-turn %lld (%s); window centred on RED\n",
                        redSt, RED_FILE);
        else
            std::printf("no RED home (%s) - window centred on the pose at enable\n", RED_FILE);
    }
    int32_t center = 0;
    // Enable is HELD until the start pose is confirmed inside the RED window.
    // Position reads 0 while the drive sits in switch-on-disabled (0x0060), so
    // it is only judged after >= 50 consecutive cycles in ready-to-switch-on.
    bool redOk = (redSt < 0) || !windowed;
    int  readyCycles = 0;                    // window/trip anchor: RED, or startPos without it
    if (windowed && (CPR <= 0.0 || std::labs(symmetric ? sweep / 2 : sweep) > winCnt)) {   // symmetric: endpoints at +-sweep/2
        std::printf("\nREFUSED: %s (CPR=%.0f, sweep=%ld counts, window=+-%.1f deg = %d counts)\n",
                    CPR <= 0.0 ? "cannot read counts/rev 0x9008:12" : "sweep exceeds the angle window",
                    CPR, sweep, maxDeg, winCnt);
        run_ = false;
    } else if (windowed) {
        std::printf("angle window +-%.1f deg (+-%d counts) around the pose at enable; "
                    "trip at +-%.1f deg\n", maxDeg, winCnt, double(tripCnt) / CPR * 360.0);
    } else {
        std::printf("*** --allow-spin: NO angle window. Wheel must be OFF. ***\n");
    }
    double spinCounts = 0.0;                       // accumulated spin target

    // ── Trapezoidal point-to-point state (used when `repeats` > 0) ───────────
    // Classic profile: accelerate at ACCEL until VMAX, cruise, then decelerate
    // so the axis arrives at the target with zero velocity. The "should I be
    // decelerating yet" test is the standard one — compare the distance left
    // against v^2/(2a) — which automatically degrades to a triangular profile
    // when the move is too short to ever reach VMAX.
    const double VMAX  = TRAP_VMAX_RPM / 60.0 * CPR;   // counts/s
    const double ACCEL = TRAP_ACCEL_RPS2 * CPR;        // counts/s^2
    double cmdPos = 0.0, vel = 0.0, dwell = 0.0;
    int32_t posA = 0, posB = 0, tgt = 0;
    int movesDone = 0;
    bool trapInit = false;
    double t = 0.0, tEn = -1.0;
    bool enabled = false;

    while (run_ && t < secs + 5.0) {
        t += 0.001;
        ec_send_processdata();
        const int wkc = ec_receive_processdata(EC_TIMEOUTRET);

        // -- ANGLE WINDOW TRIP ------------------------------------------------
        // Measured, not commanded: whatever the cause (bad target arithmetic,
        // PDO mis-map, feedback jump), once the shaft is outside the window the
        // drive gets quick stop (0x0002, drive-internal emergency ramp), then
        // disable voltage, and the run ends. Checked before anything else.
        if (windowed && enabled && !tripped &&
            (tx->pos > center + tripCnt || tx->pos < center - tripCnt)) {
            tripped = true; tTrip = t;
            std::printf("\n*** ANGLE WINDOW TRIP: pos %+d counts (%+.1f deg) from enable pose - "
                        "quick stop + disable ***\n",
                        tx->pos - center, double(tx->pos - center) / CPR * 360.0);
        }
        if (tripped) {
            rx->cw = (t - tTrip) < 0.2 ? 0x0002 : 0x0000;
            rx->target = tx->pos;
            if (t - tTrip > 0.4) break;
            dcAlign(); cycleSleep();
            continue;
        }

        // MDP 742 keeps the standard CiA-402 state machine bit layout.
        const uint16_t sw = tx->sw;
        uint16_t cw = 0x0006;
        // Fault reset is EDGE-triggered on controlword bit 7. Holding 0x0080
        // high gives the drive exactly one edge and then nothing — a latched
        // fault (e.g. after an STO event) never clears. Toggle it instead, so
        // there is a fresh rising edge every 100 ms until the fault goes.
        if      ((sw & 0x004F) == 0x0008)
            cw = (int(t * 1000) / 50) % 2 ? 0x0080 : 0x0000;           // fault -> pulsed reset
        else if ((sw & 0x004F) == 0x0040) cw = 0x0006;                 // shutdown
        else if ((sw & 0x006F) == 0x0021) cw = redOk ? 0x0007 : 0x0006;                 // switch on
        else if ((sw & 0x006F) == 0x0023) cw = 0x000F;                 // enable operation
        else if ((sw & 0x006F) == 0x0027) { cw = 0x000F; if (!enabled) { enabled = true; tEn = t; } }
        // Hard interlock: in monitor mode the controlword never leaves
        // "shutdown", so no sequence of statuswords can walk the drive into
        // operation-enabled. Torque is impossible regardless of STO.
        if (monitorOnly) cw = 0x0006;
        rx->cw = cw;

        // Until the drive is enabled, keep the reference glued to where the axis
        // actually is, so the commanded position is always achievable and the
        // following error is zero at the instant torque appears. The moment we
        // reach "operation enabled", startPos latches and becomes the fixed
        // anchor for both the sweep and the clamp.
        if (!enabled) startPos = tx->pos;
        // Anchor on RED: the RED nearest the current pose, in this session's counts.
        center = (redSt >= 0) ? int32_t(startPos - stDelta((long long)startPos - redSt)) : startPos;
        readyCycles = ((sw & 0x006F) == 0x0021) ? readyCycles + 1 : 0;
        if (!redOk && !tripped && !monitorOnly && readyCycles >= 50 && tx->pos != 0) {
            if (startPos <= center + winCnt && startPos >= center - winCnt) {
                redOk = true;
                std::printf("\nstart pose %+.2f deg from RED - inside the window, enabling\n",
                            double(startPos - center) / CPR * 360.0);
            }
        }
        if (!redOk && !tripped && !monitorOnly && readyCycles >= 50 && tx->pos != 0 &&
            (startPos > center + winCnt || startPos < center - winCnt)) {
            tripped = true; tTrip = t;
            std::printf("\n*** START POSE OUTSIDE THE RED WINDOW: %+.1f deg from RED - no motion ***\n",
                        double(startPos - center) / CPR * 360.0);
            rx->cw = 0x0000; rx->target = tx->pos;
            dcAlign(); cycleSleep();
            continue;
        }

        int32_t target = startPos;

        // ── TRAPEZOIDAL POINT-TO-POINT ───────────────────────────────────────
        if (enabled && repeats > 0) {
            const double dt = double(CYCLE_NS) / 1e9;
            if (!trapInit) {                       // latch endpoints on first enabled cycle
                posA = symmetric ? center - int32_t(sweep / 2) : center;
                posB = symmetric ? center + int32_t(sweep / 2) : center + int32_t(sweep);
                cmdPos = double(startPos); tgt = rgb ? posA : posB; trapInit = true;
                std::printf("\ntrapezoid: A=%d  B=%d  (%.1f deg)  vmax=%.0f rpm  accel=%.0f rev/s^2\n",
                            posA, posB, double(sweep) / CPR * 360.0,
                            TRAP_VMAX_RPM, TRAP_ACCEL_RPS2);
            }

            if (dwell > 0.0) {
                dwell -= dt;                       // holding at an endpoint
            } else if (movesDone < (rgb ? repeats * 3 : repeats * 2 + 1)) {   // +1 = final move home to startPos
                const double remaining = std::fabs(double(tgt) - cmdPos);
                const double dir       = (double(tgt) > cmdPos) ? 1.0 : -1.0;
                const double decelDist = (vel * vel) / (2.0 * ACCEL);

                if (remaining <= decelDist) vel -= ACCEL * dt;          // brake
                else                        vel  = std::fmin(vel + ACCEL * dt, VMAX);
                if (vel < 0.0) vel = 0.0;

                const double step = vel * dt;
                if (step >= remaining) {           // arrived
                    cmdPos = double(tgt);
                    vel = 0.0;
                    movesDone++;
                    dwell = TRAP_DWELL_S;
                    tgt = (movesDone % 2) ? posA : posB;
                    // End every run where it began. Without this a run ends at an
                    // endpoint, the next run centres on it, and repeated runs walk
                    // the wheel round (2026-10-16: -15 deg per --symmetric run).
                    if (movesDone >= repeats * 2) tgt = center;
                    if (rgb) {                       // B -> G -> R, ends on R every cycle
                        const int32_t seq[3] = {posA, posB, center};
                        tgt = seq[movesDone % 3];
                        dwell = 0.5;
                    }
                    std::printf("\n  move %d/%d complete at %d\n",
                                movesDone, repeats * 2, int32_t(cmdPos));
                } else {
                    cmdPos += dir * step;
                }
            }
            {
                int32_t c = int32_t(cmdPos);
                if (windowed && c > center + winCnt) c = center + winCnt;
                if (windowed && c < center - winCnt) c = center - winCnt;
                rx->target = c;
            }

            if (int(t * 1000) % 20 == 0)
                std::printf("\n  pos=%+11d  cmd=%+11d  v=%+7.1f rpm  err=%+6d  torque=%+6d  sw=0x%04X",
                            tx->pos, int32_t(cmdPos), vel / CPR * 60.0,
                            tx->pos - int32_t(cmdPos), tx->torque, tx->sw);
            std::fflush(stdout);
            dcAlign(); cycleSleep();
            continue;
        }

        // ── SPIN MODE: negative sweep means "rotate at |sweep| rpm" ──────────
        // Continuous rotation, not a position sweep. Ramps up over 1 s and down
        // over the last 1 s — commanding a step change from 0 to full speed
        // demands infinite acceleration and will fault the drive on following
        // error. The position clamp is deliberately NOT applied here: it exists
        // to bound a sweep about a fixed point, and continuous rotation is
        // exactly the case it would (correctly) block.
        if (enabled && sweep < 0) {
            const double rpm     = double(-sweep);
            const double el      = t - tEn;                 // seconds since enabled
            const double left    = secs - el;
            // Ramp time scales with target speed: a fixed 1 s ramp to 8000 rpm
            // demands ~133 rev/s^2, which the drive cannot deliver and which
            // shows up as a following-error fault rather than a fast machine.
            const double rampT = std::fmax(1.0, rpm / 2000.0);
            double ramp = 1.0;
            if (el   < rampT) ramp = el / rampT;                        // ramp up
            if (left < rampT) ramp = left < 0.0 ? 0.0 : left / rampT;   // ramp down
            spinCounts += (rpm / 60.0) * CPR * ramp * (double(CYCLE_NS) / 1e9);
            rx->target = startPos + int32_t(spinCounts);
            if (int(t * 1000) % 250 == 0)
                std::printf("\nsw=0x%04X pos=%+11d  %+.1f rev  ramp=%.2f  torque=%+6d  wkc=%d",
                            tx->sw, tx->pos, (tx->pos - startPos) / CPR, ramp, tx->torque, wkc);
            std::fflush(stdout);
            dcAlign(); cycleSleep();
            continue;
        }

        if (enabled && sweep != 0) {
            // Stop on a zero crossing (every 4 s) and hold the enable pose, so a
            // run always ends where it began and repeated runs cannot walk.
            const double el   = t - tEn;
            const double tEnd = std::ceil(secs / 4.0) * 4.0;   // <= secs + 4 < loop end
            const double s = el < tEnd ? std::sin(2.0 * M_PI * el / 8.0) : 0.0;   // 8 s period
            target = startPos + int32_t(double(sweep) * s);
        }
        // Second safety net: a commanded target can never be further from the
        // measured position than the sweep amplitude plus a small margin. If
        // the process image is ever misinterpreted, or the feedback jumps, this
        // bounds what we ask for instead of trusting the arithmetic above.
        // Clamp against startPos — a FIXED reference — never against tx->pos.
        //
        // Clamping to the measured position creates a self-propelling loop: the
        // axis drifts, the clamp commands pos+maxDev, the drive faithfully goes
        // there, which moves pos, which moves the clamp again. That accelerates
        // until it hits the velocity limit and looks exactly like a runaway. It
        // is not — following error stays 0 because the drive is tracking
        // perfectly; the target is the thing running away.
        //
        // A limit must be anchored to something the controlled variable cannot
        // move.
        int32_t maxDev = int32_t(std::labs(sweep)) + 4096;   // ~5.6 deg margin
        if (windowed && maxDev > winCnt) maxDev = winCnt;    // never outside the angle window
        if (target > startPos + maxDev) target = startPos + maxDev;
        if (target < startPos - maxDev) target = startPos - maxDev;
        if (windowed && target > center + winCnt) target = center + winCnt;
        if (windowed && target < center - winCnt) target = center - winCnt;
        rx->target = target;

        if (int(t * 1000) % 250 == 0) {
            std::printf("\nsw=0x%04X pos=%+11d (%+d from start) torque=%+6d wkc=%d al=0x%02X",
                        sw, tx->pos, tx->pos - startPos, tx->torque, wkc,
                        unsigned(ec_slave[sl].state));
            if (redSt >= 0)
                std::printf("  red%+.2f deg", double(stDelta((long long)tx->pos - redSt)) / CPR * 360.0);
            if (teachRed)
                std::printf("  st=%lld", stAngle((long long)tx->pos));
        }
        std::fflush(stdout);

        dcAlign(); cycleSleep();
    }

    // Before dropping out of OP, ask the drive what it thinks it was doing.
    // 0x7010:03 is what WE set; 0x6010:03 is what the drive REPORTS. If those
    // disagree, the drive has been ignoring our target position and the whole
    // control picture is different from what the code assumes.
    // NOTE: do NOT read SDOs here. Mailbox transfers take tens of ms each, and
    // while they run no process data flows — with the drive still enabled in
    // OP, that trips its watchdog and logs 0x8105 PD-Watchdog, which latches
    // and costs a power cycle. The diagnostic reads happen AFTER shutdown.
    const int32_t lastTarget = rx->target;
    const uint16_t lastSw    = tx->sw;
    const int32_t lastPos    = tx->pos;

    // Shut down GENTLY. Sending one disable frame and immediately dropping to
    // INIT stops process data while the drive still considers itself enabled,
    // which trips its watchdog and logs 0x8105 PD-Watchdog — a latched fault
    // that needs a POWER CYCLE to clear. That made every run cost a power
    // cycle. Instead: command shutdown, keep the cyclic traffic flowing until
    // the drive confirms it has left "operation enabled", and only then leave OP.
    std::printf("\ndisabling…\n");
    for (int i = 0; i < 400; i++) {
        rx->cw = 0x0006;                       // shutdown
        rx->target = tx->pos;                  // never leave a stale target behind
        ec_send_processdata();
        ec_receive_processdata(EC_TIMEOUTRET);
        if ((tx->sw & 0x006F) != 0x0027 && i > 50) break;   // out of operation-enabled
        timespec ts{0, long(CYCLE_NS)};
        nanosleep(&ts, nullptr);
    }
    std::printf("  statusword after shutdown = 0x%04X\n", tx->sw);

    // Step DOWN through SAFE-OP while still sending frames, rather than jumping
    // from OP straight to INIT. Going straight to INIT stops process data while
    // the slave is still in OP, and the drive logs 0x8105 PD-Watchdog — which
    // latches and costs a power cycle.
    ec_slave[0].state = EC_STATE_SAFE_OP;
    ec_writestate(0);
    for (int i = 0; i < 200; i++) {
        ec_send_processdata();
        ec_receive_processdata(EC_TIMEOUTRET);
        timespec ts{0, long(CYCLE_NS)};
        nanosleep(&ts, nullptr);
    }
    ec_statecheck(0, EC_STATE_SAFE_OP, EC_TIMEOUTSTATE * 2);
    ec_readstate();
    std::printf("  stepped down to state 0x%02X before leaving\n",
                unsigned(ec_slave[sl].state));

    // Safe to use the mailbox now — the drive is out of OP, so stalling the
    // cyclic traffic cannot trip its watchdog.
    std::printf("\n--- what the drive reports ---\n");
    std::printf("  last statusword / position / target  = 0x%04X / %d / %d\n",
                lastSw, lastPos, lastTarget);
    std::printf("  modes of operation display 0x6010:03 = %ld   (8 = CSP, 9 = CSV, 10 = CST)\n",
                sdoR(sl, 0x6010, 0x03));
    std::printf("  following error 0x6010:06            = %ld\n", sdoR(sl, 0x6010, 0x06));
    // DC link and the drive's own diagnosis: bit 7 of the statusword has four
    // causes (I2T, STO voltage missing, >80 C, undervoltage) and the diag
    // history is the only thing that tells them apart. 0x10F3:02 points at the
    // newest record; each record is 28 bytes, TEXT ID at bytes 6-7.
    std::printf("  DC link voltage 0x9010:12            = %ld mV\n", sdoR(sl, 0x9010, 0x12));
    {
        long newest = sdoR(sl, 0x10F3, 0x02);
        std::printf("  diag history newest 0x10F3:02        = %ld\n", newest);
        for (long k = newest; k >= 6 && k > newest - 4; k--) {
            uint8_t rec[64] = {0}; int sz = int(sizeof rec);
            if (ec_SDOread(sl, 0x10F3, uint8_t(k), FALSE, &sz, rec, EC_TIMEOUTRXM) <= 0) break;
            uint32_t diag = 0; uint16_t flags = 0, text = 0;
            std::memcpy(&diag, rec, 4); std::memcpy(&flags, rec + 4, 2); std::memcpy(&text, rec + 6, 2);
            std::printf("    0x10F3:%02lX diag=0x%08X flags=0x%04X TEXT ID=0x%04X", k, diag, flags, text);
            switch (text) {
                case 0x8302: std::printf("  Encoder/Feedback error"); break;
                case 0x8146: std::printf("  Sync-Mode / PDO config incompatible"); break;
                case 0x841C: std::printf("  STO de-energised while enabled"); break;
                case 0x8105: std::printf("  PD watchdog"); break;
                case 0x8135: std::printf("  cycle time not multiple of 125 us"); break;
                case 0x4102: std::printf("  (info) PDO config discrepancy"); break;
                default: break;
            }
            std::printf("\n");
        }
    }

    // Go to INIT first, THEN release SYNC0. Calling ec_dcsync01(..., FALSE, 0,
    // 0, 0) while the slave is still configured writes a cycle time of 0, and
    // the drive rejects that with 0x8135 "Cycletime has to be a multiple of
    // 125 us" — a fault caused purely by how we shut DC down.
    ec_slave[0].state = EC_STATE_INIT;      // PDO assignment needs PRE-OP next run
    ec_writestate(0);
    ec_statecheck(0, EC_STATE_INIT, EC_TIMEOUTSTATE * 2);
    ec_close();

    if (teachRed) {
        const long long st = stAngle((long long)lastPos);
        FILE *f = std::fopen(RED_FILE, "w");
        if (f && CPR > 0.0) {
            std::fprintf(f, "%lld\n", st);
            std::fclose(f);
            std::printf("\nRED TAUGHT: single-turn angle %lld of %.0f (%.2f deg) -> %s\n",
                        st, CPR, double(st) / CPR * 360.0, RED_FILE);
        } else {
            if (f) std::fclose(f);
            std::printf("\nRED NOT SAVED: cannot write %s (or CPR unknown)\n", RED_FILE);
        }
    }
    if (tripped)
        std::printf("\nRUN ENDED BY ANGLE WINDOW TRIP - investigate before running again.\n");
    if (!enabled)
        std::printf("\nNEVER REACHED 'operation enabled' (statusword 0x0027).\n"
                    "Check, in this order:\n"
                    "  1. 24 V on STO input, terminal point 13 — the usual cause\n"
                    "  2. 48 V motor supply present (separate from E-bus power)\n"
                    "  3. the last statusword above, against the manual's fault table\n");
    return 0;
}
