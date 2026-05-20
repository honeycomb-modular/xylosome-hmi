#pragma once
// HttpServer.h  ── Qt6 port of net/http_server.{h,cpp}
//
// Serves the same REST endpoints as the ESP32 WebServer on :80.
// Uses QTcpServer (always available) so Qt6::HttpServer is not required.
//
// Endpoints:
//   GET  /                   → embedded web control UI (identical HTML/CSS/JS)
//   GET  /api/state          → JSON snapshot (polled at 10 Hz by the browser)
//   POST /api/setpoint?v=X   → set setpoint (float, deg or matching unit)
//   POST /api/mode?v=NAME    → "position" | "velocity" | "torque"
//   POST /api/enable         → toggle enable
//   POST /api/zero           → zero the setpoint
//
// Default port: 8080 (no root required).
// For :80 on Pi: sudo setcap cap_net_bind_service+ep ./xylosome_hmi

#include <QObject>
#include <QTcpServer>

class MotorModel;
class QTcpSocket;

class HttpServer : public QObject
{
    Q_OBJECT

public:
    explicit HttpServer(MotorModel *motor, QObject *parent = nullptr);

    // Returns true on success. Call once from main().
    bool listen(quint16 port = 8080);

    quint16 port() const { return m_port; }

private slots:
    void onNewConnection();

private:
    void         handleRequest(QTcpSocket *socket);
    QByteArray   buildStateJson()  const;
    static const char* indexHtml();

    QTcpServer  m_server;
    MotorModel *m_motor;
    quint16     m_port = 8080;
};
