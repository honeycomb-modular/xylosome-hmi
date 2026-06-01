// PendantReader.cpp — see PendantReader.h
#include "PendantReader.h"

#include <QSocketNotifier>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QWindow>
#include <QTimer>
#include <QDebug>

#include <fcntl.h>
#include <termios.h>
#include <unistd.h>

PendantReader::PendantReader(QObject *parent) : QObject(parent)
{
    // Retry opening the device every 2 s while it is closed (Teensy not yet
    // plugged in, or unplugged at runtime).
    m_retry = new QTimer(this);
    m_retry->setInterval(2000);
    connect(m_retry, &QTimer::timeout, this, [this] {
        if (m_fd < 0) open(m_dev);
    });
}

PendantReader::~PendantReader() { closeDevice(); }

bool PendantReader::open(const QString &devPath)
{
    m_dev = devPath;
    closeDevice();

    const int fd = ::open(devPath.toLocal8Bit().constData(),
                          O_RDONLY | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        m_retry->start();
        return false;
    }

    termios tio{};
    if (tcgetattr(fd, &tio) == 0) {
        cfmakeraw(&tio);
        cfsetispeed(&tio, B115200);
        cfsetospeed(&tio, B115200);
        tio.c_cflag |= (CLOCAL | CREAD);
        tcsetattr(fd, TCSANOW, &tio);
    }

    m_fd = fd;
    m_notifier = new QSocketNotifier(fd, QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated, this, &PendantReader::onReadable);
    m_retry->stop();
    qInfo() << "[pendant] connected:" << devPath;
    return true;
}

void PendantReader::closeDevice()
{
    if (m_notifier) {
        m_notifier->setEnabled(false);
        m_notifier->deleteLater();
        m_notifier = nullptr;
    }
    if (m_fd >= 0) {
        ::close(m_fd);
        m_fd = -1;
    }
}

void PendantReader::onReadable()
{
    char chunk[256];
    const ssize_t n = ::read(m_fd, chunk, sizeof(chunk));
    if (n <= 0) {                 // EOF / error → Teensy unplugged
        qInfo() << "[pendant] disconnected — will retry";
        closeDevice();
        m_retry->start();
        return;
    }

    m_buf.append(chunk, int(n));
    int idx;
    while ((idx = m_buf.indexOf('\n')) >= 0) {
        QByteArray line = m_buf.left(idx);
        m_buf.remove(0, idx + 1);
        line.replace('\r', QByteArray());
        line = line.trimmed();
        if (!line.isEmpty())
            handleLine(line);
    }
}

void PendantReader::handleLine(const QByteArray &line)
{
    if      (line == "JOG 1")       postKey(Qt::Key_Down);    // CW  → next
    else if (line == "JOG -1")      postKey(Qt::Key_Up);      // CCW → prev
    else if (line == "ENC_SW DOWN") postKey(Qt::Key_Return);  // click → enter
    else if (line == "BTN2 DOWN")   postKey(Qt::Key_Escape);  // back
    else if (line == "BTN1 DOWN")   postKey(Qt::Key_Delete);  // context
    // READY and *_UP lines are ignored.
}

void PendantReader::postKey(int key)
{
    if (!m_target)
        return;
    QGuiApplication::postEvent(m_target, new QKeyEvent(QEvent::KeyPress,   key, Qt::NoModifier));
    QGuiApplication::postEvent(m_target, new QKeyEvent(QEvent::KeyRelease, key, Qt::NoModifier));
}
