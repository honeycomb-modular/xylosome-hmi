#pragma once
// CameraLink.h — Pi ⇄ capture PC (capture agent) client for the CAMERA bus.
//
// Newline-JSON over QTcpSocket, protocol in capture/PROTOCOL.md (port 5521).
// Registered as QML singleton "Camera". Auto-reconnects every 2 s, mirroring
// BeckhoffLink. Peer of the motion bus: the camera lives on the capture PC, so
// the HMI reaches it through the capture agent, never directly.
//
// Phase 1 = settings (line rate, TDI stages, gain, scan direction). State is
// pushed on connect and after every change; write with setParam().

#include <QObject>
#include <QTcpSocket>
#include <QTimer>
#include <QVariant>

class CameraLink : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool    connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString host      READ host      WRITE setHost NOTIFY hostChanged)
    Q_PROPERTY(int     port      READ port      WRITE setPort NOTIFY portChanged)

    // mirrored camera state (pushed on connect and after every successful set)
    Q_PROPERTY(double  lineRate  READ lineRate  NOTIFY stateChanged)   // Hz
    Q_PROPERTY(int     tdiStages READ tdiStages NOTIFY stateChanged)
    Q_PROPERTY(QString gain      READ gain      NOTIFY stateChanged)   // dB (tap 0)
    Q_PROPERTY(QString scanDir   READ scanDir   NOTIFY stateChanged)
    Q_PROPERTY(QString model     READ model     NOTIFY stateChanged)
    Q_PROPERTY(QString clm       READ clm       NOTIFY stateChanged)   // Camera Link mode

public:
    explicit CameraLink(QObject *parent = nullptr);

    bool    connected() const { return m_connected; }
    QString host()      const { return m_host; }
    int     port()      const { return m_port; }
    double  lineRate()  const { return m_lineRate; }
    int     tdiStages() const { return m_tdiStages; }
    QString gain()      const { return m_gain; }
    QString scanDir()   const { return m_scanDir; }
    QString model()     const { return m_model; }
    QString clm()       const { return m_clm; }

    void setHost(const QString &h);
    void setPort(int p);

    // ── commands ────────────────────────────────────────────────────────────
    Q_INVOKABLE void setParam(const QString &key, const QVariant &value);
    Q_INVOKABLE void refresh();          // ask the agent for current state

signals:
    void connectedChanged();
    void hostChanged();
    void portChanged();
    void stateChanged();

private slots:
    void onConnected();
    void onDisconnected();
    void onReadyRead();
    void tryConnect();

private:
    void sendJson(const QJsonObject &obj);
    void handleMessage(const QJsonObject &msg);

    QTcpSocket m_sock;
    QTimer     m_reconnect;
    QByteArray m_rx;

    QString m_host = QStringLiteral("192.168.10.1");   // capture PC; overridable via QSettings
    int     m_port = 5521;

    bool    m_connected = false;
    double  m_lineRate = 0.0;
    int     m_tdiStages = 0;
    QString m_gain, m_scanDir, m_model, m_clm;
};
