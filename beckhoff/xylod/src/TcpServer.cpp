// TcpServer.cpp — poll loop + JSON glue (nlohmann::json).
#include "TcpServer.h"
#include "Log.h"

#include <nlohmann/json.hpp>
using json = nlohmann::json;

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstring>
#include <chrono>

bool TcpServer::listen() {
    m_listenFd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (m_listenFd < 0) { LOGE("tcp: socket: %s", strerror(errno)); return false; }
    int one = 1;
    setsockopt(m_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port = htons(uint16_t(m_cfg.tcpPort));
    if (bind(m_listenFd, reinterpret_cast<sockaddr *>(&a), sizeof a) < 0) {
        LOGE("tcp: bind :%d: %s", m_cfg.tcpPort, strerror(errno));
        return false;
    }
    if (::listen(m_listenFd, 4) < 0) { LOGE("tcp: listen: %s", strerror(errno)); return false; }
    LOGI("tcp: listening on :%d", m_cfg.tcpPort);
    return true;
}

void TcpServer::acceptClient() {
    sockaddr_in a{}; socklen_t al = sizeof a;
    const int fd = accept(m_listenFd, reinterpret_cast<sockaddr *>(&a), &al);
    if (fd < 0) return;
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    char ip[32]; inet_ntop(AF_INET, &a.sin_addr, ip, sizeof ip);
    m_clients.push_back({fd, "", ip});
    LOGI("tcp: client connected: %s (%zu total)", ip, m_clients.size());

    json w = {{"ev", "welcome"}, {"version", "0.1"}, {"sim", m_sim}};
    sendTo(m_clients.back(), w.dump());
}

void TcpServer::sendTo(Client &c, const std::string &j) {
    const std::string line = j + "\n";
    if (::send(c.fd, line.data(), line.size(), MSG_NOSIGNAL) < 0) c.fd = -1;  // reaped below
}

void TcpServer::broadcast(const std::string &j) {
    for (auto &c : m_clients) if (c.fd >= 0) sendTo(c, j);
}

std::string TcpServer::statusJson() {
    const SeqStatus s = m_seq.status();
    json j = {
        {"ev", "status"},
        {"state", s.state}, {"op", s.operational}, {"enabled", s.enabled},
        {"homed", s.homed}, {"pass", s.pass}, {"progress", s.progress},
        {"posDeg", s.posDeg}, {"velDegS", s.velDegS},
        {"filterSlot", s.filterSlot}, {"lineHz", s.lineHz},
        {"estopOk", s.estopOk},
        {"drive", {{"sw", s.driveSw}, {"fault", s.driveFault}}},
        {"echo", s.echo},
    };
    return j.dump();
}

void TcpServer::handleLine(Client &c, const std::string &line) {
    json req;
    try { req = json::parse(line); }
    catch (...) { sendTo(c, R"({"ack":"?","ok":false,"err":"bad json"})"); return; }

    const std::string cmd = req.value("cmd", "");
    json ack = {{"ack", cmd}, {"ok", true}};
    if (req.contains("id")) ack["id"] = req["id"];

    SeqCommand sc{};
    bool post = true;

    if (cmd == "hello")        { post = false; c.name = req.value("client", c.name); }
    else if (cmd == "status")  { post = false; sendTo(c, statusJson()); }
    else if (cmd == "enable")  sc.type = SeqCommand::Enable;
    else if (cmd == "disable") sc.type = SeqCommand::Disable;
    else if (cmd == "stop")    sc.type = SeqCommand::Stop;
    else if (cmd == "pause")   sc.type = SeqCommand::Pause;
    else if (cmd == "resume")  sc.type = SeqCommand::Resume;
    else if (cmd == "fault_reset") sc.type = SeqCommand::FaultReset;
    else if (cmd == "home")    { sc.type = SeqCommand::Home; sc.a = req.value("velDegS", 0.0); }
    else if (cmd == "jog")     { sc.type = SeqCommand::Jog;  sc.a = req.value("velDegS", 0.0); }
    else if (cmd == "moveTo")  { sc.type = SeqCommand::MoveTo;
                                 sc.a = req.value("posDeg", 0.0);
                                 sc.b = req.value("velDegS", 20.0); }
    else if (cmd == "filter")  { sc.type = SeqCommand::Filter; sc.slot = req.value("slot", 3); }
    else if (cmd == "execute") {
        sc.type = SeqCommand::Execute;
        ScanJob &j = sc.job;
        j.colorMode     = req.value("colorMode", 0);
        j.arcStartDeg   = req.value("arcStartDeg", 0.0);
        j.arcEndDeg     = req.value("arcEndDeg", 90.0);
        j.maxVelDegS    = req.value("maxVelDegS", 100.0);
        j.minVelDegS    = req.value("minVelDegS", 1.0);
        j.settleMs      = req.value("settleMs", 300.0);
        j.returnVelDegS = req.value("returnVelDegS", 40.0);
        if (req.contains("line")) {
            j.lineCurve  = req["line"].value("mode", "curve") == std::string("curve");
            j.lineBaseHz = req["line"].value("baseHz", 5000.0);
        }
        if (req.contains("profile") && req["profile"].is_array())
            j.profile = req["profile"].get<std::vector<double>>();
        if (j.profile.size() < 2) { ack["ok"] = false; ack["err"] = "profile missing"; post = false; }
        if (std::fabs(j.arcEndDeg - j.arcStartDeg) < 0.5) {
            ack["ok"] = false; ack["err"] = "arc too small"; post = false;
        }
    }
    else { post = false; ack["ok"] = false; ack["err"] = "unknown cmd"; }

    if (post) m_seq.post(sc);
    sendTo(c, ack.dump());
}

void TcpServer::run(volatile bool &keepRunning) {
    using clock = std::chrono::steady_clock;
    auto lastStatus = clock::now();

    while (keepRunning) {
        std::vector<pollfd> fds;
        fds.push_back({m_listenFd, POLLIN, 0});
        for (auto &c : m_clients) fds.push_back({c.fd, POLLIN, 0});

        poll(fds.data(), nfds_t(fds.size()), 25);

        if (fds[0].revents & POLLIN) acceptClient();

        for (size_t i = 0; i < m_clients.size(); i++) {
            if (!(fds[i + 1].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            char buf[4096];
            const ssize_t n = recv(m_clients[i].fd, buf, sizeof buf, 0);
            if (n <= 0) { close(m_clients[i].fd); m_clients[i].fd = -1; continue; }
            m_clients[i].rx.append(buf, size_t(n));
            size_t nl;
            while ((nl = m_clients[i].rx.find('\n')) != std::string::npos) {
                std::string line = m_clients[i].rx.substr(0, nl);
                m_clients[i].rx.erase(0, nl + 1);
                if (!line.empty() && line.back() == '\r') line.pop_back();
                if (!line.empty()) handleLine(m_clients[i], line);
            }
            if (m_clients[i].rx.size() > 1 << 20) m_clients[i].rx.clear();   // runaway guard
        }

        // reap dead clients
        for (auto it = m_clients.begin(); it != m_clients.end();) {
            if (it->fd < 0) { LOGI("tcp: client gone: %s", it->name.c_str());
                              it = m_clients.erase(it); }
            else ++it;
        }

        // events: push immediately
        for (const auto &e : m_seq.drainEvents()) broadcast(e);

        // status @ 25 Hz — playhead smoothness on the HMI side
        if (!m_clients.empty() && clock::now() - lastStatus > std::chrono::milliseconds(40)) {
            broadcast(statusJson());
            lastStatus = clock::now();
        }
    }

    for (auto &c : m_clients) if (c.fd >= 0) close(c.fd);
    if (m_listenFd >= 0) close(m_listenFd);
}
