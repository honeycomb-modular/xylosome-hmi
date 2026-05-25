#pragma once
// MetadataRecorder.h — XYLOSOME metadata infuser
//
// Singleton registered in QML as "Recorder" (import XylosomeHMI 1.0).
//
// Records the temporal and geometric state of every trigger event:
//   - Per-pass timestamps (t_start, t_end) for R / G / B / C passes
//   - Speed curve snapshot (Motor.nodes + Motor.seqBoxW) at trigger time
//
// Exports a single SVG per session: forensic readout suitable for
// compositing over the 8K scan in Photoshop.
//
// ClearCore integration (future):
//   Call handleTrigger() / handlePassStart(n) / handlePassEnd(n)
//   from the Ethernet message parser when ClearCore events arrive.
//   Until then, simulateTrigger() lets you test the page and SVG output.

#include <QObject>
#include <QVariantList>
#include <QString>
#include <QDateTime>
#include <QVector>
#include <QPointF>

class MotorModel;

class MetadataRecorder : public QObject
{
    Q_OBJECT

    // ── QML-exposed properties ─────────────────────────────────────────────────
    Q_PROPERTY(int          triggerCount  READ triggerCount  NOTIFY triggerCountChanged)
    Q_PROPERTY(bool         hasData       READ hasData       NOTIFY triggerCountChanged)
    Q_PROPERTY(QString      lastSummary   READ lastSummary   NOTIFY lastSummaryChanged)
    // currentPasses: QVariantList of 4 QVariantMaps
    //   { passNum, channel, tStart_ms, tEnd_ms, duration_ms }
    // Updated after every simulateTrigger() / handlePassEnd().
    Q_PROPERTY(QVariantList currentPasses READ currentPasses NOTIFY lastSummaryChanged)

public:
    // ── Internal data structures ───────────────────────────────────────────────

    struct PassRecord {
        qint64 tStart_ms = -1;   // -1 = not yet recorded
        qint64 tEnd_ms   = -1;
        qint64 duration_ms() const {
            return (tStart_ms >= 0 && tEnd_ms >= 0) ? (tEnd_ms - tStart_ms) : -1;
        }
    };

    struct TriggerRecord {
        QDateTime    capturedAt;        // wall time of trigger
        int          index  = 0;        // 1-based within session
        QVariantList nodes;             // speed curve at trigger time [{nx,ny},...]
        int          boxW   = 520;      // timeline width proxy for duration
        PassRecord   passes[4];         // 0=R  1=G  2=B  3=C
    };

    // ── Construction ───────────────────────────────────────────────────────────
    explicit MetadataRecorder(MotorModel *motor, QObject *parent = nullptr);

    // ── Property accessors ────────────────────────────────────────────────────
    int          triggerCount() const { return m_triggers.size(); }
    bool         hasData()      const { return !m_triggers.isEmpty(); }
    QString      lastSummary()  const;
    QVariantList currentPasses() const;

    // ── QML-invokable actions ─────────────────────────────────────────────────

    // Simulate a complete 4-pass trigger for testing (no ClearCore required).
    // Snapshots current Motor.nodes + seqBoxW, generates plausible timestamps.
    Q_INVOKABLE void    simulateTrigger();

    // Generate and write the session SVG.
    // Returns the full file path on success, empty string on failure.
    Q_INVOKABLE QString exportSvg(const QString &directory);

    // ── ClearCore integration (future Ethernet handler) ───────────────────────
    void handleTrigger();           // call on "trigger start" message
    void handlePassStart(int pass); // pass: 0=R  1=G  2=B  3=C
    void handlePassEnd(int pass);

signals:
    void triggerCountChanged();
    void lastSummaryChanged();

private:
    // ── Helpers ───────────────────────────────────────────────────────────────
    static QString           formatMsRelative(qint64 absMs, qint64 t0Ms);
    static QString           formatDuration(qint64 durationMs);
    static QVector<QPointF>  evalCatmullRom(const QVector<QPointF> &pts, int stepsPerSeg);
    QString                  buildSvg() const;

    // ── State ─────────────────────────────────────────────────────────────────
    MotorModel              *m_motor;
    QVector<TriggerRecord>   m_triggers;
};
