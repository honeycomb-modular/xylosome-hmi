#pragma once
#include <QObject>
#include <QSerialPort>

class PendantReader : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int selectedRow READ selectedRow NOTIFY selectedRowChanged)
    Q_PROPERTY(int jogTotal READ jogTotal NOTIFY jogTotalChanged)
public:
    explicit PendantReader(QObject *parent = nullptr);
    ~PendantReader();
    Q_INVOKABLE void start(const QString &portName = "/dev/ttyACM0");
    Q_INVOKABLE void stop();
    int selectedRow() const { return m_selectedRow; }
    int jogTotal() const { return m_jogTotal; }
signals:
    void jogEvent(int delta);
    void buttonEvent(QString id, bool down);
    void readyEvent();
    void selectedRowChanged();
    void jogTotalChanged();
private slots:
    void onReadyRead();
    void onErrorOccurred(QSerialPort::SerialPortError error);
private:
    void parseLine(const QString &line);
    QSerialPort *m_port = nullptr;
    QByteArray   m_buffer;
    int          m_selectedRow = 0;
    int          m_jogTotal    = 0;
    int          m_lastDelta   = 0;
    int          m_sameCount   = 0;
    int          m_rowCount    = 5;
};
