// SessionStore.cpp — see SessionStore.h.
#include "SessionStore.h"
#include "FolderWatcher.h"
#include "XylodLink.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
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
            s.passes << p;
        }
        if (s.state == QLatin1String("live"))
            s.state = QStringLiteral("partial");   // we crashed or were closed mid-scan
        m_sessions << s;
        m_nextSeq = qMax(m_nextSeq, s.seq + 1);
    }
    qInfo() << "[sessions] loaded" << m_sessions.size() << "sidecars from" << sidecarDir();
}

void SessionStore::save(const SessionRecord &s) const
{
    if (m_captureDir.isEmpty())
        return;
    QDir().mkpath(sidecarDir());

    QJsonArray passes;
    for (const PassRecord &p : s.passes) {
        passes.append(QJsonObject{
            { QStringLiteral("index"),       p.index },
            { QStringLiteral("filter"),      p.filter },
            { QStringLiteral("tStartMs"),    double(p.tStartMs) },
            { QStringLiteral("tEndMs"),      double(p.tEndMs) },
            { QStringLiteral("wallStartMs"), double(p.wallStartMs) },
            { QStringLiteral("wallEndMs"),   double(p.wallEndMs) },
            { QStringLiteral("file"),        p.file },
        });
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

void SessionStore::pairPendingFiles()
{
    // Oldest unpaired file → oldest ended, unpaired pass within the window.
    // FIFO on both sides keeps manual-save order predictable; anything that
    // can't pair stays visible as "unpaired" (importer fodder, never lost).
    bool changed = false;
    for (int f = 0; f < m_unpaired.size(); ) {
        const qint64 mtime = m_unpaired[f].second;
        bool paired = false;
        for (int row = 0; row < m_sessions.size() && !paired; ++row) {
            SessionRecord &s = m_sessions[row];
            for (PassRecord &p : s.passes) {
                if (!p.file.isEmpty() || p.wallEndMs < 0)
                    continue;
                if (mtime < p.wallStartMs - 5000
                    || mtime - p.wallStartMs > kPairWindowMs)
                    continue;
                p.file = QDir(m_captureDir).relativeFilePath(m_unpaired[f].first);
                qInfo() << "[sessions] paired" << p.file
                        << "→ session" << s.seq << "pass" << p.index << p.filter;
                touchRow(row);
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
