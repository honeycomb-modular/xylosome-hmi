// MetadataRecorder.cpp — XYLOSOME metadata infuser implementation

#include "MetadataRecorder.h"
#include "MotorModel.h"

#include <QDir>
#include <QFile>
#include <QTextStream>
#include <QVariantMap>
#include <QtMath>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

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

// ── Real-time session API ─────────────────────────────────────────────────────

void MetadataRecorder::startSession()
{
    m_current             = TriggerRecord{};
    m_current.capturedAt  = QDateTime::currentDateTime();
    m_current.index       = m_triggers.size() + 1;
    m_current.nodes       = m_motor->nodes();
    m_current.boxW        = m_motor->seqBoxW();
    m_current.colorMode   = m_motor->colorMode();
}

void MetadataRecorder::setScanContext(double hand1Deg, double hand2Deg,
                                      double maxVelDegS, double minVelDegS,
                                      const QVariantList &profile)
{
    m_current.hand1Deg   = hand1Deg;
    m_current.hand2Deg   = hand2Deg;
    m_current.maxVelDegS = maxVelDegS;
    m_current.minVelDegS = minVelDegS;
    m_current.profile    = profile;
}

void MetadataRecorder::startPass(int pass)
{
    if (pass < 0 || pass > 3) return;
    m_current.passes[pass].tStart_ms = QDateTime::currentMSecsSinceEpoch();
}

void MetadataRecorder::endPass(int pass)
{
    if (pass < 0 || pass > 3) return;
    m_current.passes[pass].tEnd_ms = QDateTime::currentMSecsSinceEpoch();
}

void MetadataRecorder::commitSession()
{
    m_triggers.append(m_current);
    emit triggerCountChanged();
    emit lastSummaryChanged();

    // Auto-export SVG + JSON sidecar after every real execute session.
    exportSvg(kAutoExportDir);
    exportJson(kAutoExportDir);
}

// ── Simulate trigger (testing, no real execute needed) ────────────────────────

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

    // Filename from the session being exported — buildSvg() renders
    // m_triggers.last(), so name and content must agree (was .first(),
    // which overwrote earlier files with later sessions' content).
    const TriggerRecord &tr = m_triggers.last();
    QString filename = QString("xylosome_%1_%2.svg")
        .arg(tr.capturedAt.toString("yyyyMMdd"))
        .arg(tr.capturedAt.toString("HHmmss"));
    QString fullPath = dir.filePath(filename);

    QFile f(fullPath);
    if (!f.open(QFile::WriteOnly | QFile::Text)) return {};

    QTextStream ts(&f);
    ts << buildSvg();
    f.close();

    return fullPath;
}

// ── JSON sidecar — machine-readable session record ───────────────────────────
// Same stem as the SVG. Consumed by motosome to verify the commanded motion
// path (curve + profile + arc + real pass timing) against its own curves.

QString MetadataRecorder::buildJson() const
{
    if (m_triggers.isEmpty()) return {};
    const TriggerRecord &t = m_triggers.last();
    static const char *kChannels[4] = {"R", "G", "B", "C"};

    QJsonObject root;
    root[QStringLiteral("format")]      = QStringLiteral("xylosome-session");
    root[QStringLiteral("version")]     = 1;
    root[QStringLiteral("capturedAt")]  = t.capturedAt.toString(Qt::ISODateWithMs);
    root[QStringLiteral("index")]       = t.index;
    root[QStringLiteral("colorMode")]   = t.colorMode;     // 0 = color 4-pass, 1 = BW
    root[QStringLiteral("boxW")]        = t.boxW;
    root[QStringLiteral("arcStartDeg")] = t.hand1Deg;
    root[QStringLiteral("arcEndDeg")]   = t.hand2Deg;
    root[QStringLiteral("maxVelDegS")]  = t.maxVelDegS;
    root[QStringLiteral("minVelDegS")]  = t.minVelDegS;

    QJsonArray nodes;
    for (const QVariant &n : t.nodes) {
        const QVariantMap nm = n.toMap();
        nodes.append(QJsonObject{{QStringLiteral("nx"), nm.value(QStringLiteral("nx")).toDouble()},
                                 {QStringLiteral("ny"), nm.value(QStringLiteral("ny")).toDouble()}});
    }
    root[QStringLiteral("nodes")] = nodes;

    QJsonArray profile;
    for (const QVariant &v : t.profile) profile.append(v.toDouble());
    root[QStringLiteral("profile")] = profile;             // 0..1, as sent to the controller

    // Pass timing — absolute epoch ms + relative to first recorded pass start.
    qint64 t0 = -1;
    for (int i = 0; i < 4; i++)
        if (t.passes[i].tStart_ms >= 0) { t0 = t.passes[i].tStart_ms; break; }
    QJsonArray passes;
    for (int i = 0; i < 4; i++) {
        const PassRecord &p = t.passes[i];
        if (p.tStart_ms < 0) continue;                     // BW: only pass 0 present
        passes.append(QJsonObject{
            {QStringLiteral("pass"),        i},
            {QStringLiteral("channel"),     QString::fromLatin1(kChannels[i])},
            {QStringLiteral("tStartMs"),    p.tStart_ms},
            {QStringLiteral("tEndMs"),      p.tEnd_ms},
            {QStringLiteral("tStartRelMs"), p.tStart_ms - t0},
            {QStringLiteral("durationMs"),  p.duration_ms()},
        });
    }
    root[QStringLiteral("passes")] = passes;

    return QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Indented));
}

QString MetadataRecorder::exportJson(const QString &directory)
{
    if (m_triggers.isEmpty()) return {};

    QDir dir(directory);
    if (!dir.exists()) dir.mkpath(".");

    const TriggerRecord &tr = m_triggers.last();
    QString fullPath = dir.filePath(QString("xylosome_%1_%2.json")
        .arg(tr.capturedAt.toString("yyyyMMdd"))
        .arg(tr.capturedAt.toString("HHmmss")));

    QFile f(fullPath);
    if (!f.open(QFile::WriteOnly | QFile::Text)) return {};
    QTextStream ts(&f);
    ts << buildJson();
    f.close();

    return fullPath;
}

// ── SVG builder ───────────────────────────────────────────────────────────────
//
// One trigger per SVG. Black on transparent. Architectural drawing aesthetic.
// Layout: [header box — full width]
//         [timing table | curve]  ← same height, side by side
//         [parameters box — full width]
// No fills. 1px black borders. No decoration. Text sets the size; curve adapts.

QString MetadataRecorder::buildSvg() const
{
    if (m_triggers.isEmpty()) return {};

    // Export only the latest trigger.
    const TriggerRecord &tr = m_triggers.last();

    // ── Typography ────────────────────────────────────────────────────────────
    const QString fm   = "Courier New, Courier, monospace";
    const int     fz   = 13;       // single font size throughout
    const double  cw   = 7.8;      // character width at 13px Courier New (px)
    const int     lh   = 20;       // line height

    // ── Table column widths (chars × cw + 10px gap, except last col) ─────────
    // # | ch | t_start | t_end | duration | ms
    const int c_num  = 20;   // "1"   1 char
    const int c_ch   = 26;   // "R"   1 char + gap
    const int c_ts   = 84;   // "00:00.000"  9 chars
    const int c_te   = 84;   // "00:02.140"  9 chars
    const int c_dur  = 62;   // "2.140s"     6 chars
    const int c_ms   = 36;   // "2140"       4 chars  (last — no gap)

    const int tblInner = c_num + c_ch + c_ts + c_te + c_dur + c_ms; // 312
    const int pad      = 8;  // left/right padding inside any box
    const int tblW     = tblInner + pad * 2;   // 328

    // Table rows: 1 label + 4 data
    const int rows     = 5;
    const int tblInnerH = rows * lh;
    const int vpad     = 6;
    const int tblH     = tblInnerH + vpad * 2;    // 112

    // Curve box: same height as table, width chosen to feel square-ish
    const int crvW     = 240;
    const int crvH     = tblH;

    // Full content width = table + curve (no gap — shared border)
    const int svgW     = tblW + crvW;             // 568

    // Header (large title) and params (two lines)
    const int fzLg     = 20;                       // XYLOSOME_01 title font size
    const int fzSm     = 11;                       // small font for params rows
    const int hdrH     = 44;                       // tall enough for 20px title
    const int prmH     = 44;                       // tall enough for two 11px lines

    // Layout Y positions (no margins — boxes tile edge to edge)
    const int yHdr     = 0;
    const int yMain    = hdrH;
    const int yPrm     = hdrH + tblH;
    const int svgH     = hdrH + tblH + prmH;      // 200

    // ── Colours ───────────────────────────────────────────────────────────────
    const QString cBlk = "#000000";
    const QString cDim = "#555555";

    const char *chN[4] = { "R", "G", "B", "C" };

    qint64 t0 = tr.passes[0].tStart_ms >= 0
                ? tr.passes[0].tStart_ms
                : tr.capturedAt.toMSecsSinceEpoch();

    double aspect = double(tr.boxW) / 270.0;
    int    lines  = qMax(1, qRound(aspect * 8000.0));

    // ── SVG root — transparent background ────────────────────────────────────
    QString svg;
    QTextStream o(&svg);

    o << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    o << QString("<svg xmlns=\"http://www.w3.org/2000/svg\" "
                 "width=\"%1\" height=\"%2\" viewBox=\"0 0 %1 %2\">\n")
         .arg(svgW).arg(svgH);

    // ── Helpers ───────────────────────────────────────────────────────────────

    // text — baseline y
    auto txt = [&](int x, int y, const QString &s,
                   const QString &fill  = "#000000",
                   const QString &anchor = "start") {
        o << QString("<text x=\"%1\" y=\"%2\" font-family=\"%3\" font-size=\"%4\" "
                     "fill=\"%5\" text-anchor=\"%6\">%7</text>\n")
             .arg(x).arg(y).arg(fm).arg(fz).arg(fill).arg(anchor)
             .arg(s.toHtmlEscaped());
    };

    // box: no fill, 1px black stroke
    auto box = [&](int x, int y, int w, int h) {
        o << QString("<rect x=\"%1\" y=\"%2\" width=\"%3\" height=\"%4\" "
                     "fill=\"none\" stroke=\"%5\" stroke-width=\"1\"/>\n")
             .arg(x).arg(y).arg(w).arg(h).arg(cBlk);
    };

    // horizontal rule
    auto rule = [&](int x, int y, int w) {
        o << QString("<line x1=\"%1\" y1=\"%2\" x2=\"%3\" y2=\"%2\" "
                     "stroke=\"%4\" stroke-width=\"0.5\"/>\n")
             .arg(x).arg(y).arg(x + w).arg(cDim);
    };

    // ── 1. Header box (full width) ────────────────────────────────────────────
    box(0, yHdr, svgW, hdrH);

    // Left: fixed product label at large size, vertically centred
    o << QString("<text x=\"%1\" y=\"%2\" font-family=\"%3\" font-size=\"%4\" "
                 "letter-spacing=\"1\" fill=\"%5\" text-anchor=\"start\">XYLOSOME_01</text>\n")
         .arg(pad).arg(yHdr + 29).arg(fm).arg(fzLg).arg(cBlk);

    // Right: date / time  — same baseline
    txt(svgW - pad, yHdr + 29,
        tr.capturedAt.toString("yyyy-MM-dd  hh:mm:ss.zzz"),
        cDim, "end");

    // ── 2a. Timing table box (left column) ───────────────────────────────────
    box(0, yMain, tblW, tblH);

    // Column x offsets (absolute)
    const int x0 = pad;
    const int x1 = pad + c_num;
    const int x2 = pad + c_num + c_ch;
    const int x3 = pad + c_num + c_ch + c_ts;
    const int x4 = pad + c_num + c_ch + c_ts + c_te;
    const int x5 = pad + c_num + c_ch + c_ts + c_te + c_dur;

    // Label row
    const int lblY = yMain + vpad + fz;
    txt(x0, lblY, "#",        cDim);
    txt(x1, lblY, "ch",       cDim);
    txt(x2, lblY, "t_start",  cDim);
    txt(x3, lblY, "t_end",    cDim);
    txt(x4, lblY, "duration", cDim);
    txt(x5, lblY, "ms",       cDim);

    rule(0, yMain + vpad + fz + 4, tblW);

    // Data rows
    for (int pi = 0; pi < 4; pi++) {
        const PassRecord &pr = tr.passes[pi];
        const int ry = yMain + vpad + fz + 4 + (pi + 1) * lh;

        QString tsStr  = pr.tStart_ms >= 0 ? formatMsRelative(pr.tStart_ms, t0) : "--:--.---";
        QString teStr  = pr.tEnd_ms   >= 0 ? formatMsRelative(pr.tEnd_ms,   t0) : "--:--.---";
        QString durStr = formatDuration(pr.duration_ms());
        QString msStr  = pr.duration_ms() >= 0 ? QString::number(pr.duration_ms()) : "---";

        txt(x0, ry, QString::number(pi + 1), cDim);
        txt(x1, ry, chN[pi],  cBlk);
        txt(x2, ry, tsStr,    cBlk);
        txt(x3, ry, teStr,    cBlk);
        txt(x4, ry, durStr,   cBlk);
        txt(x5, ry, msStr,    cDim);

        if (pi < 3) rule(0, ry + 4, tblW);
    }

    // ── 2b. Curve box (right column, same height as table) ───────────────────
    // Shares left border with table's right border (no gap).
    box(tblW, yMain, crvW, crvH);

    // Inner plot area
    const int gPad = 10;
    const int giX  = tblW + gPad;
    const int giY  = yMain + gPad;
    const int giW  = crvW - gPad * 2;
    const int giH  = crvH - gPad * 2;

    // Zero axis — dashed, horizontal centre
    const int zy = giY + giH / 2;
    o << QString("<line x1=\"%1\" y1=\"%2\" x2=\"%3\" y2=\"%2\" "
                 "stroke=\"%4\" stroke-width=\"0.5\" stroke-dasharray=\"3,4\"/>\n")
         .arg(giX).arg(zy).arg(giX + giW).arg(cDim);

    // Catmull-Rom curve — single black line
    QVector<QPointF> rawPts;
    for (const QVariant &v : tr.nodes) {
        QVariantMap nm = v.toMap();
        rawPts.append(QPointF(nm.value("nx", 0.0).toDouble() * giW,
                              nm.value("ny", 0.5).toDouble() * giH));
    }
    if (rawPts.size() >= 2) {
        QVector<QPointF> curve = evalCatmullRom(rawPts, 32);
        if (!curve.isEmpty()) {
            o << "<polyline fill=\"none\" stroke=\"" << cBlk
              << "\" stroke-width=\"1\" stroke-linejoin=\"round\" points=\"";
            for (const QPointF &pt : curve)
                o << QString("%1,%2 ").arg(giX + pt.x(), 0, 'f', 1)
                                     .arg(giY + pt.y(), 0, 'f', 1);
            o << "\"/>\n";
        }
    }

    // ── 3. Parameters box (full width, two stacked lines at fzSm) ───────────
    box(0, yPrm, svgW, prmH);

    // Shared small-text emitter (always cDim, always fzSm)
    auto txtSm = [&](int x, int y, const QString &s, const QString &anchor = "start") {
        o << QString("<text x=\"%1\" y=\"%2\" font-family=\"%3\" font-size=\"%4\" "
                     "fill=\"%5\" text-anchor=\"%6\">%7</text>\n")
             .arg(x).arg(y).arg(fm).arg(fzSm).arg(cDim).arg(anchor)
             .arg(s.toHtmlEscaped());
    };

    // Line 1 — node coordinates
    QString nodeStr = "n:";
    for (const QVariant &v : tr.nodes) {
        QVariantMap nm = v.toMap();
        nodeStr += QString(" (%1,%2)")
            .arg(nm.value("nx", 0.0).toDouble(), 0, 'f', 2)
            .arg(nm.value("ny", 0.0).toDouble(), 0, 'f', 2);
    }
    txtSm(pad, yPrm + vpad + fzSm, nodeStr);

    // Line 2 — technical summary
    QString techStr = QString("box_w %1  aspect %2  lines %3")
        .arg(tr.boxW)
        .arg(aspect, 0, 'f', 3)
        .arg(lines);
    txtSm(pad, yPrm + vpad + fzSm + 16, techStr);

    o << "</svg>\n";
    return svg;
}
