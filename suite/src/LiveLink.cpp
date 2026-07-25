// LiveLink.cpp — see LiveLink.h. Protocol: suite/LIVE_PROTOCOL.md.
#include "LiveLink.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QDebug>

#include <cstring>

LiveLink::LiveLink(QObject *parent)
    : QObject(parent)
{
    QSettings s;
    m_host = s.value(QStringLiteral("live/host"), m_host).toString();
    if (qEnvironmentVariableIsSet("LIVE_HOST"))
        m_host = qEnvironmentVariable("LIVE_HOST");

    connect(&m_sock, &QTcpSocket::readyRead, this, &LiveLink::onReadyRead);
    connect(&m_sock, &QTcpSocket::disconnected, this, &LiveLink::onDisconnected);
    connect(&m_sock, &QTcpSocket::connected, this, [this] {
        emit connectedChanged();
        sendJson(QByteArrayLiteral("{\"cmd\":\"hello\",\"client\":\"suite\"}"));
        // 4096 of the sensor's 8192 columns, not 1024. The agent decimates with
        // img[:, ::step] where step = 8192/width, so asking for 1024 threw away
        // seven pixels in eight BEFORE anything was drawn — and the focus metric
        // is computed on that same decimated block, so the number you focus by
        // was aliased too. 64 lines x 4096 at 30 Hz is ~7.5 MB/s over loopback.
        sendJson(QByteArrayLiteral("{\"cmd\":\"live_start\",\"width\":4096,\"maxHz\":30}"));
    });
    connect(&m_sock, &QTcpSocket::errorOccurred, this,
            [this](QAbstractSocket::SocketError) {
                m_error = m_sock.errorString();
                emit errorChanged();
                stop();
            });
}

void LiveLink::setHost(const QString &h)
{
    if (m_host == h)
        return;
    m_host = h;
    QSettings().setValue(QStringLiteral("live/host"), h);
    emit hostChanged();
}

void LiveLink::start()
{
    if (m_running)
        return;
    m_error.clear();
    emit errorChanged();
    m_waterfall = QImage(kCols, 1024, QImage::Format_Grayscale8);
    m_waterfall.fill(16);
    m_focusPeak = 0;
    m_running = true;
    emit runningChanged();
    qInfo() << "[live] starting — agent at" << m_host << ":5520";
    m_sock.connectToHost(m_host, 5520);
}

void LiveLink::stop()
{
    if (!m_running && m_sock.state() == QAbstractSocket::UnconnectedState)
        return;
    if (m_sock.state() == QAbstractSocket::ConnectedState)
        sendJson(QByteArrayLiteral("{\"cmd\":\"live_stop\"}"));
    m_sock.disconnectFromHost();
    if (m_sock.state() != QAbstractSocket::UnconnectedState)
        m_sock.abort();
    m_running = false;
    m_rx.clear();
    m_pendingBytes = 0;
    emit runningChanged();
    qInfo() << "[live] stopped";
}

void LiveLink::onDisconnected()
{
    emit connectedChanged();
    if (m_running) {
        m_running = false;
        emit runningChanged();
    }
}

void LiveLink::sendJson(const QByteArray &json)
{
    m_sock.write(json + '\n');
}

void LiveLink::onReadyRead()
{
    m_rx += m_sock.readAll();

    for (;;) {
        if (m_pendingBytes > 0) {
            if (m_rx.size() < m_pendingBytes)
                return;                       // wait for the full payload

            // camera lines are COLUMNS: scroll history left by count,
            // write the new lines as columns at the right edge
            if (m_waterfall.height() != m_pendingWidth) {
                m_waterfall = QImage(kCols, m_pendingWidth,
                                     QImage::Format_Grayscale8);
                m_waterfall.fill(16);
            }
            const int cols = qMin(m_pendingCount, kCols);
            const int h = m_waterfall.height();
            const qsizetype bpl = m_waterfall.bytesPerLine();
            uchar *bits = m_waterfall.bits();
            for (int y = 0; y < h; ++y)
                std::memmove(bits + y * bpl, bits + y * bpl + cols, kCols - cols);
            const uchar *src =
                reinterpret_cast<const uchar *>(m_rx.constData());
            for (int c = 0; c < cols; ++c) {
                const uchar *lineData = src + qsizetype(c) * m_pendingWidth;
                for (int y = 0; y < h; ++y)
                    bits[y * bpl + (kCols - cols + c)] = lineData[y];
            }
            m_rx.remove(0, m_pendingBytes);
            m_pendingBytes = 0;
            ++m_serial;
            emit frameChanged();
            continue;
        }

        const int nl = m_rx.indexOf('\n');
        if (nl < 0)
            return;
        const QByteArray line = m_rx.left(nl);
        m_rx.remove(0, nl + 1);
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (doc.isObject())
            handleHeader(doc.object());
    }
}

void LiveLink::handleHeader(const QJsonObject &o)
{
    const QString ev = o.value(QStringLiteral("ev")).toString();
    if (ev == QLatin1String("lines")) {
        m_pendingCount = o.value(QStringLiteral("count")).toInt();
        m_pendingWidth = o.value(QStringLiteral("width")).toInt(1024);
        m_pendingBytes = o.value(QStringLiteral("bytes")).toInt();
        m_focus = o.value(QStringLiteral("focus")).toDouble();
        m_focusPeak = qMax(m_focusPeak, m_focus);
        if (m_pendingBytes <= 0 || m_pendingBytes > 8 * 1024 * 1024)
            m_pendingBytes = 0;   // malformed — resync on next header
    } else if (ev == QLatin1String("welcome")) {
        qInfo() << "[live] agent:" << o.value(QStringLiteral("camera")).toString()
                << (o.value(QStringLiteral("sim")).toBool() ? "[SIM]" : "");
    } else if (ev == QLatin1String("error")) {
        m_error = o.value(QStringLiteral("text")).toString();
        emit errorChanged();
        qWarning() << "[live] agent error:" << m_error;
    }
}
