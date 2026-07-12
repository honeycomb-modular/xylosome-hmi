// CameraLink.cpp — see CameraLink.h. Protocol: capture/PROTOCOL.md.
#include "CameraLink.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QDebug>

CameraLink::CameraLink(QObject *parent)
    : QObject(parent)
{
    QSettings s;
    m_host = s.value(QStringLiteral("camera/host"), m_host).toString();
    m_port = s.value(QStringLiteral("camera/port"), m_port).toInt();
    if (qEnvironmentVariableIsSet("CAMERA_HOST"))
        m_host = qEnvironmentVariable("CAMERA_HOST");

    connect(&m_sock, &QTcpSocket::connected,     this, &CameraLink::onConnected);
    connect(&m_sock, &QTcpSocket::disconnected,  this, &CameraLink::onDisconnected);
    connect(&m_sock, &QTcpSocket::readyRead,     this, &CameraLink::onReadyRead);
    connect(&m_sock, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        m_sock.abort();
        if (!m_reconnect.isActive()) m_reconnect.start();
    });

    m_reconnect.setInterval(2000);
    m_reconnect.setSingleShot(true);
    connect(&m_reconnect, &QTimer::timeout, this, &CameraLink::tryConnect);

    tryConnect();
}

void CameraLink::tryConnect() {
    if (m_sock.state() != QAbstractSocket::UnconnectedState) return;
    m_sock.connectToHost(m_host, quint16(m_port));
}

void CameraLink::setHost(const QString &h) {
    if (m_host == h) return;
    m_host = h;
    QSettings().setValue(QStringLiteral("camera/host"), h);
    emit hostChanged();
    m_sock.abort();
    tryConnect();
}

void CameraLink::setPort(int p) {
    if (m_port == p) return;
    m_port = p;
    QSettings().setValue(QStringLiteral("camera/port"), p);
    emit portChanged();
    m_sock.abort();
    tryConnect();
}

void CameraLink::onConnected() {
    m_connected = true;
    emit connectedChanged();
    qInfo() << "[camera] connected to" << m_host << ":" << m_port;
    sendJson({{QStringLiteral("cmd"), QStringLiteral("hello")},
              {QStringLiteral("client"), QStringLiteral("suite")}});
    sendJson({{QStringLiteral("cmd"), QStringLiteral("get")}});
}

void CameraLink::onDisconnected() {
    m_connected = false;
    emit connectedChanged();
    emit stateChanged();
    qWarning() << "[camera] disconnected — retrying";
    m_reconnect.start();
}

void CameraLink::sendJson(const QJsonObject &obj) {
    if (m_sock.state() != QAbstractSocket::ConnectedState) return;
    m_sock.write(QJsonDocument(obj).toJson(QJsonDocument::Compact) + '\n');
}

void CameraLink::onReadyRead() {
    m_rx += m_sock.readAll();
    int nl;
    while ((nl = m_rx.indexOf('\n')) >= 0) {
        const QByteArray line = m_rx.left(nl);
        m_rx.remove(0, nl + 1);
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (doc.isObject()) handleMessage(doc.object());
    }
}

void CameraLink::handleMessage(const QJsonObject &m) {
    if (m.contains(QStringLiteral("ack")))
        return;   // the suite issues no sets; nothing to reconcile

    const QString ev = m.value(QStringLiteral("ev")).toString();

    if (ev == QLatin1String("state")) {
        m_lineRate  = m.value(QStringLiteral("line.rate")).toDouble();
        m_tdiStages = m.value(QStringLiteral("tdi.stages")).toInt();
        m_gain      = m.value(QStringLiteral("gain")).toString();
        m_scanDir   = m.value(QStringLiteral("scan.dir")).toString();
        m_model     = m.value(QStringLiteral("model")).toString();
        m_clm       = m.value(QStringLiteral("clm")).toString();
        emit stateChanged();
    }
    else if (ev == QLatin1String("welcome")) {
        m_model = m.value(QStringLiteral("camera")).toString();
        qInfo() << "[camera] agent" << m.value(QStringLiteral("version")).toString() << m_model;
        emit stateChanged();
    }
}

void CameraLink::refresh() {
    sendJson({{QStringLiteral("cmd"), QStringLiteral("get")}});
}
