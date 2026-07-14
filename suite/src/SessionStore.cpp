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
#include <QDateTime>
#include <QDirIterator>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSettings>
#include <QStorageInfo>
#include <QTimer>
#include <QUuid>
#include <QDebug>
#include <algorithm>

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

    // Disk gauge: refresh every 30 s and after every delete.
    auto *diskTimer = new QTimer(this);
    diskTimer->setInterval(30000);
    connect(diskTimer, &QTimer::timeout, this, &SessionStore::refreshDisk);
    diskTimer->start();

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
        { FileSeqRole,     "fileSeq" },
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
        { CreatedRole, "createdWallMs" },
        { MetaSvgRole, "metaSvg" },
        { MetaXRole, "metaX" },
        { MetaYRole, "metaY" },
        { MetaWRole, "metaW" },
        { MetaWhiteRole, "metaWhite" },
    };
}

QVariant SessionStore::data(const QModelIndex &idx, int role) const
{
    if (!idx.isValid() || idx.row() >= m_sessions.size())
        return {};
    const SessionRecord &s = m_sessions[idx.row()];
    switch (role) {
    case SeqRole:       return s.seq;
    case FileSeqRole: {
        // The name the reviewer judges by: the capture agent's scan_NNNN file
        // number, taken from the first paired TIFF. -1 until a file pairs, so
        // imageless sessions (e.g. an execute pushed during LIVE) show no
        // number instead of shifting every later session's count.
        static const QRegularExpression rx(QStringLiteral("scan_(\\d+)"));
        for (const PassRecord &p : s.passes) {
            if (p.file.isEmpty())
                continue;
            const auto m = rx.match(QFileInfo(p.file).fileName());
            if (m.hasMatch())
                return m.captured(1).toInt();
        }
        return -1;
    }
    case CreatedRole:   return s.createdWallMs;
    case MetaSvgRole:   return metaSvgPath(s);
    case MetaXRole:     return s.metaX;
    case MetaYRole:     return s.metaY;
    case MetaWRole:     return s.metaW;
    case MetaWhiteRole: return s.metaWhite;
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
    refreshDisk();
}

// ── disk gauge + deletion ────────────────────────────────────────────────────

static qint64 dirBytes(const QString &path)
{
    qint64 total = 0;
    QDirIterator it(path, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        total += it.fileInfo().size();
    }
    return total;
}

QString SessionStore::passAbsPath(const PassRecord &p) const
{
    return QDir::isAbsolutePath(p.file) ? p.file
                                        : m_captureDir + QLatin1Char('/') + p.file;
}

qint64 SessionStore::sessionBytes(const SessionRecord &s) const
{
    qint64 total = 0;
    for (const PassRecord &p : s.passes)
        if (!p.file.isEmpty())
            total += QFileInfo(passAbsPath(p)).size();
    total += dirBytes(proxiesDir() + QLatin1Char('/') + s.uuid);
    return total;
}

double SessionStore::sessionGB(int row) const
{
    if (row < 0 || row >= m_sessions.size())
        return 0;
    return sessionBytes(m_sessions[row]) / 1e9;
}

int SessionStore::rejectedCount() const
{
    int n = 0;
    for (const SessionRecord &s : m_sessions)
        if (s.rejected)
            ++n;
    return n;
}

void SessionStore::refreshDisk()
{
    if (m_captureDir.isEmpty())
        return;
    const QStorageInfo info(m_captureDir);
    m_freeGB = info.bytesAvailable() / 1e9;

    // "sessions remaining": free space / average size of complete sessions
    qint64 sum = 0;
    int n = 0;
    for (const SessionRecord &s : m_sessions) {
        if (s.state != QLatin1String("complete"))
            continue;
        sum += sessionBytes(s);
        if (++n >= 8)   // recent average is enough; don't walk everything
            break;
    }
    m_sessionsRemaining = (n > 0 && sum > 0)
                              ? int(info.bytesAvailable() / (sum / n)) : -1;
    emit diskChanged();
}

void SessionStore::appendDeletionLog(const SessionRecord &s, qint64 bytes) const
{
    QFile f(m_captureDir + QStringLiteral("/.xylosome/deletions.log"));
    QDir().mkpath(m_captureDir + QStringLiteral("/.xylosome"));
    if (!f.open(QIODevice::Append | QIODevice::Text))
        return;
    QStringList files;
    for (const PassRecord &p : s.passes)
        if (!p.file.isEmpty())
            files << p.file;
    f.write(QStringLiteral("%1 deleted session %2 (%3) %4 bytes — %5\n")
                .arg(QDateTime::currentDateTime().toString(Qt::ISODate))
                .arg(s.seq)
                .arg(s.uuid, QString::number(bytes), files.join(QLatin1Char(' ')))
                .toUtf8());
}

void SessionStore::deleteSession(int row)
{
    if (row < 0 || row >= m_sessions.size())
        return;
    SessionRecord s = m_sessions[row];
    if (s.state == QLatin1String("live"))
        return;   // never delete a session mid-scan

    const qint64 bytes = sessionBytes(s);

    beginRemoveRows({}, row, row);
    m_sessions.removeAt(row);
    endRemoveRows();

    // Capture-folder files are deleted; ARCHIVE originals (absolute paths,
    // imported) are never touched — the suite only ever owns its copies.
    for (const PassRecord &p : s.passes)
        if (!p.file.isEmpty() && !QDir::isAbsolutePath(p.file))
            QFile::remove(m_captureDir + QLatin1Char('/') + p.file);
    QDir(proxiesDir() + QLatin1Char('/') + s.uuid).removeRecursively();
    QFile::remove(sidecarDir() + QLatin1Char('/') + s.uuid + QStringLiteral(".json"));

    appendDeletionLog(s, bytes);
    qInfo() << "[sessions] permanently deleted session" << s.seq
            << "—" << bytes / 1e9 << "GB reclaimed";

    emit countChanged();
    refreshDisk();
    emit reclaimed(bytes / 1e9, 1);
}

void SessionStore::emptyQuarantine()
{
    double gb = 0;
    int n = 0;
    for (int row = m_sessions.size() - 1; row >= 0; --row) {
        if (!m_sessions[row].rejected)
            continue;
        const SessionRecord s = m_sessions[row];
        const qint64 bytes = sessionBytes(s);

        beginRemoveRows({}, row, row);
        m_sessions.removeAt(row);
        endRemoveRows();

        for (const PassRecord &p : s.passes)
            if (!p.file.isEmpty() && !QDir::isAbsolutePath(p.file))
                QFile::remove(m_captureDir + QLatin1Char('/') + p.file);
        QDir(proxiesDir() + QLatin1Char('/') + s.uuid).removeRecursively();
        QFile::remove(sidecarDir() + QLatin1Char('/') + s.uuid + QStringLiteral(".json"));
        appendDeletionLog(s, bytes);

        gb += bytes / 1e9;
        ++n;
    }
    if (n > 0) {
        qInfo() << "[sessions] quarantine emptied —" << n << "sessions,"
                << gb << "GB reclaimed";
        emit countChanged();
        refreshDisk();
        emit reclaimed(gb, n);
    }
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
    const QString abs = passAbsPath(p);
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
        s.metaSvg       = o.value(QStringLiteral("metaSvg")).toString();
        if (o.contains(QStringLiteral("metaX"))) {
            s.metaX = o.value(QStringLiteral("metaX")).toDouble();
            s.metaY = o.value(QStringLiteral("metaY")).toDouble();
            s.metaW = o.value(QStringLiteral("metaW")).toDouble();
            s.metaWhite = o.value(QStringLiteral("metaWhite")).toBool();
        }
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

    // Sidecars load in filename (uuid) order, which is neither capture order nor
    // the live append order — so the strip looked reshuffled after every
    // restart. Sort by capture time (seq as tie-break) so it always reads
    // oldest → newest, matching how sessions arrive live.
    std::sort(m_sessions.begin(), m_sessions.end(),
              [](const SessionRecord &a, const SessionRecord &b) {
                  if (a.createdWallMs != b.createdWallMs)
                      return a.createdWallMs < b.createdWallMs;
                  return a.seq < b.seq;
              });

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
    QJsonObject o{
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
    if (!s.metaSvg.isEmpty()) {
        o.insert(QStringLiteral("metaSvg"), s.metaSvg);
        o.insert(QStringLiteral("metaX"), s.metaX);
        o.insert(QStringLiteral("metaY"), s.metaY);
        o.insert(QStringLiteral("metaW"), s.metaW);
        o.insert(QStringLiteral("metaWhite"), s.metaWhite);
    }

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
    if (absPath.endsWith(QLatin1String(".svg"), Qt::CaseInsensitive)) {
        pairMetaSvg(absPath, mtimeMs);
        return;
    }
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

// ── importer (plan → Import / backfill) ──────────────────────────────────────

struct ArchiveGroup {
    QVector<QPair<QString, qint64>> files;   // absPath, mtimeMs
    QStringList filters;
};

static QVector<ArchiveGroup> buildProposals(const QString &dir)
{
    static const QStringList kOrder{ QStringLiteral("R"), QStringLiteral("G"),
                                     QStringLiteral("B"), QStringLiteral("C") };
    QFileInfoList entries =
        QDir(dir).entryInfoList({ QStringLiteral("*.tif"), QStringLiteral("*.tiff"),
                                  QStringLiteral("*.TIF"), QStringLiteral("*.TIFF") },
                                QDir::Files, QDir::Time | QDir::Reversed);

    QVector<ArchiveGroup> groups;
    qint64 lastMtime = -1;
    for (const QFileInfo &fi : entries) {
        const QString token = filterToken(fi.fileName());
        const qint64 mtime = fi.lastModified().toMSecsSinceEpoch();

        const bool gap = lastMtime > 0 && mtime - lastMtime > 10 * 60 * 1000;
        const bool full = !groups.isEmpty() && groups.last().files.size() >= 4;
        const bool restart = !groups.isEmpty() && !groups.last().files.isEmpty()
                             && token == QLatin1String("R");
        if (groups.isEmpty() || gap || full || restart)
            groups.append(ArchiveGroup());

        ArchiveGroup &g = groups.last();
        g.files.append({ fi.absoluteFilePath(), mtime });
        g.filters << (!token.isEmpty()
                          ? token
                          : kOrder.value(g.files.size() - 1, QStringLiteral("C")));
        lastMtime = mtime;
    }
    return groups;
}

QVariantList SessionStore::scanArchive(const QString &dir) const
{
    QVariantList out;
    for (const ArchiveGroup &g : buildProposals(dir)) {
        QStringList names;
        for (const auto &f : g.files)
            names << QFileInfo(f.first).fileName();
        out << QVariantMap{
            { QStringLiteral("start"),
              QDateTime::fromMSecsSinceEpoch(g.files.first().second)
                  .toString(QStringLiteral("yyyy-MM-dd hh:mm:ss")) },
            { QStringLiteral("files"), names },
            { QStringLiteral("filters"), g.filters },
        };
    }
    return out;
}

int SessionStore::importArchive(const QString &dir)
{
    const QVector<ArchiveGroup> groups = buildProposals(dir);
    if (groups.isEmpty() || m_captureDir.isEmpty())
        return 0;

    // Skip groups whose first file is already in a session (re-import safety).
    auto known = [this](const QString &abs) {
        for (const SessionRecord &s : m_sessions)
            for (const PassRecord &p : s.passes)
                if (passAbsPath(p) == abs)
                    return true;
        return false;
    };

    int imported = 0;
    for (const ArchiveGroup &g : groups) {
        if (g.files.isEmpty() || known(g.files.first().first))
            continue;

        beginInsertRows({}, m_sessions.size(), m_sessions.size());
        SessionRecord s;
        s.uuid = QUuid::createUuid().toString(QUuid::WithoutBraces);
        s.seq = m_nextSeq++;
        s.createdWallMs = g.files.first().second;
        s.state = g.files.size() == 4 ? QStringLiteral("complete")
                                      : QStringLiteral("partial");
        s.note = QStringLiteral("imported");
        for (int i = 0; i < g.files.size(); ++i) {
            PassRecord p;
            p.index = i;
            p.filter = g.filters.value(i);
            p.file = g.files[i].first;            // absolute — archive original
            p.wallStartMs = g.files[i].second;
            p.wallEndMs = g.files[i].second;
            s.passes << p;
        }
        m_sessions << s;
        endInsertRows();
        save(s);
        for (const PassRecord &p : s.passes)
            enqueueIngest(s, p);
        ++imported;
    }
    if (imported > 0) {
        // Pair any MetadataRecorder SVGs living beside the archive scans.
        const QFileInfoList svgs = QDir(dir).entryInfoList(
            { QStringLiteral("*.svg"), QStringLiteral("*.SVG") }, QDir::Files);
        for (const QFileInfo &fi : svgs)
            pairMetaSvg(fi.absoluteFilePath(),
                        fi.lastModified().toMSecsSinceEpoch());
        qInfo() << "[sessions] imported" << imported << "sessions from" << dir;
        emit countChanged();
        refreshDisk();
    }
    return imported;
}

// ── metadata SVG pairing (Pi MetadataRecorder export) ────────────────────────

void SessionStore::pairMetaSvg(const QString &absPath, qint64 mtimeMs)
{
    // Filename carries the trigger time: xylosome_YYYYMMDD_HHMMSS.svg.
    // Pair with the session whose start is nearest (Pi and suite clocks
    // are NTP'd on the cart LAN; ±10 min tolerance). Fallback: file mtime.
    qint64 t = mtimeMs;
    static const QRegularExpression rx(
        QStringLiteral("xylosome_(\\d{8})_(\\d{6})\\.svg$"));
    const auto m = rx.match(QFileInfo(absPath).fileName());
    if (m.hasMatch()) {
        const QDateTime dt = QDateTime::fromString(
            m.captured(1) + m.captured(2), QStringLiteral("yyyyMMddHHmmss"));
        if (dt.isValid())
            t = dt.toMSecsSinceEpoch();
    }

    int best = -1;
    qint64 bestDist = 10 * 60 * 1000;
    for (int row = 0; row < m_sessions.size(); ++row) {
        if (!m_sessions[row].metaSvg.isEmpty())
            continue;
        const qint64 d = qAbs(m_sessions[row].createdWallMs - t);
        if (d < bestDist) {
            bestDist = d;
            best = row;
        }
    }
    if (best < 0) {
        qInfo() << "[sessions] metadata svg unmatched:" << QFileInfo(absPath).fileName();
        return;
    }
    m_sessions[best].metaSvg =
        absPath.startsWith(m_captureDir + QLatin1Char('/'))
            ? QDir(m_captureDir).relativeFilePath(absPath)
            : absPath;   // archive svg — keep absolute, like archive tiffs
    qInfo() << "[sessions] metadata svg paired:" << QFileInfo(absPath).fileName()
            << "→ session" << m_sessions[best].seq;
    touchRow(best);
}

QString SessionStore::metaSvgPath(const SessionRecord &s) const
{
    if (s.metaSvg.isEmpty())
        return {};
    const QString orig = QDir::isAbsolutePath(s.metaSvg)
                             ? s.metaSvg
                             : m_captureDir + QLatin1Char('/') + s.metaSvg;
    if (!s.metaWhite)
        return orig;

    // White-line variant for dark scans: same artwork, tones inverted
    // (#000000→#FFFFFF, #555555→#AAAAAA). Derived file, cached in proxies.
    const QString cached = proxiesDir() + QLatin1Char('/') + s.uuid
                           + QStringLiteral("/meta_white.svg");
    if (!QFile::exists(cached)
        || QFileInfo(cached).lastModified() < QFileInfo(orig).lastModified()) {
        QFile in(orig);
        if (!in.open(QIODevice::ReadOnly))
            return orig;
        QString svg = QString::fromUtf8(in.readAll());
        svg.replace(QStringLiteral("#000000"), QStringLiteral("#FFFFFF"), Qt::CaseInsensitive);
        svg.replace(QStringLiteral("#555555"), QStringLiteral("#AAAAAA"), Qt::CaseInsensitive);
        QDir().mkpath(QFileInfo(cached).path());
        QFile out(cached);
        if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate))
            return orig;
        out.write(svg.toUtf8());
    }
    return cached;
}

void SessionStore::setMetaWhite(int row, bool white)
{
    if (row < 0 || row >= m_sessions.size() || m_sessions[row].metaWhite == white)
        return;
    m_sessions[row].metaWhite = white;
    touchRow(row);
}

void SessionStore::setMetaPlacement(int row, double x, double y, double w)
{
    if (row < 0 || row >= m_sessions.size())
        return;
    SessionRecord &s = m_sessions[row];
    s.metaX = qBound(-0.5, x, 1.0);
    s.metaY = qBound(-0.5, y, 1.0);
    s.metaW = qBound(0.02, w, 1.0);
    touchRow(row);
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
