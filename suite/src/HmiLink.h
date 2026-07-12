#pragma once
// HmiLink.h — reachability heartbeat for the Pi HMI.
//
// The suite doesn't talk to the HMI directly (they're peers on the xylod and
// camera buses), but the HMI runs an HTTP server on :8080 (pi/hmi/HttpServer).
// So "HMI connected" = can we open a TCP connection to that port. Every 2 s we
// make one probe connection and report whether it succeeded; no data is sent.
// Registered as QML singleton "Hmi". Override the address with HMI_HOST.

#include <QObject>
#include <QTcpSocket>
#include <QTimer>

class HmiLink : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool    connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString host      READ host      WRITE setHost NOTIFY hostChanged)

public:
    explicit HmiLink(QObject *parent = nullptr);

    bool    connected() const { return m_connected; }
    QString host()      const { return m_host; }
    void    setHost(const QString &h);

signals:
    void connectedChanged();
    void hostChanged();

private slots:
    void poll();
    void onProbeConnected();

private:
    void setConnected(bool c);

    QTcpSocket m_sock;
    QTimer     m_timer;

    QString m_host = QStringLiteral("192.168.10.3");   // last-working HMI; HMI_HOST overrides
    int     m_port = 8080;
    bool    m_connected = false;
    bool    m_attemptOk = false;   // did the in-flight probe reach ConnectedState?
};
