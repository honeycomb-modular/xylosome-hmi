// MetadataRecorder.cpp — XYLOSOME metadata infuser implementation

#include "MetadataRecorder.h"
#include "MotorModel.h"

#include <QDir>
#include <QFile>
#include <QTextStream>
#include <QVariantMap>
#include <QtMath>

// ── Construction ──────────────────────────────────────────────────────────────

MetadataRecorder::MetadataRecorder(MotorModel *motor, QObject *parent)
    : QObject(parent), m_motor(motor)
{}

// ── Property accessors ────────────────────────────────────────────────────────

QString MetadataRecorder::lastSummary() const
{
    if (m_triggers.isEmpty())
        return "no triggers recorded";
    const auto &t = m_triggers.last();
    return QString("trigger %1  —  %2  —  %3 passes")
        .arg(t.index)
        .arg(t.capturedAt.toString("hh:mm:ss"))
        .arg(4);
}

QVariantList MetadataRecorder::currentPasses() const
{
    if (m_triggers.isEmpty()) return {};

    const TriggerRecord &t = m_triggers.last();
    qint64 t0 = t.passes[0].tStart_ms >= 0 ? t.passes[0].tStart_ms
                                             : t.capturedAt.toMSecsSinceEpoch();

    const char *chNames[4]  = { "R", "G", "B", "C" };
    QVariantList out;
    for (int i = 0; i < 4; i++) {
        QVariantMap m;
        m["passNum"]     = i + 1;
        m["channel"]     = QString(chNames[i]);
        m["tStart_ms"]   = t.passes[i].tStart_ms;
        m["tEnd_ms"]     = t.passes[i].tEnd_ms;
        m["duration_ms"] = t.passes[i].duration_ms();
        m["tStartStr"]   = t.passes[i].tStart_ms >= 0
                           ? formatMsRelative(t.passes[i].tStart_ms, t0) : "--:--.---";
        m["tEndStr"]     = t.passes[i].tEnd_ms   >= 0
                           ? formatMsRelative(t.passes[i].tEnd_ms,   t0) : "--:--.---";
        m["durationStr"] = formatDuration(t.passes[i].duration_ms());
        out.append(m);
    }
    return out;
}

// ── Simulate trigger (testing, no ClearCore) ──────────────────────────────────

void MetadataRecorder::simulateTrigger()
{
    TriggerRecord rec;
    rec.capturedAt = QDateTime::currentDateTime();
    rec.index      = m_triggers.size() + 1;
    rec.nodes      = m_motor->nodes();
    rec.boxW       = m_motor->seqBoxW();

    // Duration based on boxW / seqBoxW ratio — rough heuristic.
    // boxW=520 → ~2.14 s; scale linearly.
    const double baseDur_ms = 2140.0 * (rec.boxW / 520.0);
    const double gap_ms     =   57.0;  // inter-pass gap

    qint64 t = rec.capturedAt.toMSecsSinceEpoch();
    for (int i = 0; i < 4; i++) {
        rec.passes[i].tStart_ms = t;
        rec.passes[i].tEnd_ms   = t + static_cast<qint64>(baseDur_ms);
        t += static_cast<qint64>(baseDur_ms + gap_ms);
    }

    m_triggers.append(rec);
    emit triggerCountChanged();
    emit lastSummaryChanged();
}

// ── ClearCore integration ─────────────────────────────────────────────────────

void MetadataRecorder::handleTrigger()
{
    TriggerRecord rec;
    rec.capturedAt = QDateTime::currentDateTime();
    rec.index      = m_triggers.size() + 1;
    rec.nodes      = m_motor->nodes();
    rec.boxW       = m_motor->seqBoxW();
    m_triggers.append(rec);
    emit triggerCountChanged();
    emit lastSummaryChanged();
}

void MetadataRecorder::handlePassStart(int pass)
{
    if (m_triggers.isEmpty() || pass < 0 || pass > 3) return;
    m_triggers.last().passes[pass].tStart_ms = QDateTime::currentMSecsSinceEpoch();
}

void MetadataRecorder::handlePassEnd(int pass)
{
    if (m_triggers.isEmpty() || pass < 0 || pass > 3) return;
    m_triggers.last().passes[pass].tEnd_ms = QDateTime::currentMSecsSinceEpoch();
    emit lastSummaryChanged();
}

// ── Time formatting ───────────────────────────────────────────────────────────

QString MetadataRecorder::formatMsRelative(qint64 absMs, qint64 t0Ms)
{
    qint64 rel  = absMs - t0Ms;
    if (rel < 0) rel = 0;
    qint64 min  =  rel / 60000;
    qint64 sec  = (rel % 60000) / 1000;
    qint64 frac =  rel % 1000;
    return QString("%1:%2.%3")
        .arg(min,  2, 10, QLatin1Char('0'))
        .arg(sec,  2, 10, QLatin1Char('0'))
        .arg(frac, 3, 10, QLatin1Char('0'));
}

QString MetadataRecorder::formatDuration(qint64 durationMs)
{
    if (durationMs < 0) return "---s";
    return QString::number(durationMs / 1000.0, 'f', 3) + "s";
}

// ── Catmull-Rom → polyline ────────────────────────────────────────────────────
// Mirrors the evalSeg() logic in ScreenSequences.qml exactly.

QVector<QPointF> MetadataRecorder::evalCatmullRom(const QVector<QPointF> &pts, int steps)
{
    int n = pts.size();
    if (n < 2) return {};

    QVector<QPointF> out;
    out.reserve((n - 1) * steps + 1);

    for (int seg = 0; seg < n - 1; seg++) {
        int i0 = qMax(0,     seg - 1);
        int i3 = qMin(n - 1, seg + 2);

        QPointF p0 = pts[i0];
        QPointF p1 = pts[seg];
        QPointF p2 = pts[seg + 1];
        QPointF p3 = pts[i3];

        // Catmull-Rom tangent → cubic Bezier control points
        QPointF c1 = p1 + (p2 - p0) / 6.0;
        QPointF c2 = p2 - (p3 - p1) / 6.0;

        int last_k = (seg == n - 2) ? steps : steps - 1;
        for (int k = 0; k <= last_k; k++) {
            double t  = double(k) / steps;
            double mt = 1.0 - t;
            double x  = mt*mt*mt * p1.x()
                      + 3*mt*mt*t * c1.x()
                      + 3*mt*t*t  * c2.x()
                      + t*t*t     * p2.x();
            double y  = mt*mt*mt * p1.y()
                      + 3*mt*mt*t * c1.y()
                      + 3*mt*t*t  * c2.y()
                      + t*t*t     * p2.y();
            out.append(QPointF(x, y));
        }
    }
    return out;
}

// ── SVG export ────────────────────────────────────────────────────────────────

QString MetadataRecorder::exportSvg(const QString &directory)
{
    if (m_triggers.isEmpty()) return {};

    QDir dir(directory);
    if (!dir.exists()) dir.mkpath(".");

    const TriggerRecord &first = m_triggers.first();
    QString filename = QString("xylosome_%1_%2.svg")
        .arg(first.capturedAt.toString("yyyyMMdd"))
        .arg(first.capturedAt.toString("HHmmss"));
    QString fullPath = dir.filePath(filename);

    QFile f(fullPath);
    if (!f.open(QFile::WriteOnly | QFile::Text)) return {};

    QTextStream ts(&f);
    ts << buildSvg();
    f.close();

    return fullPath;
}

// ── SVG builder ───────────────────────────────────────────────────────────────
//
// Output: 8192 × (header + N × triggerRowH) px, white-on-black.
// Typography: Courier New monospace.
// Curve: Catmull-Rom polyline, matches screen rendering exactly.

QString MetadataRecorder::buildSvg() const
{
    // ── Geometry constants ────────────────────────────────────────────────────
    const int svgW       = 8192;
    const int marginX    = 96;
    const int headerH    = 200;
    const int trigRowH   = 360;   // height per trigger block
    const int footerH    = 60;

    // Speed curve graph (left of each trigger block)
    const int graphW     = 1400;
    const int graphH     = 200;
    const int graphOffY  = 48;    // offset from trigger block top

    // Timing table (right of graph)
    const int tableX     = marginX + graphW + 72;
    const int tableColW  = 220;

    // Typography
    const int fzTitle    = 48;
    const int fzHead     = 32;
    const int fzBody     = 30;
    const int fzDim      = 24;
    const QString fontMono = "Courier New, Courier, monospace";

    // Colors
    const QString cBg    = "#000000";
    const QString cText  = "#ECECEC";
    const QString cDim   = "#888888";
    const QString cFaint = "#444444";
    const QString cBorder= "#333333";
    const QString cPanel = "#0A0A0A";
    const QString chColor[4] = { "#CC4444", "#44CC44", "#4488CC", "#AAAAAA" };
    const char   *chName[4]  = { "R", "G", "B", "C" };

    int totalH = headerH + m_triggers.size() * trigRowH + footerH;

    QString svg;
    QTextStream o(&svg);

    // ── SVG root ──────────────────────────────────────────────────────────────
    o << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    o << QString("<svg xmlns=\"http://www.w3.org/2000/svg\" "
                 "width=\"%1\" height=\"%2\" viewBox=\"0 0 %1 %2\">\n")
         .arg(svgW).arg(totalH);

    // Background
    o << QString("<rect width=\"%1\" height=\"%2\" fill=\"%3\"/>\n")
         .arg(svgW).arg(totalH).arg(cBg);

    // ── Inline helpers (lambdas) ──────────────────────────────────────────────

    // text element
    auto txt = [&](int x, int y, const QString &s, int sz,
                   const QString &fill = "#ECECEC",
                   const QString &anchor = "start")
    {
        o << QString("<text x=\"%1\" y=\"%2\" "
                     "font-family=\"%3\" font-size=\"%4\" "
                     "fill=\"%5\" text-anchor=\"%6\">%7</text>\n")
             .arg(x).arg(y).arg(fontMono).arg(sz).arg(fill).arg(anchor)
             .arg(s.toHtmlEscaped());
    };

    // horizontal rule
    auto hline = [&](int x, int y, int w, const QString &stroke = "#333333") {
        o << QString("<line x1=\"%1\" y1=\"%2\" x2=\"%3\" y2=\"%2\" "
                     "stroke=\"%4\" stroke-width=\"1\"/>\n")
             .arg(x).arg(y).arg(x + w).arg(stroke);
    };

    // ── Session header ────────────────────────────────────────────────────────
    const TriggerRecord &first = m_triggers.first();
    QString sessionId = first.capturedAt.toString("yyyyMMdd-HHmmss");
    QString dateStr   = first.capturedAt.toString("yyyy-MM-dd  hh:mm:ss");

    txt(marginX, 64, "XYLOSOME", fzTitle, cText);
    txt(marginX + 380, 64,
        QString("—  %1  —  %2").arg(sessionId).arg(dateStr),
        fzHead, cDim);
    txt(svgW - marginX, 64,
        QString("%1 TRIGGER%2")
            .arg(m_triggers.size())
            .arg(m_triggers.size() == 1 ? "" : "S"),
        fzDim, cFaint, "end");

    hline(marginX, 80, svgW - 2 * marginX, cBorder);

    txt(marginX, 120, "SPEED CURVE", fzDim, cFaint);
    txt(marginX + graphW + 72, 120, "PASS TIMING", fzDim, cFaint);
    hline(marginX, 136, svgW - 2 * marginX, "#1E1E1E");

    // ── Per-trigger blocks ────────────────────────────────────────────────────
    for (int ti = 0; ti < m_triggers.size(); ti++) {
        const TriggerRecord &tr = m_triggers[ti];
        int baseY = headerH + ti * trigRowH;

        // Trigger label
        txt(marginX, baseY + 32,
            QString("TRIGGER %1").arg(tr.index), fzDim, cFaint);
        txt(marginX + 280, baseY + 32,
            tr.capturedAt.toString("hh:mm:ss.zzz"), fzDim, cDim);

        // ── Speed curve box ───────────────────────────────────────────────────
        int gx = marginX;
        int gy = baseY + graphOffY;

        // Box background
        o << QString("<rect x=\"%1\" y=\"%2\" width=\"%3\" height=\"%4\" "
                     "fill=\"%5\" stroke=\"%6\" stroke-width=\"1\"/>\n")
             .arg(gx).arg(gy).arg(graphW).arg(graphH).arg(cPanel).arg(cBorder);

        // Grid (fine + coarse)
        o << "<g stroke=\"#161616\" stroke-width=\"0.5\">\n";
        for (int gix = 0; gix <= graphW; gix += graphW / 16)
            o << QString("<line x1=\"%1\" y1=\"%2\" x2=\"%1\" y2=\"%3\"/>\n")
                 .arg(gx + gix).arg(gy).arg(gy + graphH);
        for (int giy = 0; giy <= graphH; giy += graphH / 4)
            o << QString("<line x1=\"%1\" y1=\"%2\" x2=\"%3\" y2=\"%2\"/>\n")
                 .arg(gx).arg(gy + giy).arg(gx + graphW);
        o << "</g>\n";

        // Zero axis (horizontal centre, dashed)
        int zy = gy + graphH / 2;
        o << QString("<line x1=\"%1\" y1=\"%2\" x2=\"%3\" y2=\"%2\" "
                     "stroke=\"#505050\" stroke-width=\"0.5\" stroke-dasharray=\"6,8\"/>\n")
             .arg(gx).arg(zy).arg(gx + graphW);

        // Channel labels on zero axis (right side, stacked)
        // (space-saving: only one shared curve for now; future = 4 overlaid curves)
        o << QString("<text x=\"%1\" y=\"%2\" "
                     "font-family=\"%3\" font-size=\"%4\" fill=\"%5\">SPEED</text>\n")
             .arg(gx + 10).arg(gy + 22)
             .arg(fontMono).arg(fzDim).arg(cFaint);

        // Catmull-Rom curve from snapshotted nodes
        QVector<QPointF> rawPts;
        for (const QVariant &v : tr.nodes) {
            QVariantMap nm = v.toMap();
            double nx = nm.value("nx", 0.0).toDouble();
            double ny = nm.value("ny", 0.5).toDouble();
            rawPts.append(QPointF(nx * graphW, ny * graphH));
        }

        if (rawPts.size() >= 2) {
            QVector<QPointF> curve = evalCatmullRom(rawPts, 24);
            if (!curve.isEmpty()) {
                o << "<polyline fill=\"none\" stroke=\"" << cText
                  << "\" stroke-width=\"2.5\" stroke-linejoin=\"round\" points=\"";
                for (const QPointF &pt : curve) {
                    o << QString("%1,%2 ")
                         .arg(gx + pt.x(), 0, 'f', 1)
                         .arg(gy + pt.y(), 0, 'f', 1);
                }
                o << "\"/>\n";

                // Node dots
                for (const QPointF &np : rawPts) {
                    o << QString("<circle cx=\"%1\" cy=\"%2\" r=\"4\" fill=\"#4ADE80\"/>\n")
                         .arg(gx + np.x(), 0, 'f', 1)
                         .arg(gy + np.y(), 0, 'f', 1);
                }
            }
        }

        // box_w annotation below graph
        txt(gx, gy + graphH + 22,
            QString("box_w = %1 px").arg(tr.boxW), fzDim, cFaint);

        // ── Timing table ──────────────────────────────────────────────────────
        // t0 = absolute ms of first pass start (or trigger wall time)
        qint64 t0 = tr.passes[0].tStart_ms >= 0
                    ? tr.passes[0].tStart_ms
                    : tr.capturedAt.toMSecsSinceEpoch();

        int tblY = baseY + graphOffY;

        // Column headers
        auto th = [&](int col, const QString &label) {
            txt(tableX + col * tableColW, tblY + 30, label, fzDim, cFaint);
        };
        th(0, "PASS");
        th(1, "CH");
        th(2, "t_start");
        th(3, "t_end");
        th(4, "DURATION");

        hline(tableX, tblY + 38, svgW - marginX - tableX, cBorder);

        for (int pi = 0; pi < 4; pi++) {
            const PassRecord &pr = tr.passes[pi];
            int rowY = tblY + 38 + 2 + (pi + 1) * 46;

            QString tStart = pr.tStart_ms >= 0
                ? formatMsRelative(pr.tStart_ms, t0) : "--:--.---";
            QString tEnd   = pr.tEnd_ms   >= 0
                ? formatMsRelative(pr.tEnd_ms,   t0) : "--:--.---";
            QString dur    = formatDuration(pr.duration_ms());

            txt(tableX + 0 * tableColW, rowY, QString::number(pi + 1), fzBody, cDim);
            txt(tableX + 1 * tableColW, rowY, chName[pi],               fzBody, chColor[pi]);
            txt(tableX + 2 * tableColW, rowY, tStart,                   fzBody, cText);
            txt(tableX + 3 * tableColW, rowY, tEnd,                     fzBody, cText);
            txt(tableX + 4 * tableColW, rowY, dur,                      fzBody, cText);
        }

        // Block separator
        if (ti < m_triggers.size() - 1) {
            hline(marginX, baseY + trigRowH - 10, svgW - 2 * marginX, "#1E1E1E");
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────────
    int footY = headerH + m_triggers.size() * trigRowH;
    hline(marginX, footY + 16, svgW - 2 * marginX, cBorder);

    txt(marginX, footY + 46,
        QString("XYLOSOME METADATA — EXPORTED %1")
            .arg(QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss")),
        fzDim, cFaint);
    txt(svgW - marginX, footY + 46,
        "github.com/honeycomb-modular/xylosome-hmi",
        fzDim, cFaint, "end");

    o << "</svg>\n";
    return svg;
}
