// PendantReader.h — reads the Teensy pendant over USB-CDC serial and turns
// its events into Qt key presses, so the existing keyboard focus router in
// main.qml drives the UI with no per-screen changes.
//
//   JOG 1  (CW)   -> Key_Down    (moveNext / adjust +1 while editing)
//   JOG -1 (CCW)  -> Key_Up      (movePrev / adjust -1 while editing)
//   ENC_SW DOWN   -> Key_Return  (enter / confirm)
//   BTN2 DOWN     -> Key_Escape  (back)
//   BTN1 DOWN     -> Key_Delete  (screen context action)
//
// Dependency-free: raw POSIX serial + QSocketNotifier (QtCore/QtGui only).
// Auto-reopens if the Teensy is absent at boot or unplugged at runtime.
#pragma once

#include <QObject>
#include <QByteArray>
#include <QString>

class QSocketNotifier;
class QWindow;
class QTimer;

class PendantReader : public QObject
{
    Q_OBJECT
public:
    explicit PendantReader(QObject *parent = nullptr);
    ~PendantReader() override;

    void setTargetWindow(QWindow *w) { m_target = w; }
    bool open(const QString &devPath = QStringLiteral("/dev/ttyACM0"));

private slots:
    void onReadable();

private:
    void handleLine(const QByteArray &line);
    void postKey(int key);
    void closeDevice();

    int              m_fd       = -1;
    QSocketNotifier *m_notifier = nullptr;
    QTimer          *m_retry    = nullptr;
    QByteArray       m_buf;
    QWindow         *m_target   = nullptr;
    QString          m_dev      = QStringLiteral("/dev/ttyACM0");
};
