// Config.cpp — key=value parser. '#' comments, whitespace tolerant.
#include "Config.h"
#include "Log.h"
#include <fstream>
#include <sstream>
#include <cstring>

static std::string trim(const std::string &s) {
    const auto a = s.find_first_not_of(" \t\r");
    const auto b = s.find_last_not_of(" \t\r");
    return (a == std::string::npos) ? "" : s.substr(a, b - a + 1);
}

bool Config::load(const std::string &path) {
    std::ifstream f(path);
    if (!f) { LOGW("config: %s not found — using defaults", path.c_str()); return false; }

    std::map<std::string, std::string> kv;
    std::string line;
    while (std::getline(f, line)) {
        const auto hash = line.find('#');
        if (hash != std::string::npos) line.erase(hash);
        const auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        kv[trim(line.substr(0, eq))] = trim(line.substr(eq + 1));
    }

    auto s = [&](const char *k, std::string &v) { if (kv.count(k)) v = kv[k]; };
    auto i = [&](const char *k, int &v)         { if (kv.count(k)) v = std::stoi(kv[k]); };
    auto d = [&](const char *k, double &v)      { if (kv.count(k)) v = std::stod(kv[k]); };
    auto b = [&](const char *k, bool &v)        { if (kv.count(k)) v = (kv[k] == "1" || kv[k] == "true" || kv[k] == "yes"); };

    i("tcp_port", tcpPort);            s("ec_iface", ecIface);
    i("pos_drive", posDrive);          i("pos_ek1100", posEk1100);
    i("pos_el7031", posEl7031);        i("pos_el2521", posEl2521);
    i("pos_el5152", posEl5152);        i("pos_el_dout", posElDout);
    i("pos_el_din", posElDin);
    d("motor_counts_per_rev", motorCountsPerRev);
    d("gear_ratio", gearRatio);        b("invert_axis", invertAxis);
    d("acc_limit_degs2", accLimitDegS2);
    d("home_deg", homeDeg);            d("home_vel_degs", homeVelDegS);
    d("soft_min_deg", softMinDeg);     d("soft_max_deg", softMaxDeg);
    d("fw_steps_per_rev", fwStepsPerRev);
    d("fw_vel_steps_s", fwVelStepsS);  d("fw_acc_steps_s2", fwAccStepsS2);
    d("fw_slot_r", fwSlotOffset[0]);   d("fw_slot_g", fwSlotOffset[1]);
    d("fw_slot_b", fwSlotOffset[2]);   d("fw_slot_c", fwSlotOffset[3]);
    d("el2521_base_hz", el2521BaseHz); d("line_max_hz", lineMaxHz);
    i("di_home", diHome);              i("di_end_min", diEndMin);
    i("di_end_max", diEndMax);         i("di_estop", diEstop);
    i("di_fw_index", diFwIndex);
    i("do_pass_active", doPassActive); i("do_pass_index", doPassIndex);
    b("estop_active_low", estopActiveLow);
    i("cycle_us", cycleUs);            i("rt_prio", rtPrio);

    LOGI("config: loaded %s (iface=%s port=%d)", path.c_str(), ecIface.c_str(), tcpPort);
    return true;
}

Config Config::fromArgs(int argc, char **argv, bool &sim) {
    Config cfg;
    std::string path = "/etc/xylod.conf";
    sim = false;
    for (int a = 1; a < argc; a++) {
        if (!std::strcmp(argv[a], "--sim")) sim = true;
        else if (!std::strcmp(argv[a], "--config") && a + 1 < argc) path = argv[++a];
        else if (!std::strcmp(argv[a], "--iface")  && a + 1 < argc) cfg.ecIface = argv[++a];
        else if (!std::strcmp(argv[a], "--port")   && a + 1 < argc) cfg.tcpPort = std::stoi(argv[++a]);
    }
    cfg.load(path);
    // command-line wins over file
    for (int a = 1; a < argc; a++) {
        if (!std::strcmp(argv[a], "--iface") && a + 1 < argc) cfg.ecIface = argv[++a];
        else if (!std::strcmp(argv[a], "--port") && a + 1 < argc) cfg.tcpPort = std::stoi(argv[++a]);
    }
    return cfg;
}
