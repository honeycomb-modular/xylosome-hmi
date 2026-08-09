#pragma once
// BeckhoffLink.h — Pi ⇄ Beckhoff C6920 (xylod) client.
//
// Newline-JSON over QTcpSocket, protocol in beckhoff/PROTOCOL.md.
// Registered as QML singleton "Beckhoff". Auto-reconnects every 2 s.
//
// ScreenScan stays fully functional when disconnected (local playhead sim);
// when connected the daemon drives the real motion and this object's
// progress / passIndex / signals drive the playhead and the Recorder.

#include <QObject>
#include <QTcpSocket>
#include <QTimer>
#include <QVariantList>

class BeckhoffLink : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool    connected   READ connected   NOTIFY connectedChanged)
    Q_PROPERTY(QString host        READ host        WRITE setHost NOTIFY hostChanged)
    Q_PROPERTY(int     port        READ port        WRITE setPort NOTIFY portChanged)

    // mirrored daemon status (10 Hz pushes)
    Q_PROPERTY(QString state       READ state       NOTIFY statusChanged)   // idle|running|…
    Q_PROPERTY(bool    running     READ running     NOTIFY statusChanged)
    Q_PROPERTY(bool    enabled     READ enabled     NOTIFY statusChanged)
    Q_PROPERTY(bool    homed       READ homed       NOTIFY statusChanged)
    Q_PROPERTY(bool    estopOk     READ estopOk     NOTIFY statusChanged)
    Q_PROPERTY(int     passIndex   READ passIndex   NOTIFY passIndexChanged)
    Q_PROPERTY(double  progress    READ progress    NOTIFY progressChanged)  // 0..1 in pass
    Q_PROPERTY(double  positionDeg READ positionDeg NOTIFY statusChanged)
    Q_PROPERTY(double  velocityDegS READ velocityDegS NOTIFY statusChanged)
    Q_PROPERTY(double  lineHz      READ lineHz      NOTIFY statusChanged)
    Q_PROPERTY(int     filterSlot  READ filterSlot  NOTIFY statusChanged)
    Q_PROPERTY(QString faultText   READ faultText   NOTIFY faultTextChanged)

public:
    explicit BeckhoffLink(QObject *parent = nullptr);

    bool    connected()    const { return m_connected; }
    QString host()         const { return m_host; }
    int     port()         const { return m_port; }
    QString state()        const { return m_state; }
    bool    running()      const { return m_state == QLatin1String("running")
                                       || m_state == QLatin1String("paused")
                                       || m_state == QLatin1String("settle")
                                       || m_state == QLatin1String("filter"); }
    bool    enabled()      const { return m_enabled; }
    bool    homed()        const { return m_homed; }
    bool    estopOk()      const { return m_estopOk; }
    int     passIndex()    const { return m_pass; }
    double  progress()     const { return m_progress; }
    double  positionDeg()  const { return m_posDeg; }
    double  velocityDegS() const { return m_velDegS; }
    double  lineHz()       const { return m_lineHz; }
    int     filterSlot()   const { return m_filterSlot; }
    QString faultText()    const { return m_faultText; }

    void setHost(const QString &h);
    void setPort(int p);

    // ── commands ──────────────────────────────────────────────────────────────
    // executeScan: profile = uniform speed-curve samples 0..1, sampled by
    // ScreenScan from the curve editor — what the artist draws is what executes.
    // targetLines = the aspect bar's line count (ScreenScan.linesCount): the
    // sensor fixes one axis at 8k, so the line total IS the image aspect. xylod
    // turns it into the trigger rate, since only it knows the rate clamp.
    Q_INVOKABLE void executeScan(int colorMode,
                                 double arcStartDeg, double arcEndDeg,
                                 double maxVelDegS, double minVelDegS,
                                 int targetLines,
                                 const QVariantList &profile);
    // executeStatic: no sweep at all. The flange holds where it already is and
    // the camera scans lines for a set time, so the image is bounded by the
    // clock, not by an arc — there is no curve and no velocity to send.
    Q_INVOKABLE void executeStatic(int colorMode, double holdDeg,
                                   double durationSec, int targetLines);
    Q_INVOKABLE void pause();
    Q_INVOKABLE void resume();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void home();
    Q_INVOKABLE void setHome();                              // teach current pose as 0°
    Q_INVOKABLE void enable(bool on);
    Q_INVOKABLE void jog(double velDegS);
    Q_INVOKABLE void moveTo(double posDeg, double velDegS);   // absolute step moves (dial jog)
    Q_INVOKABLE void setFilter(int slot);
    // Line-rate coupling for the NEXT executeScan. "curve" = trigger rate tracks
    // instantaneous velocity, so geometry stays honest. "fixed" = constant
    // baseHz regardless of speed, which stretches the subject where the axis is
    // slow and compresses it where fast — an optical effect, not a bug.
    //
    // Goes through QSettings because that is where executeScan() already reads
    // it (and has since before this accessor existed — the key was simply never
    // written by anything). sync() so a scan fired straight after cannot read
    // the previous value.
    Q_INVOKABLE void    setLineMode(const QString &mode);   // "curve" | "fixed"
    Q_INVOKABLE QString lineMode() const;
    Q_INVOKABLE void faultReset();

signals:
    void connectedChanged();
    void hostChanged();
    void portChanged();
    void statusChanged();
    void passIndexChanged();
    void progressChanged();
    void faultTextChanged();

    // sequence events — drive ScreenScan + MetadataRecorder when connected
    void passStarted(int pass, qint64 tMs);
    void passEnded(int pass, qint64 tMs);
    void sequenceDone(int passes);
    void homedEvent();
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
    QString m_state = QStringLiteral("offline");
    bool    m_enabled = false, m_homed = false, m_estopOk = true;
    int     m_pass = -1, m_filterSlot = -1;
    double  m_progress = 0.0, m_posDeg = 0.0, m_velDegS = 0.0, m_lineHz = 0.0;
    QString m_faultText;
};
