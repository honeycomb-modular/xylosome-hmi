#pragma once
// LiveLink.h — Suite ⇄ capture agent live-focus stream (:5520).
// Protocol: suite/LIVE_PROTOCOL.md. QML singleton "Live".
//
// Receives downsampled camera lines while the camera free-runs, keeps a
// rolling waterfall image (newest lines at the bottom) and mirrors the
// agent's focus metric. Connects only while live mode is on.

#include <QImage>
#include <QObject>
#include <QTcpSocket>

class LiveLink : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(double focus READ focus NOTIFY frameChanged)      // 0..1
    Q_PROPERTY(double focusPeak READ focusPeak NOTIFY frameChanged)
    Q_PROPERTY(int frameSerial READ frameSerial NOTIFY frameChanged)
    Q_PROPERTY(QString host READ host WRITE setHost NOTIFY hostChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    explicit LiveLink(QObject *parent = nullptr);

    bool connected() const { return m_sock.state() == QAbstractSocket::ConnectedState; }
    bool running() const { return m_running; }
    double focus() const { return m_focus; }
    double focusPeak() const { return m_focusPeak; }
    int frameSerial() const { return m_serial; }
    QString host() const { return m_host; }
    void setHost(const QString &h);
    QString error() const { return m_error; }

    // waterfall image for the QML image provider
    QImage waterfall() const { return m_waterfall; }

    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();

signals:
    void connectedChanged();
    void runningChanged();
    void frameChanged();
    void hostChanged();
    void errorChanged();

private slots:
    void onReadyRead();
    void onDisconnected();

private:
    void sendJson(const QByteArray &json);
    void handleHeader(const QJsonObject &o);

    QTcpSocket m_sock;
    QByteArray m_rx;
    int m_pendingBytes = 0;      // payload bytes still expected
    int m_pendingCount = 0;
    int m_pendingWidth = 0;

    // The camera is a VERTICAL line scanner: every line is a column, the
    // image builds left→right. The live strip does the same: kCols columns
    // of history, newest at the right edge.
    static constexpr int kCols = 640;
    QImage m_waterfall;
    bool m_running = false;
    double m_focus = 0;
    double m_focusPeak = 0;
    int m_serial = 0;
    QString m_host = QStringLiteral("127.0.0.1");
    QString m_error;
};
