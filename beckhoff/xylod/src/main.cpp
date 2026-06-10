// main.cpp — xylod: Xylosome motion daemon for the Beckhoff C6920.
//
//   xylod [--config /etc/xylod.conf] [--iface eth1] [--port 5510] [--sim]
//
// Threads:
//   cyclic   — owned by the backend: EtherCAT exchange + Sequencer (1 kHz)
//   main     — TcpServer poll loop (commands in, events/status out)
#include "Config.h"
#include "EcBackend.h"
#include "SimBackend.h"
#include "Sequencer.h"
#include "TcpServer.h"
#include "Log.h"

#include <csignal>
#include <memory>

static volatile bool g_run = true;
static void onSignal(int) { g_run = false; }

int main(int argc, char **argv) {
    bool sim = false;
    const Config cfg = Config::fromArgs(argc, argv, sim);

    LOGI("xylod 0.1 — XYLOSOME motion daemon%s", sim ? " [SIM]" : "");

    std::unique_ptr<IBackend> backend;
    if (sim) backend = std::make_unique<SimBackend>(cfg);
    else     backend = std::make_unique<EcBackend>(cfg);

    Sequencer seq(cfg, *backend);

    if (!backend->start([&seq](double dt) { seq.cycle(dt); })) {
        LOGE("backend failed to start — exiting");
        return 1;
    }

    TcpServer server(cfg, seq, sim);
    if (!server.listen()) { backend->shutdown(); return 1; }

    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);

    server.run(g_run);

    LOGI("shutting down");
    backend->shutdown();
    return 0;
}
