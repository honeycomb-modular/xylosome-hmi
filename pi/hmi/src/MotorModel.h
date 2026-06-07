#pragma once
// MotorModel.h  ── Qt6 port of state/motor.h + state/motor.cpp
//
// Single source of truth for both the QML UI and the HTTP REST API.
// Exposed to QML as a registered singleton named "Motor":
//
//   // In main.cpp:
//   qmlRegisterSingletonInstance<MotorModel>("XylosomeHMI", 1, 0, "Motor", &motor);
//
//   // In any QML file after  import XylosomeHMI 1.0 :
//   text: Motor.position.toFixed(1)
//   onClicked: Motor.toggleEnabled()
//
// The mock dynamics (motor_tick → tick()) are a direct port of motor.cpp.
// When the real Teensy UART link arrives, replace tick() with a UART rx step
// behind the same property API — QML bindings pick up changes automatically.

#include <QObject>
#include <QTimer>
#include <QString>
#include <QVariant>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonValue>

class MotorModel : public QObject
{
    Q_OBJECT

    // ── Control outputs ───────────────────────────────────────────────────────
    Q_PROPERTY(int    mode     READ mode     WRITE setMode     NOTIFY modeChanged)
    Q_PROPERTY(double setpoint READ setpoint WRITE setSetpoint NOTIFY setpointChanged)
    Q_PROPERTY(bool   enabled  READ enabled  WRITE setEnabled  NOTIFY enabledChanged)

    // ── Telemetry readbacks ───────────────────────────────────────────────────
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double velocity READ velocity NOTIFY velocityChanged)
    Q_PROPERTY(double current  READ current  NOTIFY currentChanged)
    Q_PROPERTY(double tempC    READ tempC    NOTIFY tempCChanged)

    // ── Sequence state ────────────────────────────────────────────────────────
    Q_PROPERTY(bool         sequencePlaying READ sequencePlaying WRITE setSequencePlaying NOTIFY sequencePlayingChanged)
    Q_PROPERTY(QVariantList nodes           READ nodes           WRITE setNodes           NOTIFY nodesChanged)
    Q_PROPERTY(int          seqBoxW         READ seqBoxW         WRITE setSeqBoxW         NOTIFY seqBoxWChanged)
    // 0 = full color (4-pass R/G/B/C), 1 = BW (single pass)
    Q_PROPERTY(int          colorMode       READ colorMode       WRITE setColorMode       NOTIFY colorModeChanged)

    // ── QML convenience ───────────────────────────────────────────────────────
    Q_PROPERTY(QString modeName READ modeName NOTIFY modeChanged)

public:
    enum Mode { Position = 0, Velocity = 1, Torque = 2 };
    Q_ENUM(Mode)

    explicit MotorModel(QObject *parent = nullptr);

    // ── Getters ───────────────────────────────────────────────────────────────
    int     mode()             const { return m_mode; }
    double  setpoint()         const { return m_setpoint; }
    bool    enabled()          const { return m_enabled; }
    double  position()         const { return m_position; }
    double  velocity()         const { return m_velocity; }
    double  current()          const { return m_current; }
    double  tempC()            const { return m_tempC; }
    bool         sequencePlaying() const { return m_sequencePlaying; }
    QVariantList nodes()           const { return m_nodes; }
    int          seqBoxW()         const { return m_seqBoxW; }
    int          colorMode()       const { return m_colorMode; }
    QString    modeName()        const;

    // ── Setters (also callable from QML via the property write path) ──────────
    void setMode(int m);
    void setSetpoint(double v);
    void setEnabled(bool e);
    void setSequencePlaying(bool p);
    void setNodes(const QVariantList &nodes);
    void setSeqBoxW(int w);
    void setColorMode(int c);

    // ── Invokable actions (called directly from QML or HttpServer) ────────────
    Q_INVOKABLE void toggleEnabled();
    Q_INVOKABLE void zero();
    // Accepts a JSON string like '[{"nx":0.27,"ny":0.27},...]' from QML or HTTP.
    // Using JSON avoids QVariantList/QJSValue conversion ambiguity when assigned
    // from QML (Motor.nodes = jsArray silently loses type info on inner objects).
    Q_INVOKABLE void setNodesFromJson(const QString &json);
    // Easter egg — launches an external video file full-screen via mpv.
    Q_INVOKABLE void playVideo(const QString &path);

signals:
    void modeChanged();
    void setpointChanged();
    void enabledChanged();
    void positionChanged();
    void velocityChanged();
    void currentChanged();
    void tempCChanged();
    void sequencePlayingChanged();
    void nodesChanged();
    void seqBoxWChanged();
    void colorModeChanged();

private slots:
    void tick();   // 10 Hz mock dynamics — swap for real UART rx in Phase 6

private:
    int    m_mode             = Position;
    double m_setpoint         = 0.0;
    bool   m_enabled          = false;
    double m_position         = 0.0;
    double m_velocity         = 0.0;
    double m_current          = 0.0;
    double m_tempC            = 24.0;
    bool         m_sequencePlaying  = false;
    QVariantList m_nodes;            // initialised in constructor
    int          m_seqBoxW          = 520;
    int          m_colorMode        = 0;   // 0=color, 1=BW

    QTimer m_timer;
};
