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
#include <QStandardPaths>
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
        { PassDiscardedRole, "passDiscarded" },
        { MergedRole, "merged" },
        { PassMediansRole, "passMedians" },
        { CreatedRole, "createdWallMs" },
        { MetaSvgRole, "metaSvg" },
        { MetaXRole, "metaX" },
        { MetaYRole, "metaY" },
        { MetaWRole, "metaW" },
        { MetaWhiteRole, "metaWhite" },
        { HdrSetRole, "hdrSet" },
        { HdrLabelRole, "hdrLabel" },
        { HdrIndexRole, "hdrIndex" },
        { HdrCountRole, "hdrCount" },
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
    case HdrSetRole:    return s.hdrSet;
    case HdrIndexRole:  return s.hdrIndex;
    case HdrCountRole:  return s.hdrCount;
    case HdrLabelRole: {
        if (s.hdrSet.isEmpty())
            return QString();
        // Whole stops are the common case and read better without decimals.
        const double ev = s.hdrEv;
        const QString n = qFuzzyCompare(ev, qRound(ev)) ? QString::number(qRound(ev))
                                                        : QString::number(ev, 'f', 1);
        return (ev > 0 ? QStringLiteral("+") : QString()) + n + QStringLiteral(" EV");
    }
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
    case PassDiscardedRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes) v << p.discarded;
        return v;
    }
    case MergedRole: {
        for (const PassRecord &p : s.passes)
            if (p.filter == QLatin1String("RGB") && !p.file.isEmpty())
                return true;
        return false;
    }
    case PassMediansRole: {
        QVariantList v;
        for (const PassRecord &p : s.passes) {
            QVariantList m;
            for (double d : p.medians) m << d;
            v << QVariant(m);
        }
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
                              const QVariantList &hist256, const QVariantList &bandMedians)
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
            p.medians.clear();
            for (const QVariant &v : bandMedians)
                p.medians << v.toDouble();
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
        s.hdrSet        = o.value(QStringLiteral("hdrSet")).toString();
        s.hdrIndex      = o.value(QStringLiteral("hdrIndex")).toInt();
        s.hdrCount      = o.value(QStringLiteral("hdrCount")).toInt();
        s.hdrEv         = o.value(QStringLiteral("hdrEv")).toDouble();
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
            p.discarded   = po.value(QStringLiteral("discarded")).toBool();
            p.sealed      = p.discarded;   // never pair a stray file into a discarded slot
            const QString prevRel = po.value(QStringLiteral("preview")).toString();
            if (!prevRel.isEmpty())
                p.preview = m_captureDir + QLatin1Char('/') + prevRel;
            p.pxW = po.value(QStringLiteral("pxW")).toInt();
            p.pxH = po.value(QStringLiteral("pxH")).toInt();
            p.clipBlackPct = po.value(QStringLiteral("clipBlackPct")).toDouble(-1);
            p.clipWhitePct = po.value(QStringLiteral("clipWhitePct")).toDouble(-1);
            for (const QJsonValue &hv : po.value(QStringLiteral("hist256")).toArray())
                p.hist256 << hv.toDouble();
            for (const QJsonValue &mv : po.value(QStringLiteral("medians")).toArray())
                p.medians << mv.toDouble();
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
                && (p.preview.isEmpty() || !QFile::exists(p.preview)
                    || (p.filter == QLatin1String("RGB") && p.medians.isEmpty())))
                enqueueIngest(s, p);   // merged before medians existed: once more
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
        if (p.discarded)
            po.insert(QStringLiteral("discarded"), true);
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
        if (!p.medians.isEmpty()) {
            QJsonArray m;
            for (double v : p.medians) m.append(v);
            po.insert(QStringLiteral("medians"), m);
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
    // Optional keys, deliberately NOT a schema bump: loadExisting() drops any
    // sidecar whose schema is not 1, so raising it would make every existing
    // session vanish from an older build. Absent = not a bracket set.
    if (!s.hdrSet.isEmpty()) {
        o.insert(QStringLiteral("hdrSet"), s.hdrSet);
        o.insert(QStringLiteral("hdrIndex"), s.hdrIndex);
        o.insert(QStringLiteral("hdrCount"), s.hdrCount);
        o.insert(QStringLiteral("hdrEv"), s.hdrEv);
    }
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

// Parse the job tag xylod echoes back on pass_start. The format is a client
// convention (PROTOCOL.md ▸ execute ▸ tag): hdr:<setId>:<n>/<total>:<ev>.
// Anything that does not match is ignored rather than guessed at — an untagged
// scan, or a tag from some later mode, is simply not a bracket set.
static void parseHdrTag(const QString &tag, SessionRecord *s)
{
    static const QRegularExpression rx(
        QStringLiteral(R"(^hdr:([\w.+-]+):(\d+)/(\d+):([-+]?[\d.]+)$)"));
    const auto m = rx.match(tag);
    if (!m.hasMatch())
        return;
    s->hdrSet   = m.captured(1);
    s->hdrIndex = m.captured(2).toInt();
    s->hdrCount = m.captured(3).toInt();
    s->hdrEv    = m.captured(4).toDouble();
}

void SessionStore::onPassStarted(int pass, const QString &filter, qint64 tMs, qint64 wallMs,
                                 const QString &tag)
{
    if (pass == 0 || !liveSession())
        beginSession(wallMs);
    SessionRecord *s = liveSession();
    if (!tag.isEmpty() && s->hdrSet.isEmpty())
        parseHdrTag(tag, s);
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
    // Each unpaired file → the unpaired pass that ended MOST RECENTLY before
    // the file appeared (within the window). The capture agent writes a pass's
    // file seconds after its pass_end, so that pass is the one the file
    // belongs to. It used to be the OLDEST unfilled pass in the window, which
    // sent a fresh scan's files into an earlier session whose own files never
    // arrived (agent down, 2026-10-17: scan_2230 landed in session 2113).
    // Anything that can't pair stays visible as "unpaired" (importer fodder,
    // never lost). Two drift guards: a filter token in the filename must match
    // the pass, and once the stream pairs past a hole, the hole is sealed — a
    // missed file must not shift every later file back a slot.
    bool changed = false;
    for (int f = 0; f < m_unpaired.size(); ) {
        const qint64 mtime = m_unpaired[f].second;
        const QString token = filterToken(QFileInfo(m_unpaired[f].first).fileName());
        bool paired = false;
        int bestRow = -1, bestPass = -1;
        qint64 bestEnd = -1;
        for (int row = 0; row < m_sessions.size(); ++row) {
            const SessionRecord &s = m_sessions[row];
            for (int i = 0; i < s.passes.size(); ++i) {
                const PassRecord &p = s.passes[i];
                if (!p.file.isEmpty() || p.sealed || p.wallEndMs < 0)
                    continue;
                if (mtime < p.wallStartMs - 5000
                    || mtime - p.wallStartMs > kPairWindowMs)
                    continue;
                if (!token.isEmpty() && token != p.filter)
                    continue;
                // Prefer the pass that ended last before the file was written;
                // a pass that ended after it (file written early, clock skew)
                // still qualifies but ranks below any that ended before.
                const qint64 end = p.wallEndMs <= mtime + 5000 ? p.wallEndMs
                                                               : mtime - (p.wallEndMs - mtime);
                if (end > bestEnd) { bestEnd = end; bestRow = row; bestPass = i; }
            }
        }
        if (bestRow >= 0) {
            const int row = bestRow;
            SessionRecord &s = m_sessions[row];
            {
                PassRecord &p = s.passes[bestPass];
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

// ── HDR bracket sets ─────────────────────────────────────────────────────────

QVariantList SessionStore::hdrSetRows(int row) const
{
    QVariantList out;
    if (row < 0 || row >= m_sessions.size() || m_sessions[row].hdrSet.isEmpty())
        return out;
    const QString set = m_sessions[row].hdrSet;
    QVector<QPair<int, int>> found;          // bracket number, row
    for (int i = 0; i < m_sessions.size(); ++i)
        if (m_sessions[i].hdrSet == set)
            found << qMakePair(m_sessions[i].hdrIndex, i);
    std::sort(found.begin(), found.end());
    for (const auto &f : found)
        out << f.second;
    return out;
}

// Packaged next to the exe, or in the source tree when running from build-suite.
// Looked up rather than assumed, because the working directory differs between
// the two and a wrong guess only shows up at the moment you press merge.
static QString toolPath(const QString &name)
{
    const QString exe = QCoreApplication::applicationDirPath();
    for (const QString &t : { exe + QStringLiteral("/tools/") + name,
                              exe + QStringLiteral("/../suite/tools/") + name,
                              exe + QStringLiteral("/../capture/") + name })
        if (QFile::exists(t))
            return QFileInfo(t).absoluteFilePath();
    return {};
}

static QString mergeToolPath() { return toolPath(QStringLiteral("hdr_merge.py")); }

// The interpreter the merge tools run under. start-suite.ps1 puts msys2's bin
// first on PATH for the Qt/vips DLLs, and msys2 ships its own python without
// numpy/cv2/tifffile — so a bare "python" found the wrong one (2026-10-17:
// "No module named 'cv2'"). The Windows launcher resolves the real install.
// merge/python in the settings overrides it.
static QStringList pythonCommand()
{
    const QString custom = QSettings().value(QStringLiteral("merge/python")).toString();
    if (!custom.isEmpty())
        return { custom };
    if (!QStandardPaths::findExecutable(QStringLiteral("py")).isEmpty())
        return { QStringLiteral("py"), QStringLiteral("-3") };
    return { QStringLiteral("python") };
}

void SessionStore::mergeHdrSet(int row)
{
    if (m_merge) {
        emit hdrMergeFinished(false, QStringLiteral("a merge is already running"));
        return;
    }
    const QVariantList rows = hdrSetRows(row);
    if (rows.size() < 2) {
        emit hdrMergeFinished(false, QStringLiteral("not a bracket set"));
        return;
    }
    // One image per bracket — a bracket is a single-pass execute by construction.
    QStringList files;
    for (const QVariant &r : rows) {
        const SessionRecord &s = m_sessions[r.toInt()];
        QString f;
        for (const PassRecord &p : s.passes)
            if (!p.file.isEmpty()) { f = passAbsPath(p); break; }
        if (f.isEmpty()) {
            emit hdrMergeFinished(false, QStringLiteral("bracket %1 has no image yet")
                                             .arg(s.hdrIndex));
            return;
        }
        files << QDir::toNativeSeparators(f);
    }
    const int want = m_sessions[rows.first().toInt()].hdrCount;
    if (want > 0 && files.size() != want) {
        emit hdrMergeFinished(false, QStringLiteral("set is incomplete — %1 of %2 brackets")
                                         .arg(files.size()).arg(want));
        return;
    }
    const QString tool = mergeToolPath();
    if (tool.isEmpty()) {
        emit hdrMergeFinished(false, QStringLiteral("hdr_merge.py not found beside the app"));
        return;
    }
    // Beside the capture folder, never inside it: that folder is the agent's
    // output and this model's own scan target, so an 800 MB float TIFF landing
    // there would be picked up and paired as though it were a scan.
    const QString outDir = QDir::cleanPath(
        QDir(m_captureDir).absoluteFilePath(QStringLiteral("../hdr-merge")));

    m_mergeOut.clear();
    m_mergeUuid.clear();
    m_merge = new QProcess(this);
    QStringList py = pythonCommand();
    m_merge->setProgram(py.takeFirst());
    m_merge->setArguments(py + QStringList{ tool } + files
                          + QStringList{ QStringLiteral("--out"),
                                         QDir::toNativeSeparators(outDir) });
    m_merge->setProcessChannelMode(QProcess::MergedChannels);

    connect(m_merge, &QProcess::readyReadStandardOutput, this, [this] {
        m_mergeOut += QString::fromLocal8Bit(m_merge->readAllStandardOutput());
    });
    // Cleanup runs from exactly one of these two paths: a process that fails to
    // start never emits finished().
    const auto done = [this](bool ok, const QString &msg) {
        if (!m_merge)
            return;
        m_merge->deleteLater();
        m_merge = nullptr;
        emit hdrMergeBusyChanged();
        emit hdrMergeFinished(ok, msg);
    };
    connect(m_merge, &QProcess::errorOccurred, this, [this, done](QProcess::ProcessError e) {
        done(false, e == QProcess::FailedToStart
                        ? QStringLiteral("could not run python — is it on PATH?")
                        : QStringLiteral("merge process error"));
    });
    connect(m_merge, &QProcess::finished, this,
            [this, done](int code, QProcess::ExitStatus st) {
        m_mergeOut += QString::fromLocal8Bit(m_merge->readAllStandardOutput());
        if (st != QProcess::NormalExit || code != 0) {
            const QStringList lines = m_mergeOut.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
            done(false, lines.isEmpty() ? QStringLiteral("merge failed")
                                        : lines.last().trimmed());
            return;
        }
        // The tool prints the path it wrote; trusting that beats recomputing its
        // naming rule here and quietly disagreeing with it.
        QString wrote;
        for (const QString &l : m_mergeOut.split(QLatin1Char('\n')))
            if (l.startsWith(QLatin1String("wrote ")))
                wrote = l.mid(6).section(QStringLiteral("  ("), 0, 0).trimmed();
        qInfo().noquote() << "[hdr]" << m_mergeOut.trimmed();
        done(true, wrote.isEmpty() ? QStringLiteral("merge complete") : wrote);
    });

    emit hdrMergeStarted(files.size(), outDir);
    emit hdrMergeBusyChanged();
    qInfo() << "[hdr] merging" << files.size() << "brackets ->" << outDir;
    m_merge->start();
}

// ── colour merge (R/G/B passes → one 16-bit RGB TIFF) ────────────────────────

void SessionStore::mergeColour(int row, bool discardChannels)
{
    if (m_merge) {
        emit colourMergeFinished(false, QStringLiteral("a merge is already running"));
        return;
    }
    if (row < 0 || row >= m_sessions.size())
        return;
    const SessionRecord &s = m_sessions[row];
    if (s.state == QLatin1String("live")) {
        emit colourMergeFinished(false, QStringLiteral("session is still scanning"));
        return;
    }
    QString files[3];
    for (const PassRecord &p : s.passes) {
        const int k = p.filter == QLatin1String("R") ? 0
                    : p.filter == QLatin1String("G") ? 1
                    : p.filter == QLatin1String("B") ? 2 : -1;
        if (k >= 0 && !p.file.isEmpty() && files[k].isEmpty())
            files[k] = passAbsPath(p);
    }
    for (int k = 0; k < 3; ++k)
        if (files[k].isEmpty()) {
            emit colourMergeFinished(false, QStringLiteral("no %1 pass image")
                                                .arg(QLatin1Char("RGB"[k])));
            return;
        }
    const QString tool = toolPath(QStringLiteral("rgb_merge.py"));
    if (tool.isEmpty()) {
        emit colourMergeFinished(false, QStringLiteral("rgb_merge.py not found beside the app"));
        return;
    }
    // A subfolder of the capture folder: the watcher lists only the top level,
    // so the result is never mistaken for a scan, and the session owns it like
    // any pass (deleted with the session, counted in its size).
    const int fseq = data(index(row), FileSeqRole).toInt();
    const QString outRel = QStringLiteral("merged/scan_%1_RGB16.tif")
        .arg(fseq >= 0 ? QString::number(fseq).rightJustified(4, QLatin1Char('0'))
                       : s.uuid.left(8));
    QDir().mkpath(m_captureDir + QStringLiteral("/merged"));
    const QString outAbs = m_captureDir + QLatin1Char('/') + outRel;

    m_mergeOut.clear();
    m_mergeUuid = s.uuid;
    m_mergeDiscard = discardChannels;
    m_merge = new QProcess(this);
    QStringList py = pythonCommand();
    m_merge->setProgram(py.takeFirst());
    m_merge->setArguments(py + QStringList{ QStringLiteral("-I"), tool, QStringLiteral("--files"),
                                       QDir::toNativeSeparators(files[0]),
                                       QDir::toNativeSeparators(files[1]),
                                       QDir::toNativeSeparators(files[2]),
                                       QStringLiteral("--out"), QDir::toNativeSeparators(outAbs),
                                       QStringLiteral("--align"), QStringLiteral("--denoise-blue") });
    m_merge->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_merge, &QProcess::readyReadStandardOutput, this, [this] {
        m_mergeOut += QString::fromLocal8Bit(m_merge->readAllStandardOutput());
    });
    const auto done = [this](bool ok, const QString &msg) {
        if (!m_merge)
            return;
        m_merge->deleteLater();
        m_merge = nullptr;
        m_mergeUuid.clear();
        emit hdrMergeBusyChanged();
        emit colourMergeFinished(ok, msg);
    };
    connect(m_merge, &QProcess::errorOccurred, this, [this, done](QProcess::ProcessError e) {
        done(false, e == QProcess::FailedToStart
                        ? QStringLiteral("could not run python — is it on PATH?")
                        : QStringLiteral("merge process error"));
    });
    const QString uuid = s.uuid;
    const bool discard = discardChannels;
    connect(m_merge, &QProcess::finished, this,
            [this, done, uuid, outRel, discard](int code, QProcess::ExitStatus st) {
        m_mergeOut += QString::fromLocal8Bit(m_merge->readAllStandardOutput());
        qInfo().noquote() << "[rgb]" << m_mergeOut.trimmed();
        if (st != QProcess::NormalExit || code != 0
            || !QFile::exists(m_captureDir + QLatin1Char('/') + outRel)) {
            const QStringList lines = m_mergeOut.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
            done(false, lines.isEmpty() ? QStringLiteral("merge failed")
                                        : lines.last().trimmed());
            return;
        }
        colourMerged(uuid, outRel, discard);
        done(true, outRel);
    });
    emit colourMergeStarted(fseq >= 0 ? fseq : s.seq);
    emit hdrMergeBusyChanged();
    qInfo() << "[rgb] merging session" << s.seq << "->" << outRel
            << (discardChannels ? "(channels will be discarded)" : "");
    m_merge->start();
}

void SessionStore::colourMerged(const QString &uuid, const QString &outRel, bool discard)
{
    for (int row = 0; row < m_sessions.size(); ++row) {
        SessionRecord &s = m_sessions[row];
        if (s.uuid != uuid)
            continue;
        const QString proxy = proxiesDir() + QLatin1Char('/') + s.uuid;
        // One RGB pass per session: a re-merge replaces it (new proxies follow).
        int slot = -1, maxIdx = -1;
        for (int i = 0; i < s.passes.size(); ++i) {
            maxIdx = qMax(maxIdx, s.passes[i].index);
            if (s.passes[i].filter == QLatin1String("RGB"))
                slot = i;
        }
        if (slot < 0) {
            PassRecord p;
            p.index = maxIdx + 1;
            p.filter = QStringLiteral("RGB");
            s.passes << p;
            slot = s.passes.size() - 1;
        }
        PassRecord &m = s.passes[slot];
        m.file = outRel;
        m.preview.clear();
        m.pxW = m.pxH = 0;
        m.clipBlackPct = m.clipWhitePct = -1;
        m.hist256.clear();
        m.wallStartMs = m.wallEndMs = QDateTime::currentMSecsSinceEpoch();
        if (discard) {
            for (PassRecord &p : s.passes) {
                if (p.filter != QLatin1String("R") && p.filter != QLatin1String("G")
                    && p.filter != QLatin1String("B"))
                    continue;
                if (p.file.isEmpty())
                    continue;
                // Capture-folder files only; archive originals (absolute) stay.
                if (!QDir::isAbsolutePath(p.file))
                    QFile::remove(m_captureDir + QLatin1Char('/') + p.file);
                QDir(proxy + QStringLiteral("/pass_%1_files").arg(p.index)).removeRecursively();
                QFile::remove(proxy + QStringLiteral("/pass_%1.dzi").arg(p.index));
                QFile::remove(p.preview);
                qInfo() << "[rgb] discarded" << p.file << "(session" << s.seq << ")";
                p.file.clear();
                p.preview.clear();
                p.discarded = true;
                p.sealed = true;
            }
        }
        touchRow(row);
        enqueueIngest(s, m);
        refreshDisk();
        return;
    }
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
    // rejectedCount is exposed with NOTIFY countChanged; without this the
    // header's "N rejected" and the quarantine dialog keep a stale number.
    emit countChanged();
}

int SessionStore::setRejectedRange(int fromRow, int toRow, bool rejected)
{
    if (fromRow > toRow)
        std::swap(fromRow, toRow);
    fromRow = qMax(0, fromRow);
    toRow   = qMin(toRow, int(m_sessions.size()) - 1);

    int n = 0;
    for (int row = fromRow; row <= toRow; ++row) {
        // A scan still being written is not a judgement candidate — and
        // emptyQuarantine() does not re-check, so keeping it out of quarantine
        // here is what stops a live scan being deleted underneath itself.
        if (m_sessions[row].state == QLatin1String("live"))
            continue;
        if (m_sessions[row].rejected == rejected)
            continue;
        m_sessions[row].rejected = rejected;
        touchRow(row);
        ++n;
    }
    qInfo() << "[sessions]" << (rejected ? "rejected" : "un-rejected") << n
            << "session(s) in rows" << fromRow << "-" << toRow;
    if (n > 0)
        emit countChanged();   // refresh rejectedCount (see setRejected)
    return n;
}

void SessionStore::setNote(int row, const QString &note)
{
    if (row < 0 || row >= m_sessions.size())
        return;
    m_sessions[row].note = note;
    touchRow(row);
}
