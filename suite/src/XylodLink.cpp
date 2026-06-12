// XylodLink.cpp — see XylodLink.h. Protocol: beckhoff/PROTOCOL.md.
#include "XylodLink.h"
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QDebug>

XylodLink::XylodLink(QObject *parent)
    : QObject(parent)
{
    QSettings s;
    m_host = s.value(QStringLiteral("xylod/host"), m_host).toString();
    m_port = s.value(QStringLiteral("xylod/port"), m_port).toInt();

    // Dev override (no settings UI yet): XYLOD_HOST / XYLOD_PORT
    if (qEnvironmentVariableIsSet("XYLOD_HOST"))
        m_host = qEnvironmentVariable("XYLOD_HOST");
    if (qEnvironmentVariableIsSet("XYLOD_PORT"))
        m_port = qEnvironmentVariable("XYLOD_PORT").toInt();

    connect(&m_sock, &QTcpSocket::connected,    this, &XylodLink::onConnected);
    connect(&m_sock, &QTcpSocket::disconnected, this, &XylodLink::onDisconnected);
    connect(&m_sock, &QTcpSocket::readyRead,    this, &XylodLink::onReadyRead);
    connect(&m_sock, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        m_sock.abort();
        if (!m_reconnect.isActive()) m_reconnect.start();
    });

    m_reconnect.setInterval(2000);
    m_reconnect.setSingleShot(true);
    connect(&m_reconnect, &QTimer::timeout, this, &XylodLink::tryConnect);

    tryConnect();
}

void XylodLink::tryConnect() {
    if (m_sock.state() != QAbstractSocket::UnconnectedState) return;
    m_sock.connectToHost(m_host, quint16(m_port));
}

void XylodLink::setHost(const QString &h) {
    if (m_host == h) return;
    m_host = h;
    QSettings().setValue(QStringLiteral("xylod/host"), h);
    emit hostChanged();
    m_sock.abort();
    tryConnect();
}

void XylodLink::setPort(int p) {
    if (m_port == p) return;
    m_port = p;
    QSettings().setValue(QStringLiteral("xylod/port"), p);
    emit portChanged();
    m_sock.abort();
    tryConnect();
}

void XylodLink::onConnected() {
    m_connected = true;
    emit connectedChanged();
    qInfo() << "[xylod] connected to" << m_host << ":" << m_port;
    sendJson({{QStringLiteral("cmd"), QStringLiteral("hello")},
              {QStringLiteral("client"), QStringLiteral("suite")}});
    sendJson({{QStringLiteral("cmd"), QStringLiteral("status")}});
}

void XylodLink::onDisconnected() {
    m_connected = false;
    m_state = QStringLiteral("offline");
    emit connectedChanged();
    emit statusChanged();
    qWarning() << "[xylod] disconnected — retrying";
    m_reconnect.start();
}

void XylodLink::sendJson(const QJsonObject &obj) {
    if (m_sock.state() != QAbstractSocket::ConnectedState) return;
    m_sock.write(QJsonDocument(obj).toJson(QJsonDocument::Compact) + '\n');
}

void XylodLink::onReadyRead() {
    m_rx += m_sock.readAll();
    int nl;
    while ((nl = m_rx.indexOf('\n')) >= 0) {
        const QByteArray line = m_rx.left(nl);
        m_rx.remove(0, nl + 1);
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (doc.isObject()) handleMessage(doc.object());
    }
}

void XylodLink::handleMessage(const QJsonObject &m) {
    if (m.contains(QStringLiteral("ack")))
        return;   // observer sends only hello/status; nothing to track

    const QString ev = m.value(QStringLiteral("ev")).toString();
    const qint64 wallMs = QDateTime::currentMSecsSinceEpoch();

    static const char *kFilters[] = { "R", "G", "B", "C" };

    if (ev == QLatin1String("status")) {
        const int    pass = m.value(QStringLiteral("pass")).toInt(-1);
        const double prog = m.value(QStringLiteral("progress")).toDouble();
        m_state   = m.value(QStringLiteral("state")).toString();
        m_estopOk = m.value(QStringLiteral("estopOk")).toBool(true);
        m_posDeg  = m.value(QStringLiteral("posDeg")).toDouble();
        m_velDegS = m.value(QStringLiteral("velDegS")).toDouble();
        m_lineHz  = m.value(QStringLiteral("lineHz")).toDouble();
        if (!m_faultText.isEmpty()
            && m_state != QLatin1String("fault")
            && m_state != QLatin1String("estop")) {
            m_faultText.clear();      // fault recovered on the pendant
            emit faultTextChanged();
        }
        emit statusChanged();
        if (pass != m_pass) {
            m_pass = pass;
            m_filterName = (pass >= 0 && pass < 4) ? QLatin1String(kFilters[pass])
                                                   : QString();
            emit passIndexChanged();
        }
        if (prog != m_progress) { m_progress = prog; emit progressChanged(); }
    }
    else if (ev == QLatin1String("pass_start")) {
        const int p = m.value(QStringLiteral("pass")).toInt();
        const QString f = m.value(QStringLiteral("filter")).toString();
        if (p != m_pass || f != m_filterName) {
            m_pass = p;
            m_filterName = f;
            emit passIndexChanged();
        }
        emit passStarted(p, f, qint64(m.value(QStringLiteral("tMs")).toDouble()), wallMs);
    }
    else if (ev == QLatin1String("pass_end")) {
        emit passEnded(m.value(QStringLiteral("pass")).toInt(),
                       qint64(m.value(QStringLiteral("tMs")).toDouble()), wallMs);
    }
    else if (ev == QLatin1String("seq_done")) {
        m_pass = -1;
        m_filterName.clear();
        emit passIndexChanged();
        emit sequenceDone(m.value(QStringLiteral("passes")).toInt());
    }
    else if (ev == QLatin1String("fault")) {
        m_faultText = m.value(QStringLiteral("text")).toString();
        emit faultTextChanged();
        emit faulted(m_faultText);
        qWarning() << "[xylod] FAULT:" << m_faultText;
    }
    else if (ev == QLatin1String("welcome")) {
        m_sim = m.value(QStringLiteral("sim")).toBool();
        emit connectedChanged();
        qInfo() << "[xylod] daemon" << m.value(QStringLiteral("version")).toString()
                << (m_sim ? "[SIM]" : "");
    }
}
