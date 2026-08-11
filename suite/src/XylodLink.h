#pragma once
// XylodLink.h — Suite ⇄ Beckhoff C6920 (xylod) client. Observer only.
//
// Port of pi/hmi/src/BeckhoffLink (protocol: beckhoff/PROTOCOL.md), with the
// command surface removed: the suite listens — status at 10 Hz, sequence
// events — and never commands motion. The pendant owns the machine.
//
// Clock discipline (plan → Foundations #4): xylod tMs is a monotonic daemon
// clock; capture-PC files carry wall-clock mtimes. Each pass_start/pass_end
// is therefore stamped here with the suite's wall clock on arrival (wallMs)
// — the bridge that phase 2 file⇄pass pairing builds on.
//
// Registered as QML singleton "Xylod". Auto-reconnects every 2 s.

#include <QObject>
#include <QTcpSocket>
#include <QTimer>

class XylodLink : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool    connected   READ connected   NOTIFY connectedChanged)
    Q_PROPERTY(QString host        READ host        WRITE setHost NOTIFY hostChanged)
    Q_PROPERTY(int     port        READ port        WRITE setPort NOTIFY portChanged)

    // mirrored daemon status (10 Hz pushes)
    Q_PROPERTY(QString state       READ state       NOTIFY statusChanged)   // idle|running|…
    Q_PROPERTY(bool    running     READ running     NOTIFY statusChanged)
    Q_PROPERTY(bool    estopOk     READ estopOk     NOTIFY statusChanged)
    Q_PROPERTY(int     passIndex   READ passIndex   NOTIFY passIndexChanged)
    Q_PROPERTY(QString filterName  READ filterName  NOTIFY passIndexChanged) // R|G|B|C|""
    Q_PROPERTY(double  progress    READ progress    NOTIFY progressChanged)  // 0..1 in pass
    Q_PROPERTY(double  positionDeg READ positionDeg NOTIFY statusChanged)
    Q_PROPERTY(double  velocityDegS READ velocityDegS NOTIFY statusChanged)
    Q_PROPERTY(double  lineHz      READ lineHz      NOTIFY statusChanged)
    Q_PROPERTY(QString faultText   READ faultText   NOTIFY faultTextChanged)
    Q_PROPERTY(bool    sim         READ sim         NOTIFY connectedChanged)

public:
    explicit XylodLink(QObject *parent = nullptr);

    bool    connected()    const { return m_connected; }
    QString host()         const { return m_host; }
    int     port()         const { return m_port; }
    QString state()        const { return m_state; }
    bool    running()      const { return m_state == QLatin1String("running")
                                       || m_state == QLatin1String("paused")
                                       || m_state == QLatin1String("settle")
                                       || m_state == QLatin1String("filter"); }
    bool    estopOk()      const { return m_estopOk; }
    int     passIndex()    const { return m_pass; }
    QString filterName()   const { return m_filterName; }
    double  progress()     const { return m_progress; }
    double  positionDeg()  const { return m_posDeg; }
    double  velocityDegS() const { return m_velDegS; }
    double  lineHz()       const { return m_lineHz; }
    QString faultText()    const { return m_faultText; }
    bool    sim()          const { return m_sim; }

    void setHost(const QString &h);
    void setPort(int p);

signals:
    void connectedChanged();
    void hostChanged();
    void portChanged();
    void statusChanged();
    void passIndexChanged();
    void progressChanged();
    void faultTextChanged();

    // sequence events — tMs = daemon monotonic clock, wallMs = suite wall
    // clock at arrival (file⇄pass pairing anchor, phase 2)
    // tag: opaque label the daemon echoes back from the job (empty for most
    // scans). HDR uses it to say "these separate scans are one bracket set".
    void passStarted(int pass, const QString &filter, qint64 tMs, qint64 wallMs,
                     const QString &tag);
    void passEnded(int pass, qint64 tMs, qint64 wallMs);
    void sequenceDone(int passes);
    void faulted(const QString &text);

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

    QString m_host = QStringLiteral("192.168.10.20");
    int     m_port = 5510;

    bool    m_connected = false;
    bool    m_sim = false;
    QString m_state = QStringLiteral("offline");
    bool    m_estopOk = true;
    int     m_pass = -1;
    QString m_filterName;
    double  m_progress = 0.0, m_posDeg = 0.0, m_velDegS = 0.0, m_lineHz = 0.0;
    QString m_faultText;
};
