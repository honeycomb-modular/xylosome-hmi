#include "PendantReader.h"
#include <QDebug>

PendantReader::PendantReader(QObject *parent) : QObject(parent) {}
PendantReader::~PendantReader() { stop(); }

void PendantReader::start(const QString &portName)
{
    if (m_port) { m_port->close(); delete m_port; }
    m_port = new QSerialPort(portName, this);
    m_port->setBaudRate(QSerialPort::Baud115200);
    m_port->setDataBits(QSerialPort::Data8);
    m_port->setParity(QSerialPort::NoParity);
    m_port->setStopBits(QSerialPort::OneStop);
    m_port->setFlowControl(QSerialPort::NoFlowControl);
    connect(m_port, &QSerialPort::readyRead, this, &PendantReader::onReadyRead);
    connect(m_port, &QSerialPort::errorOccurred, this, &PendantReader::onErrorOccurred);
    if (m_port->open(QIODevice::ReadWrite))
        qInfo("[pendant] connected on %s", qPrintable(portName));
    else
        qWarning("[pendant] failed: %s", qPrintable(m_port->errorString()));
}

void PendantReader::stop()
{
    if (m_port) { m_port->close(); delete m_port; m_port = nullptr; }
}

void PendantReader::onReadyRead()
{
    m_buffer += m_port->readAll();
    while (m_buffer.contains('\n')) {
        int idx = m_buffer.indexOf('\n');
        QString line = QString::fromLatin1(m_buffer.left(idx)).trimmed();
        m_buffer = m_buffer.mid(idx + 1);
        if (!line.isEmpty()) parseLine(line);
    }
}

void PendantReader::onErrorOccurred(QSerialPort::SerialPortError error)
{
    if (error != QSerialPort::NoError)
        qWarning("[pendant] serial error: %d", error);
}

void PendantReader::parseLine(const QString &line)
{
    QStringList parts = line.split(' ', Qt::SkipEmptyParts);
    if (parts.isEmpty()) return;
    if (parts[0] == "READY") { emit readyEvent(); return; }
    if (parts[0] == "JOG" && parts.size() == 2) {
        bool ok; int delta = parts[1].toInt(&ok);
        if (ok) {
            if (delta == m_lastDelta) {
                m_sameCount++;
                if (m_sameCount >= 2) {
                    m_sameCount = 0;
                    emit jogEvent(delta);
                    m_selectedRow = (m_selectedRow + delta + m_rowCount) % m_rowCount;
                    emit selectedRowChanged();
                    m_jogTotal += delta;
                    emit jogTotalChanged();
                }
            } else {
                m_lastDelta = delta;
                m_sameCount = 1;
            }
        }
        return;
    }
    if ((parts[0] == "BTN1" || parts[0] == "BTN2" || parts[0] == "ENC_SW") && parts.size() == 2)
        emit buttonEvent(parts[0], parts[1].toUpper() == "DOWN");
}
