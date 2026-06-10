#include "SimBackend.h"
#include "Log.h"
#include <chrono>

bool SimBackend::start(CycleFn cycle) {
    m_running = true;
    m_thread = std::thread([this, cycle] { loop(cycle); });
    LOGI("sim: backend started (no hardware)");
    return true;
}

void SimBackend::shutdown() {
    if (!m_running) return;
    m_running = false;
    if (m_thread.joinable()) m_thread.join();
}

void SimBackend::loop(CycleFn cycle) {
    using clock = std::chrono::steady_clock;
    const auto period = std::chrono::microseconds(m_cfg.cycleUs);
    auto next = clock::now();
    const double dt = m_cfg.cycleUs * 1e-6;

    while (m_running) {
        // axis: track target when enabled — fast 1st-order lag, vel derived
        if (m_enabled) {
            const double prev = m_pos;
            m_pos += (m_target - m_pos) * std::min(1.0, dt * 50.0);
            m_vel  = (m_pos - prev) / dt;
        } else {
            m_vel *= 0.95;
        }
        if (m_fwTimer > 0.0) m_fwTimer -= dt;

        cycle(dt);

        next += period;
        std::this_thread::sleep_until(next);
    }
}
