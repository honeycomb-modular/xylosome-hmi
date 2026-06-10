// BeckhoffLink.cpp — see BeckhoffLink.h. Protocol: beckhoff/PROTOCOL.md.
#include "BeckhoffLink.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QSettings>
#include <QDebug>

BeckhoffLink::BeckhoffLink(QObject *parent)
    : QObject(parent)
{
    QSettings s;
    m_host = s.value(QStringLiteral("beckhoff/host"), m_host).toString();
    m_port = s.value(QStringLiteral("beckhoff/port"), m_port).toInt();

    connect(&m_sock, &QTcpSocket::connected,    this, &BeckhoffLink::onConnected);
    connect(&m_sock, &QTcpSocket::disconnected, this, &BeckhoffLink::onDisconnected);
    connect(&m_sock, &QTcpSocket::readyRead,    this, &BeckhoffLink::onReadyRead);
    connect(&m_sock, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        m_sock.abort();
        if (!m_reconnect.isActive()) m_reconnect.start();
    });

    m_reconnect.setInterval(2000);
    m_reconnect.setSingleShot(true);
    connect(&m_reconnect, &QTimer::timeout, this, &BeckhoffLink::tryConnect);

    tryConnect();
}

void BeckhoffLink::tryConnect() {
    if (m_sock.state() != QAbstractSocket::UnconnectedState) return;
    m_sock.connectToHost(m_host, quint16(m_port));
}

void BeckhoffLink::setHost(const QString &h) {
    if (m_host == h) return;
    m_host = h;
    QSettings().setValue(QStringLiteral("beckhoff/host"), h);
    emit hostChanged();
    m_sock.abort();
    tryConnect();
}

void BeckhoffLink::setPort(int p) {
    if (m_port == p) return;
    m_port = p;
    QSettings().setValue(QStringLiteral("beckhoff/port"), p);
    emit portChanged();
    m_sock.abort();
    tryConnect();
}

void BeckhoffLink::onConnected() {
    m_connected = true;
    emit connectedChanged();
    qInfo() << "[beckhoff] connected to" << m_host << ":" << m_port;
    sendJson({{QStringLiteral("cmd"), QStringLiteral("hello")},
              {QStringLiteral("client"), QStringLiteral("hmi")}});
    sendJson({{QStringLiteral("cmd"), QStringLiteral("status")}});
}

void BeckhoffLink::onDisconnected() {
    m_connected = false;
    m_state = QStringLiteral("offline");
    emit connectedChanged();
    emit statusChanged();
    qWarning() << "[beckhoff] disconnected — retrying";
    m_reconnect.start();
}

void BeckhoffLink::sendJson(const QJsonObject &obj) {
    if (m_sock.state() != QAbstractSocket::ConnectedState) return;
    m_sock.write(QJsonDocument(obj).toJson(QJsonDocument::Compact) + '\n');
}

void BeckhoffLink::onReadyRead() {
    m_rx += m_sock.readAll();
    int nl;
    while ((nl = m_rx.indexOf('\n')) >= 0) {
        const QByteArray line = m_rx.left(nl);
        m_rx.remove(0, nl + 1);
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (doc.isObject()) handleMessage(doc.object());
    }
}

void BeckhoffLink::handleMessage(const QJsonObject &m) {
    if (m.contains(QStringLiteral("ack"))) {
        if (!m.value(QStringLiteral("ok")).toBool(true))
            qWarning() << "[beckhoff] nack:" << m.value(QStringLiteral("ack")).toString()
                       << m.value(QStringLiteral("err")).toString();
        return;
    }

    const QString ev = m.value(QStringLiteral("ev")).toString();

    if (ev == QLatin1String("status")) {
        const int    pass = m.value(QStringLiteral("pass")).toInt(-1);
        const double prog = m.value(QStringLiteral("progress")).toDouble();
        m_state      = m.value(QStringLiteral("state")).toString();
        m_enabled    = m.value(QStringLiteral("enabled")).toBool();
        m_homed      = m.value(QStringLiteral("homed")).toBool();
        m_estopOk    = m.value(QStringLiteral("estopOk")).toBool(true);
        m_posDeg     = m.value(QStringLiteral("posDeg")).toDouble();
        m_velDegS    = m.value(QStringLiteral("velDegS")).toDouble();
        m_lineHz     = m.value(QStringLiteral("lineHz")).toDouble();
        m_filterSlot = m.value(QStringLiteral("filterSlot")).toInt(-1);
        emit statusChanged();
        if (pass != m_pass)     { m_pass = pass;     emit passIndexChanged(); }
        if (prog != m_progress) { m_progress = prog; emit progressChanged(); }
    }
    else if (ev == QLatin1String("pass_start")) {
        const int p = m.value(QStringLiteral("pass")).toInt();
        if (p != m_pass) { m_pass = p; emit passIndexChanged(); }
        emit passStarted(p, qint64(m.value(QStringLiteral("tMs")).toDouble()));
    }
    else if (ev == QLatin1String("pass_end")) {
        emit passEnded(m.value(QStringLiteral("pass")).toInt(),
                       qint64(m.value(QStringLiteral("tMs")).toDouble()));
    }
    else if (ev == QLatin1String("seq_done")) {
        emit sequenceDone(m.value(QStringLiteral("passes")).toInt());
    }
    else if (ev == QLatin1String("homed")) {
        m_homed = true;
        emit statusChanged();
        emit homedEvent();
    }
    else if (ev == QLatin1String("fault")) {
        m_faultText = m.value(QStringLiteral("text")).toString();
        emit faultTextChanged();
        emit faulted(m_faultText);
        qWarning() << "[beckhoff] FAULT:" << m_faultText;
    }
    else if (ev == QLatin1String("welcome")) {
        qInfo() << "[beckhoff] xylod" << m.value(QStringLiteral("version")).toString()
                << (m.value(QStringLiteral("sim")).toBool() ? "[SIM]" : "");
    }
}

// ── commands ──────────────────────────────────────────────────────────────────

void BeckhoffLink::executeScan(int colorMode,
                               double arcStartDeg, double arcEndDeg,
                               double maxVelDegS, double minVelDegS,
                               const QVariantList &profile)
{
    QJsonArray prof;
    for (const QVariant &v : profile) prof.append(v.toDouble());

    QSettings s;
    QJsonObject line{
        {QStringLiteral("mode"),   s.value(QStringLiteral("beckhoff/lineMode"),
                                           QStringLiteral("curve")).toString()},
        {QStringLiteral("baseHz"), s.value(QStringLiteral("beckhoff/lineBaseHz"), 5000.0).toDouble()},
    };

    sendJson({
        {QStringLiteral("cmd"),          QStringLiteral("execute")},
        {QStringLiteral("colorMode"),    colorMode},
        {QStringLiteral("arcStartDeg"),  arcStartDeg},
        {QStringLiteral("arcEndDeg"),    arcEndDeg},
        {QStringLiteral("maxVelDegS"),   maxVelDegS},
        {QStringLiteral("minVelDegS"),   minVelDegS},
        // Defaults tightened 2026-06-10 (artist: inter-pass pause too long).
        // Both overridable via QSettings; revisit on real hardware.
        {QStringLiteral("settleMs"),     s.value(QStringLiteral("beckhoff/settleMs"), 150.0).toDouble()},
        {QStringLiteral("returnVelDegS"),s.value(QStringLiteral("beckhoff/returnVelDegS"), 80.0).toDouble()},
        {QStringLiteral("line"),         line},
        {QStringLiteral("profile"),      prof},
    });
}

void BeckhoffLink::pause()  { sendJson({{QStringLiteral("cmd"), QStringLiteral("pause")}}); }
void BeckhoffLink::resume() { sendJson({{QStringLiteral("cmd"), QStringLiteral("resume")}}); }
void BeckhoffLink::stop()   { sendJson({{QStringLiteral("cmd"), QStringLiteral("stop")}}); }
void BeckhoffLink::home()   { sendJson({{QStringLiteral("cmd"), QStringLiteral("home")}}); }
void BeckhoffLink::faultReset() { sendJson({{QStringLiteral("cmd"), QStringLiteral("fault_reset")}}); }

void BeckhoffLink::enable(bool on) {
    sendJson({{QStringLiteral("cmd"), on ? QStringLiteral("enable")
                                         : QStringLiteral("disable")}});
}
void BeckhoffLink::jog(double velDegS) {
    sendJson({{QStringLiteral("cmd"), QStringLiteral("jog")},
              {QStringLiteral("velDegS"), velDegS}});
}
void BeckhoffLink::setFilter(int slot) {
    sendJson({{QStringLiteral("cmd"), QStringLiteral("filter")},
              {QStringLiteral("slot"), slot}});
}
