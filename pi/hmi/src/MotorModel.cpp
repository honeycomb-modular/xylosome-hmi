// MotorModel.cpp  ── direct port of state/motor.cpp
//
// tick() reproduces the exact mock dynamics from the ESP32:
//   if enabled:  position tracks setpoint with 5% lag per tick
//                velocity = (setpoint - position) * 2
//                current  = |velocity| * 0.05 + 0.20
//                temp     += (current - 0.30) * 0.02
//   if disabled: velocity and current decay at 0.9× per tick
//
// Swap tick() contents for real UART rx/tx once the Teensy link is in place
// (Phase 6 in the original PROGRESS.md).

#include "MotorModel.h"
#include <cmath>
#include <QDebug>
#include <QProcess>
#include <QSettings>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonDocument>

// Helper to make a node QVariantMap
static QVariantMap makeNode(double nx, double ny) {
    QVariantMap m;
    m["nx"] = nx;
    m["ny"] = ny;
    return m;
}

MotorModel::MotorModel(QObject *parent)
    : QObject(parent)
{
    // Default nodes — overridden by loadFromSettings() if saved data exists
    m_nodes << makeNode(0.00, 0.52)
            << makeNode(0.27, 0.27)
            << makeNode(0.50, 0.63)
            << makeNode(0.70, 0.17)
            << makeNode(1.00, 0.41);

    connect(&m_timer, &QTimer::timeout, this, &MotorModel::tick);
    m_timer.start(100);

    // Debounced settings writer — scan state (nodes/boxW/colorMode)
    m_settingsTimer.setInterval(1000);
    m_settingsTimer.setSingleShot(true);
    connect(&m_settingsTimer, &QTimer::timeout, this, &MotorModel::saveLastToSettings);

    loadFromSettings();   // restore saved scan state + presets
}

QString MotorModel::modeName() const {
    switch (m_mode) {
        case Position: return QStringLiteral("position");
        case Velocity: return QStringLiteral("velocity");
        case Torque:   return QStringLiteral("torque");
    }
    return QStringLiteral("position");
}

void MotorModel::setMode(int m) {
    if (m_mode == m) return;
    m_mode = m;
    emit modeChanged();
    qDebug() << "[motor] mode =" << modeName();
}

void MotorModel::setSetpoint(double v) {
    if (qFuzzyCompare(m_setpoint, v)) return;
    m_setpoint = v;
    emit setpointChanged();
}

void MotorModel::setEnabled(bool e) {
    if (m_enabled == e) return;
    m_enabled = e;
    emit enabledChanged();
    qDebug() << "[motor] enabled =" << m_enabled;
}

void MotorModel::toggleEnabled() {
    setEnabled(!m_enabled);
}

void MotorModel::zero() {
    setSetpoint(0.0);
    qDebug() << "[motor] zeroed";
}

void MotorModel::setSequencePlaying(bool p) {
    if (m_sequencePlaying == p) return;
    m_sequencePlaying = p;
    emit sequencePlayingChanged();
    qDebug() << "[motor] sequencePlaying =" << p;
}

void MotorModel::setNodes(const QVariantList &nodes) {
    if (nodes.isEmpty()) return;
    m_nodes = nodes;
    emit nodesChanged();
}

// Parse a JSON string '[{"nx":0.27,"ny":0.52},...]' into m_nodes.
// Called from QML (via Q_INVOKABLE) and from HttpServer to avoid the
// QVariantList/QJSValue conversion ambiguity that plagues property assignment.
void MotorModel::setNodesFromJson(const QString &json) {
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray()) {
        qWarning("[motor] setNodesFromJson: not a JSON array");
        return;
    }
    QVariantList vl;
    for (const QJsonValue &v : doc.array()) {
        QVariantMap m;
        m[QStringLiteral("nx")] = v[QStringLiteral("nx")].toDouble();
        m[QStringLiteral("ny")] = v[QStringLiteral("ny")].toDouble();
        vl.append(m);
    }
    if (vl.isEmpty()) return;
    // Always pin endpoints to nx=0 and nx=1 to prevent gap at box edges
    { QVariantMap m = vl.first().toMap(); m[QStringLiteral("nx")] = 0.0; vl[0] = m; }
    { QVariantMap m = vl.last().toMap();  m[QStringLiteral("nx")] = 1.0; vl[vl.size()-1] = m; }
    m_nodes = vl;
    emit nodesChanged();
    m_settingsTimer.start();
    qDebug() << "[motor] setNodesFromJson: loaded" << vl.size() << "nodes";
}

void MotorModel::setSeqBoxW(int w) {
    if (m_seqBoxW == w) return;
    m_seqBoxW = w;
    emit seqBoxWChanged();
    m_settingsTimer.start();
}

void MotorModel::setColorMode(int c) {
    if (m_colorMode == c) return;
    m_colorMode = c;
    emit colorModeChanged();
    m_settingsTimer.start();   // persist after brief settle
    qDebug() << "[motor] colorMode =" << (c == 0 ? "COLOR" : "BW");
}

void MotorModel::savePreset(double hand1Angle, double hand2Angle) {
    QVariantMap p;
    p[QStringLiteral("name")]       = QStringLiteral("preset %1").arg(m_presets.size() + 1);
    p[QStringLiteral("colorMode")]  = m_colorMode;
    p[QStringLiteral("boxW")]       = m_seqBoxW;
    p[QStringLiteral("hand1Angle")] = hand1Angle;
    p[QStringLiteral("hand2Angle")] = hand2Angle;
    p[QStringLiteral("nodes")]      = m_nodes;
    m_presets.insert(0, p);   // newest first
    emit presetsChanged();
    savePresetsToSettings();
    qDebug() << "[motor] preset saved:" << p[QStringLiteral("name")].toString();
}

void MotorModel::loadPreset(int index) {
    if (index < 0 || index >= m_presets.size()) return;
    const QVariantMap p = m_presets[index].toMap();

    const int cm = p[QStringLiteral("colorMode")].toInt();
    if (m_colorMode != cm) { m_colorMode = cm; emit colorModeChanged(); }

    const int bw = p[QStringLiteral("boxW")].toInt();
    if (m_seqBoxW != bw) { m_seqBoxW = bw; emit seqBoxWChanged(); }

    const QVariantList nodes = p[QStringLiteral("nodes")].toList();
    if (!nodes.isEmpty()) { m_nodes = nodes; emit nodesChanged(); }

    qDebug() << "[motor] preset loaded:" << p[QStringLiteral("name")].toString();
}

void MotorModel::deletePreset(int index) {
    if (index < 0 || index >= m_presets.size()) return;
    m_presets.removeAt(index);
    emit presetsChanged();
    savePresetsToSettings();
    qDebug() << "[motor] preset deleted, remaining:" << m_presets.size();
}

void MotorModel::playVideo(const QString &path) {
    qDebug() << "[motor] playVideo:" << path;
    QProcess::startDetached(QStringLiteral("mpv"), {
        QStringLiteral("--fullscreen"),
        QStringLiteral("--no-terminal"),
        QStringLiteral("--hwdec=auto"),
        path
    });
}

// ── QSettings persistence ─────────────────────────────────────────────────────

QString MotorModel::nodesToJson(const QVariantList &nodes) {
    QJsonArray arr;
    for (const QVariant &n : nodes) {
        const QVariantMap nm = n.toMap();
        QJsonObject obj;
        obj[QStringLiteral("nx")] = nm[QStringLiteral("nx")].toDouble();
        obj[QStringLiteral("ny")] = nm[QStringLiteral("ny")].toDouble();
        arr.append(obj);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

void MotorModel::loadFromSettings() {
    QSettings s;

    // ── Last scan state ───────────────────────────────────────────────────────
    m_colorMode = s.value(QStringLiteral("last/colorMode"), 0).toInt();
    m_seqBoxW   = s.value(QStringLiteral("last/seqBoxW"),  520).toInt();

    const QString nodesJson = s.value(QStringLiteral("last/nodes")).toString();
    if (!nodesJson.isEmpty()) {
        const QJsonDocument doc = QJsonDocument::fromJson(nodesJson.toUtf8());
        if (doc.isArray()) {
            QVariantList vl;
            for (const QJsonValue &v : doc.array()) {
                QVariantMap m;
                m[QStringLiteral("nx")] = v[QStringLiteral("nx")].toDouble();
                m[QStringLiteral("ny")] = v[QStringLiteral("ny")].toDouble();
                vl.append(m);
            }
            if (vl.size() >= 2) {
                { QVariantMap m = vl.first().toMap(); m[QStringLiteral("nx")] = 0.0; vl[0] = m; }
                { QVariantMap m = vl.last().toMap();  m[QStringLiteral("nx")] = 1.0; vl[vl.size()-1] = m; }
                m_nodes = vl;
            }
        }
    }

    // ── Presets ───────────────────────────────────────────────────────────────
    const int count = s.beginReadArray(QStringLiteral("presets"));
    for (int i = 0; i < count; i++) {
        s.setArrayIndex(i);
        QVariantMap p;
        p[QStringLiteral("name")]       = s.value(QStringLiteral("name")).toString();
        p[QStringLiteral("colorMode")]  = s.value(QStringLiteral("colorMode"),  0).toInt();
        p[QStringLiteral("boxW")]       = s.value(QStringLiteral("boxW"),      520).toInt();
        p[QStringLiteral("hand1Angle")] = s.value(QStringLiteral("hand1Angle"), 0.0).toDouble();
        p[QStringLiteral("hand2Angle")] = s.value(QStringLiteral("hand2Angle"), 90.0).toDouble();

        const QString pj = s.value(QStringLiteral("nodes")).toString();
        if (!pj.isEmpty()) {
            const QJsonDocument doc = QJsonDocument::fromJson(pj.toUtf8());
            if (doc.isArray()) {
                QVariantList vl;
                for (const QJsonValue &v : doc.array()) {
                    QVariantMap m;
                    m[QStringLiteral("nx")] = v[QStringLiteral("nx")].toDouble();
                    m[QStringLiteral("ny")] = v[QStringLiteral("ny")].toDouble();
                    vl.append(m);
                }
                p[QStringLiteral("nodes")] = vl;
            }
        }
        m_presets.append(p);
    }
    s.endArray();

    qInfo() << "[settings] loaded — colorMode" << m_colorMode
            << "seqBoxW" << m_seqBoxW
            << "nodes" << m_nodes.size()
            << "presets" << m_presets.size();
}

void MotorModel::saveLastToSettings() {
    QSettings s;
    s.setValue(QStringLiteral("last/colorMode"), m_colorMode);
    s.setValue(QStringLiteral("last/seqBoxW"),   m_seqBoxW);
    s.setValue(QStringLiteral("last/nodes"),     nodesToJson(m_nodes));
    qDebug() << "[settings] scan state saved";
}

void MotorModel::savePresetsToSettings() {
    QSettings s;
    s.beginWriteArray(QStringLiteral("presets"));
    for (int i = 0; i < m_presets.size(); i++) {
        s.setArrayIndex(i);
        const QVariantMap p = m_presets[i].toMap();
        s.setValue(QStringLiteral("name"),       p[QStringLiteral("name")]);
        s.setValue(QStringLiteral("colorMode"),  p[QStringLiteral("colorMode")]);
        s.setValue(QStringLiteral("boxW"),       p[QStringLiteral("boxW")]);
        s.setValue(QStringLiteral("hand1Angle"), p[QStringLiteral("hand1Angle")]);
        s.setValue(QStringLiteral("hand2Angle"), p[QStringLiteral("hand2Angle")]);
        s.setValue(QStringLiteral("nodes"),      nodesToJson(p[QStringLiteral("nodes")].toList()));
    }
    s.endArray();
    qDebug() << "[settings] presets saved —" << m_presets.size() << "entries";
}

// Direct port of state/motor.cpp :: motor_tick()
void MotorModel::tick() {
    if (m_enabled) {
        m_position += (m_setpoint - m_position) * 0.05;
        m_velocity  = (m_setpoint - m_position) * 2.0;
        m_current   = std::abs(m_velocity) * 0.05 + 0.20;
        m_tempC    += (m_current - 0.30) * 0.02;
    } else {
        m_velocity *= 0.9;
        m_current  *= 0.9;
    }
    // Emit all telemetry signals; QML bindings update automatically.
    emit positionChanged();
    emit velocityChanged();
    emit currentChanged();
    emit tempCChanged();
}
