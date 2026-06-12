// SessionStore.cpp — see SessionStore.h.
#include "SessionStore.h"
#include "FolderWatcher.h"
#include "VipsEngine.h"
#include "XylodLink.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QCoreApplication>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSettings>
#include <QUuid>
#include <QDebug>

// Pairing window: a file may land long after its pass (manual CamExpert
// saves today; the capture agent will tighten this). A file pairs with the
// oldest ended, unpaired pass whose start precedes the file's mtime by no
// more than this.
static const qint64 kPairWindowMs = 30 * 60 * 1000;

SessionStore::SessionStore(XylodLink *link, QObject *parent)
    : QAbstractListModel(parent)
    , m_link(link)
    , m_watcher(new FolderWatcher(this))
{
    connect(m_link, &XylodLink::passStarted,  this, &SessionStore::onPassStarted);
    connect(m_link, &XylodLink::passEnded,    this, &SessionStore::onPassEnded);
    connect(m_link, &XylodLink::sequenceDone, this, &SessionStore::onSequenceDone);
    connect(m_link, &XylodLink::faulted,      this, &SessionStore::onFaulted);
    connect(m_link, &XylodLink::connectedChanged, this, [this] {
        if (!m_link->connected())
            onLinkDropped();
    });
    connect(m_watcher, &FolderWatcher::fileReady, this, &SessionStore::onFileReady);

    // Ingest engine in its own thread — UI never waits on a 1 GB TIFF.
    m_engine = new VipsEngine;
    m_engine->moveToThread(&m_engineThread);
    connect(&m_engineThread, &QThread::finished, m_engine, &QObject::deleteLater);
    connect(m_engine, &VipsEngine::ingested, this, &SessionStore::onIngested);
    connect(m_engine, &VipsEngine::failed, this,
            [](const QString &uuid, int pass, const QString &err) {
                qWarning() << "[sessions] ingest failed" << uuid << "pass" << pass << err;
            });
    m_engineThread.start();
    connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
        m_engineThread.quit();
        m_engineThread.wait(3000);
    });

    QSettings s;
    QString dir = s.value(QStringLiteral("capture/folder")).toString();
    if (qEnvironmentVariableIsSet("CAPTURE_DIR"))
        dir = qEnvironmentVariable("CAPTURE_DIR");
    if (!dir.isEmpty())
        setCaptureDir(dir);
}

// ── model plumbing ───────────────────────────────────────────────────────────

QHash<int, QByteArray> SessionStore::roleNames() const
{
    return {
        { SeqRole,         "seq" },
        { UuidRole,        "uuid" },
        { StateRole,       "sessionState" },
        { RatingRole,      "rating" },
        { RejectedRole,    "rejected" },
        { NoteRole,        "note" },
        { PassCountRole,   "passCount" },
        { PassFiltersRole, "passFilters" },
        { PassPairedRole,  "passPaired" },
        { PassDurationsRole, "passDurations" },
        { PassPreviewsRole, "passPreviews" },
        { PassClipsRole, "passClips" },
        { PassDimsRole, "passDims" },
        { PassTileBasesRole, "passTileBases" },
    };
}

QVariant SessionStore::data(const QModelIndex &idx, int role) const
{
    if (!idx.isValid() || idx.row() >= m_sessions.size())
        return {};
    const SessionRecord &s = m_sessions[idx.row()];
    switch (role) {
    case SeqRole:       return s.seq;
    case UuidRole:      return s.uuid;
    case StateRole:     return s.state;
    case RatingRole:    return s.rating;
    case RejectedRole:  return s.rejected;
    case NoteRole:      return s.note;
    case PassCountRole: return s.passes.size();
    case PassFiltersRole: {
        QStringList f;
        for (const PassRecord &p : s.passes) f << p.filter;
        return f;
    }
    case PassPairedRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes) v << !p.file.isEmpty();
        return v;
    }
    case PassDurationsRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes)
            v << (p.tEndMs >= 0 && p.tStartMs >= 0
                      ? (p.tEndMs - p.tStartMs) / 1000.0 : -1.0);
        return v;
    }
    case PassPreviewsRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes) v << p.preview;
        return v;
    }
    case PassClipsRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes)
            v << QVariantMap{ { QStringLiteral("black"), p.clipBlackPct },
                              { QStringLiteral("white"), p.clipWhitePct } };
        return v;
    }
    case PassDimsRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes)
            v << QVariantMap{ { QStringLiteral("w"), p.pxW },
                              { QStringLiteral("h"), p.pxH } };
        return v;
    }
    case PassTileBasesRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes)
            v << (p.preview.isEmpty()
                      ? QString()
                      : proxiesDir() + QLatin1Char('/') + s.uuid
                            + QStringLiteral("/pass_%1").arg(p.index));
        return v;
    }
    }
    return {};
}

void SessionStore::touchRow(int row)
{
    if (row < 0 || row >= m_sessions.size())
        return;
    save(m_sessions[row]);
    const QModelIndex i = index(row);
    emit dataChanged(i, i);
}

// ── capture folder ───────────────────────────────────────────────────────────

void SessionStore::setCaptureDir(const QString &dir)
{
    if (m_captureDir == dir)
        return;
    m_captureDir = dir;
    QSettings().setValue(QStringLiteral("capture/folder"), dir);

    beginResetModel();
    m_sessions.clear();
    m_unpaired.clear();
    m_nextSeq = 1;
    loadExisting();
    endResetModel();

    m_watcher->setDir(dir);   // full rescan announces every stable TIFF;
                              // already-paired ones are filtered in onFileReady
    emit captureDirChanged();
    emit countChanged();
    emit unpairedFilesChanged();
}

QString SessionStore::sidecarDir() const
{
    return m_captureDir + QStringLiteral("/.xylosome/sessions");
}

QString SessionStore::proxiesDir() const
{
    return m_captureDir + QStringLiteral("/.xylosome/proxies");
}

void SessionStore::enqueueIngest(const SessionRecord &s, const PassRecord &p)
{
    if (p.file.isEmpty())
        return;
    const QString abs = m_captureDir + QLatin1Char('/') + p.file;
    const QString proxyDir = proxiesDir() + QLatin1Char('/') + s.uuid;
    QMetaObject::invokeMethod(m_engine, "ingest", Qt::QueuedConnection,
                              Q_ARG(QString, s.uuid), Q_ARG(int, p.index),
                              Q_ARG(QString, abs), Q_ARG(QString, proxyDir));
}

void SessionStore::onIngested(const QString &sessionUuid, int passIndex,
                              const QString &previewAbs, int pxW, int pxH,
                              double clipBlackPct, double clipWhitePct,
                              const QVariantList &hist256)
{
    for (int row = 0; row < m_sessions.size(); ++row) {
        SessionRecord &s = m_sessions[row];
        if (s.uuid != sessionUuid)
            continue;
        for (PassRecord &p : s.passes) {
            if (p.index != passIndex)
                continue;
            p.preview = previewAbs;
            p.pxW = pxW;
            p.pxH = pxH;
            p.clipBlackPct = clipBlackPct;
            p.clipWhitePct = clipWhitePct;
            p.hist256.clear();
            p.hist256.reserve(hist256.size());
            for (const QVariant &v : hist256)
                p.hist256 << v.toDouble();
            touchRow(row);
            return;
        }
    }
}

void SessionStore::loadExisting()
{
    const QDir d(sidecarDir());
    const QStringList files = d.entryList({ QStringLiteral("*.json") }, QDir::Files, QDir::Name);
    for (const QString &name : files) {
        QFile f(d.absoluteFilePath(name));
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        if (o.value(QStringLiteral("schema")).toInt() != 1) {
            qWarning() << "[sessions] skipping sidecar with unknown schema:" << name;
            continue;
        }
        SessionRecord s;
        s.uuid          = o.value(QStringLiteral("uuid")).toString();
        s.seq           = o.value(QStringLiteral("seq")).toInt();
        s.createdWallMs = qint64(o.value(QStringLiteral("createdWallMs")).toDouble());
        s.state         = o.value(QStringLiteral("state")).toString();
        s.rating        = o.value(QStringLiteral("rating")).toInt();
        s.rejected      = o.value(QStringLiteral("rejected")).toBool();
        s.note          = o.value(QStringLiteral("note")).toString();
        const QJsonArray passes = o.value(QStringLiteral("passes")).toArray();
        for (const QJsonValue &pv : passes) {
            const QJsonObject po = pv.toObject();
            PassRecord p;
            p.index       = po.value(QStringLiteral("index")).toInt();
            p.filter      = po.value(QStringLiteral("filter")).toString();
            p.tStartMs    = qint64(po.value(QStringLiteral("tStartMs")).toDouble(-1));
            p.tEndMs      = qint64(po.value(QStringLiteral("tEndMs")).toDouble(-1));
            p.wallStartMs = qint64(po.value(QStringLiteral("wallStartMs")).toDouble(-1));
            p.wallEndMs   = qint64(po.value(QStringLiteral("wallEndMs")).toDouble(-1));
            p.file        = po.value(QStringLiteral("file")).toString();
            const QString prevRel = po.value(QStringLiteral("preview")).toString();
            if (!prevRel.isEmpty())
                p.preview = m_captureDir + QLatin1Char('/') + prevRel;
            p.pxW = po.value(QStringLiteral("pxW")).toInt();
            p.pxH = po.value(QStringLiteral("pxH")).toInt();
            p.clipBlackPct = po.value(QStringLiteral("clipBlackPct")).toDouble(-1);
            p.clipWhitePct = po.value(QStringLiteral("clipWhitePct")).toDouble(-1);
            for (const QJsonValue &hv : po.value(QStringLiteral("hist256")).toArray())
                p.hist256 << hv.toDouble();
            s.passes << p;
        }
        if (s.state == QLatin1String("live"))
            s.state = QStringLiteral("partial");   // we crashed or were closed mid-scan
        m_sessions << s;
        m_nextSeq = qMax(m_nextSeq, s.seq + 1);
    }
    qInfo() << "[sessions] loaded" << m_sessions.size() << "sidecars from" << sidecarDir();

    // Crash-safe ingest: paired but proxy missing/incomplete → re-run.
    for (const SessionRecord &s : m_sessions)
        for (const PassRecord &p : s.passes)
            if (!p.file.isEmpty()
                && (p.preview.isEmpty() || !QFile::exists(p.preview)))
                enqueueIngest(s, p);
}

void SessionStore::save(const SessionRecord &s) const
{
    if (m_captureDir.isEmpty())
        return;
    QDir().mkpath(sidecarDir());

    QJsonArray passes;
    for (const PassRecord &p : s.passes) {
        QJsonObject po{
            { QStringLiteral("index"),       p.index },
            { QStringLiteral("filter"),      p.filter },
            { QStringLiteral("tStartMs"),    double(p.tStartMs) },
            { QStringLiteral("tEndMs"),      double(p.tEndMs) },
            { QStringLiteral("wallStartMs"), double(p.wallStartMs) },
            { QStringLiteral("wallEndMs"),   double(p.wallEndMs) },
            { QStringLiteral("file"),        p.file },
        };
        if (!p.preview.isEmpty())
            po.insert(QStringLiteral("preview"),
                      QDir(m_captureDir).relativeFilePath(p.preview));
        if (p.pxW > 0) {
            po.insert(QStringLiteral("pxW"), p.pxW);
            po.insert(QStringLiteral("pxH"), p.pxH);
        }
        if (p.clipBlackPct >= 0) {
            po.insert(QStringLiteral("clipBlackPct"), p.clipBlackPct);
            po.insert(QStringLiteral("clipWhitePct"), p.clipWhitePct);
            QJsonArray h;
            for (double v : p.hist256) h.append(v);
            po.insert(QStringLiteral("hist256"), h);
        }
        passes.append(po);
    }
    const QJsonObject o{
        { QStringLiteral("schema"),        1 },
        { QStringLiteral("uuid"),          s.uuid },
        { QStringLiteral("seq"),           s.seq },
        { QStringLiteral("createdWallMs"), double(s.createdWallMs) },
        { QStringLiteral("state"),         s.state },
        { QStringLiteral("rating"),        s.rating },
        { QStringLiteral("rejected"),      s.rejected },
        { QStringLiteral("note"),          s.note },
        { QStringLiteral("passes"),        passes },
    };

    QFile f(sidecarDir() + QLatin1Char('/') + s.uuid + QStringLiteral(".json"));
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
    else
        qWarning() << "[sessions] cannot write sidecar for" << s.seq;
}

// ── session lifecycle (xylod events) ─────────────────────────────────────────

SessionRecord *SessionStore::liveSession()
{
    if (!m_sessions.isEmpty() && m_sessions.last().state == QLatin1String("live"))
        return &m_sessions.last();
    return nullptr;
}

int SessionStore::liveRow() const
{
    if (!m_sessions.isEmpty() && m_sessions.last().state == QLatin1String("live"))
        return m_sessions.size() - 1;
    return -1;
}

void SessionStore::beginSession(qint64 wallMs)
{
    beginInsertRows({}, m_sessions.size(), m_sessions.size());
    SessionRecord s;
    s.uuid = QUuid::createUuid().toString(QUuid::WithoutBraces);
    s.seq = m_nextSeq++;
    s.createdWallMs = wallMs;
    s.state = QStringLiteral("live");
    m_sessions << s;
    endInsertRows();
    emit countChanged();
    qInfo() << "[sessions] session" << s.seq << "started";
}

void SessionStore::onPassStarted(int pass, const QString &filter, qint64 tMs, qint64 wallMs)
{
    if (pass == 0 || !liveSession())
        beginSession(wallMs);
    SessionRecord *s = liveSession();
    PassRecord p;
    p.index = pass;
    p.filter = filter;
    p.tStartMs = tMs;
    p.wallStartMs = wallMs;
    s->passes << p;
    touchRow(m_sessions.size() - 1);
}

void SessionStore::onPassEnded(int pass, qint64 tMs, qint64 wallMs)
{
    SessionRecord *s = liveSession();
    if (!s || s->passes.isEmpty())
        return;
    PassRecord &p = s->passes.last();
    if (p.index == pass) {
        p.tEndMs = tMs;
        p.wallEndMs = wallMs;
    }
    touchRow(m_sessions.size() - 1);
    pairPendingFiles();
}

void SessionStore::onSequenceDone(int)
{
    closeLive(QStringLiteral("complete"));
}

void SessionStore::onFaulted(const QString &)
{
    closeLive(QStringLiteral("partial"));
}

void SessionStore::onLinkDropped()
{
    closeLive(QStringLiteral("partial"));
}

void SessionStore::closeLive(const QString &finalState)
{
    SessionRecord *s = liveSession();
    if (!s)
        return;
    s->state = finalState;
    touchRow(m_sessions.size() - 1);
    qInfo() << "[sessions] session" << s->seq << finalState
            << "(" << s->passes.size() << "passes )";
}

// ── file ⇄ pass pairing ──────────────────────────────────────────────────────

void SessionStore::onFileReady(const QString &absPath, qint64 mtimeMs)
{
    const QString rel = QDir(m_captureDir).relativeFilePath(absPath);

    // Already paired in a loaded sidecar? (startup rescan)
    for (const SessionRecord &s : m_sessions)
        for (const PassRecord &p : s.passes)
            if (p.file == rel)
                return;

    m_unpaired.append({ absPath, mtimeMs });
    emit unpairedFilesChanged();
    pairPendingFiles();
}

// Filter hint from the filename, e.g. "…_R.tif" → "R" ("" if none).
// The capture agent will name files this way; CamExpert saves may not —
// when absent, pairing falls back to pure FIFO.
static QString filterToken(const QString &fileName)
{
    static const QRegularExpression rx(
        QStringLiteral("[_-]([RGBC])\\.[^.]+$"));
    const auto m = rx.match(fileName);
    return m.hasMatch() ? m.captured(1) : QString();
}

void SessionStore::pairPendingFiles()
{
    // Oldest unpaired file → oldest ended, unpaired pass within the window.
    // FIFO on both sides keeps manual-save order predictable; anything that
    // can't pair stays visible as "unpaired" (importer fodder, never lost).
    // Two drift guards: a filter token in the filename must match the pass,
    // and once the stream pairs past a hole, the hole is sealed — a missed
    // file must not shift every later file back a slot.
    bool changed = false;
    for (int f = 0; f < m_unpaired.size(); ) {
        const qint64 mtime = m_unpaired[f].second;
        const QString token = filterToken(QFileInfo(m_unpaired[f].first).fileName());
        bool paired = false;
        for (int row = 0; row < m_sessions.size() && !paired; ++row) {
            SessionRecord &s = m_sessions[row];
            for (PassRecord &p : s.passes) {
                if (!p.file.isEmpty() || p.sealed || p.wallEndMs < 0)
                    continue;
                if (mtime < p.wallStartMs - 5000
                    || mtime - p.wallStartMs > kPairWindowMs)
                    continue;
                if (!token.isEmpty() && token != p.filter)
                    continue;
                p.file = QDir(m_captureDir).relativeFilePath(m_unpaired[f].first);
                qInfo() << "[sessions] paired" << p.file
                        << "→ session" << s.seq << "pass" << p.index << p.filter;
                enqueueIngest(s, p);
                touchRow(row);

                // Seal holes the stream has now moved past (earlier sessions
                // and earlier passes of this session).
                for (int r2 = 0; r2 <= row; ++r2) {
                    SessionRecord &s2 = m_sessions[r2];
                    for (PassRecord &p2 : s2.passes) {
                        if (r2 == row && p2.index >= p.index)
                            break;
                        if (p2.file.isEmpty() && !p2.sealed && p2.wallEndMs >= 0) {
                            p2.sealed = true;
                            qInfo() << "[sessions] sealed hole — session" << s2.seq
                                    << "pass" << p2.index << p2.filter
                                    << "(file never arrived)";
                        }
                    }
                }
                paired = true;
                changed = true;
                break;
            }
        }
        if (paired)
            m_unpaired.removeAt(f);
        else
            ++f;
    }
    if (changed)
        emit unpairedFilesChanged();
}

// ── judging (write-through, no Save) ─────────────────────────────────────────

void SessionStore::setRating(int row, int rating)
{
    if (row < 0 || row >= m_sessions.size())
        return;
    m_sessions[row].rating = qBound(0, rating, 5);
    touchRow(row);
}

void SessionStore::setRejected(int row, bool rejected)
{
    if (row < 0 || row >= m_sessions.size())
        return;
    m_sessions[row].rejected = rejected;
    touchRow(row);
}

void SessionStore::setNote(int row, const QString &note)
{
    if (row < 0 || row >= m_sessions.size())
        return;
    m_sessions[row].note = note;
    touchRow(row);
}
