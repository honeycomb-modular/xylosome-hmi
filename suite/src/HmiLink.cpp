// HmiLink.cpp — see HmiLink.h.
#include "HmiLink.h"
#include <QSettings>
#include <QDebug>

HmiLink::HmiLink(QObject *parent)
    : QObject(parent)
{
    QSettings s;
    m_host = s.value(QStringLiteral("hmi/host"), m_host).toString();
    if (qEnvironmentVariableIsSet("HMI_HOST"))
        m_host = qEnvironmentVariable("HMI_HOST");

    // Reaching ConnectedState is the whole signal — we drop the probe at once
    // so the HMI's HTTP server never waits on a request that isn't coming.
    connect(&m_sock, &QTcpSocket::connected, this, &HmiLink::onProbeConnected);

    m_timer.setInterval(2000);
    connect(&m_timer, &QTimer::timeout, this, &HmiLink::poll);
    m_timer.start();
    poll();
}

void HmiLink::setHost(const QString &h) {
    if (m_host == h) return;
    m_host = h;
    QSettings().setValue(QStringLiteral("hmi/host"), h);
    emit hostChanged();
    m_attemptOk = false;
    poll();
}

void HmiLink::poll() {
    // Conclude the previous 2 s cycle, then start a fresh probe. The interval
    // doubles as the connect timeout: no ConnectedState by now → offline.
    setConnected(m_attemptOk);
    m_attemptOk = false;
    m_sock.abort();
    m_sock.connectToHost(m_host, quint16(m_port));
}

void HmiLink::onProbeConnected() {
    m_attemptOk = true;
    m_sock.abort();   // reachability confirmed; don't hold the socket open
}

void HmiLink::setConnected(bool c) {
    if (m_connected == c) return;
    m_connected = c;
    emit connectedChanged();
    qInfo() << "[hmi]" << (c ? "reachable at" : "unreachable —") << m_host;
}
