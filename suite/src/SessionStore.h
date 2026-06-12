#pragma once
// SessionStore.h — the suite's session ledger.
//
// Sessions are born from xylod events (pass_start), closed by seq_done
// (complete) or fault/link-drop (partial — never hidden, plan → Operational).
// Files from the capture share are paired to passes by wall-clock windows
// (plan → Foundations #4). Every change writes through instantly to a
// schema-versioned sidecar JSON — there is no Save (plan → Design).
//
// Sidecars live in <captureFolder>/.xylosome/sessions/<uuid>.json.
// Exposed to QML as a list model (newest last); singleton "Sessions".

#include <QAbstractListModel>
#include <QDateTime>
#include <QThread>
#include <QVector>

class XylodLink;
class FolderWatcher;
class VipsEngine;

struct PassRecord {
    int     index = -1;          // 0..3
    QString filter;              // R|G|B|C
    qint64  tStartMs = -1;       // daemon monotonic
    qint64  tEndMs = -1;
    qint64  wallStartMs = -1;    // suite wall clock at event arrival
    qint64  wallEndMs = -1;
    QString file;                // paired TIFF (name relative to capture dir)
    bool    sealed = false;      // transient: hole skipped by the stream, never pair
    QString preview;             // abs path of pass_<i>_preview.jpg ("" = pending)
    int     pxW = 0, pxH = 0;    // original TIFF dimensions (from ingest)
    double  clipBlackPct = -1;   // -1 = not computed
    double  clipWhitePct = -1;
    QVector<double> hist256;
};

struct SessionRecord {
    QString uuid;
    int     seq = 0;             // display number
    qint64  createdWallMs = 0;
    QString state;               // live | complete | partial
    int     rating = 0;
    bool    rejected = false;
    QString note;
    QVector<PassRecord> passes;
};

class SessionStore : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(QString captureDir READ captureDir WRITE setCaptureDir NOTIFY captureDirChanged)
    Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
    Q_PROPERTY(int liveRow READ liveRow NOTIFY countChanged)
    Q_PROPERTY(int unpairedFiles READ unpairedFiles NOTIFY unpairedFilesChanged)
    Q_PROPERTY(double freeGB READ freeGB NOTIFY diskChanged)
    Q_PROPERTY(int sessionsRemaining READ sessionsRemaining NOTIFY diskChanged)
    Q_PROPERTY(int rejectedCount READ rejectedCount NOTIFY countChanged)

public:
    enum Roles {
        SeqRole = Qt::UserRole + 1,
        UuidRole,
        StateRole,
        RatingRole,
        RejectedRole,
        NoteRole,
        PassCountRole,       // passes recorded so far
        PassFiltersRole,     // QStringList, e.g. ["R","G","B"]
        PassPairedRole,      // QVariantList<bool> — file present per pass
        PassDurationsRole,   // QVariantList<double> — seconds per pass, -1 if open
        PassPreviewsRole,    // QVariantList<QString> — preview abs path or ""
        PassClipsRole,       // QVariantList<QVariantMap{black,white}> — % or -1
        PassDimsRole,        // QVariantList<QVariantMap{w,h}> — original px
        PassTileBasesRole,   // QVariantList<QString> — dz base path or ""
        CreatedRole,         // qint64 wall ms
    };

    explicit SessionStore(XylodLink *link, QObject *parent = nullptr);

    int rowCount(const QModelIndex & = {}) const override { return m_sessions.size(); }
    QVariant data(const QModelIndex &idx, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString captureDir() const { return m_captureDir; }
    void setCaptureDir(const QString &dir);

    int liveRow() const;
    int unpairedFiles() const { return m_unpaired.size(); }

    Q_INVOKABLE void setRating(int row, int rating);
    Q_INVOKABLE void setRejected(int row, bool rejected);
    Q_INVOKABLE void setNote(int row, const QString &note);

    double freeGB() const { return m_freeGB; }
    int sessionsRemaining() const { return m_sessionsRemaining; }
    int rejectedCount() const;

    // Permanent deletion (plan → Operational / Permanent delete).
    // sessionBytes: TIFFs + proxies, for the confirmation dialog.
    Q_INVOKABLE double sessionGB(int row) const;
    Q_INVOKABLE void deleteSession(int row);     // direct, skips quarantine
    Q_INVOKABLE void emptyQuarantine();          // deletes every rejected session

signals:
    void captureDirChanged();
    void countChanged();
    void unpairedFilesChanged();
    void diskChanged();
    void reclaimed(double gb, int sessions);     // after any permanent delete

private slots:
    void onPassStarted(int pass, const QString &filter, qint64 tMs, qint64 wallMs);
    void onPassEnded(int pass, qint64 tMs, qint64 wallMs);
    void onSequenceDone(int passes);
    void onFaulted(const QString &text);
    void onLinkDropped();
    void onFileReady(const QString &absPath, qint64 mtimeMs);
    void onIngested(const QString &sessionUuid, int passIndex,
                    const QString &previewAbs, int pxW, int pxH,
                    double clipBlackPct, double clipWhitePct,
                    const QVariantList &hist256);

private:
    SessionRecord *liveSession();
    void beginSession(qint64 wallMs);
    void closeLive(const QString &finalState);
    void save(const SessionRecord &s) const;
    void loadExisting();
    void pairPendingFiles();
    void enqueueIngest(const SessionRecord &s, const PassRecord &p);
    QString sidecarDir() const;
    QString proxiesDir() const;
    void touchRow(int row);
    void refreshDisk();
    qint64 sessionBytes(const SessionRecord &s) const;
    void appendDeletionLog(const SessionRecord &s, qint64 bytes) const;

    XylodLink *m_link = nullptr;
    FolderWatcher *m_watcher = nullptr;
    VipsEngine *m_engine = nullptr;
    QThread m_engineThread;
    QString m_captureDir;
    QVector<SessionRecord> m_sessions;
    QVector<QPair<QString, qint64>> m_unpaired;   // absPath, mtimeMs
    int m_nextSeq = 1;
    double m_freeGB = -1;
    int m_sessionsRemaining = -1;
};
