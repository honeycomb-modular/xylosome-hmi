#pragma once
// TcpServer.h — newline-JSON command server (see ../PROTOCOL.md).
// poll()-based, single thread (the main thread). Translates JSON ⇄ SeqCommand,
// broadcasts sequencer events immediately and status at 10 Hz.
#include "Sequencer.h"
#include <string>
#include <vector>

class TcpServer {
public:
    TcpServer(const Config &cfg, Sequencer &seq, bool sim)
        : m_cfg(cfg), m_seq(seq), m_sim(sim) {}

    bool listen();
    void run(volatile bool &keepRunning);   // blocks; poll loop

private:
    struct Client { int fd; std::string rx; std::string name; };

    void acceptClient();
    void handleLine(Client &c, const std::string &line);
    void sendTo(Client &c, const std::string &json);
    void broadcast(const std::string &json);
    std::string statusJson();

    const Config &m_cfg;
    Sequencer &m_seq;
    bool m_sim;
    int m_listenFd = -1;
    std::vector<Client> m_clients;
};
