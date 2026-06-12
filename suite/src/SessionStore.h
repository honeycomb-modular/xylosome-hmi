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
#include <QVector>

class XylodLink;
class FolderWatcher;

struct PassRecord {
    int     index = -1;          // 0..3
    QString filter;              // R|G|B|C
    qint64  tStartMs = -1;       // daemon monotonic
    qint64  tEndMs = -1;
    qint64  wallStartMs = -1;    // suite wall clock at event arrival
    qint64  wallEndMs = -1;
    QString file;                // paired TIFF (name relative to capture dir)
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

signals:
    void captureDirChanged();
    void countChanged();
    void unpairedFilesChanged();

private slots:
    void onPassStarted(int pass, const QString &filter, qint64 tMs, qint64 wallMs);
    void onPassEnded(int pass, qint64 tMs, qint64 wallMs);
    void onSequenceDone(int passes);
    void onFaulted(const QString &text);
    void onLinkDropped();
    void onFileReady(const QString &absPath, qint64 mtimeMs);

private:
    SessionRecord *liveSession();
    void beginSession(qint64 wallMs);
    void closeLive(const QString &finalState);
    void save(const SessionRecord &s) const;
    void loadExisting();
    void pairPendingFiles();
    QString sidecarDir() const;
    void touchRow(int row);

    XylodLink *m_link = nullptr;
    FolderWatcher *m_watcher = nullptr;
    QString m_captureDir;
    QVector<SessionRecord> m_sessions;
    QVector<QPair<QString, qint64>> m_unpaired;   // absPath, mtimeMs
    int m_nextSeq = 1;
};
