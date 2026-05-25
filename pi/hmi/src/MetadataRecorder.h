#pragma once
// MetadataRecorder.h — XYLOSOME metadata infuser
//
// Singleton registered in QML as "Recorder" (import XylosomeHMI 1.0).
//
// One execute press = 4 sequential passes (R/G/B/C), same curve, same duration.
// The recorder captures wall-clock timestamps for each pass, then auto-exports
// the session SVG when all 4 complete.
//
// Real-time usage (called from ScreenSequences.qml execute logic):
//   Recorder.startSession()     — on execute press (snapshots curve)
//   Recorder.startPass(0..3)    — at the start of each pass
//   Recorder.endPass(0..3)      — at the end of each pass
//   Recorder.commitSession()    — after pass 3, auto-exports SVG
//
// Test usage (from ScreenMetadata [test trigger] button):
//   Recorder.simulateTrigger()  — generates a complete fake session instantly

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

    // ── Real-time session API (called from ScreenSequences execute logic) ────────
    Q_INVOKABLE void startSession();        // snapshot curve; call on execute press
    Q_INVOKABLE void startPass(int pass);   // record t_start; pass = 0..3
    Q_INVOKABLE void endPass(int pass);     // record t_end
    Q_INVOKABLE void commitSession();       // finalise + auto-export SVG

    // ── Test / manual ─────────────────────────────────────────────────────────
    // Simulate a complete 4-pass session instantly (no real execute needed).
    Q_INVOKABLE void simulateTrigger();

    // Re-export the last committed session to the given directory.
    // Returns the full file path on success, empty string on failure.
    Q_INVOKABLE QString exportSvg(const QString &directory);

    // Auto-export path (used by commitSession; same directory as manual export)
    static constexpr const char *kAutoExportDir = "/home/hoyte/xylosome_exports";

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
    TriggerRecord            m_current;     // in-progress session (between startSession / commitSession)
};
