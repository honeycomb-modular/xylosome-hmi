#pragma once
// FolderWatcher.h — capture-share watcher with write-stability guard.
//
// Emits fileReady(path, mtimeMs) only after a TIFF's size has been stable
// across two scan ticks — a >1 GB file arriving over SMB must never be
// ingested half-written (plan → open question 2). Rescans fully on start
// (crash-safe ingest, plan → Foundations: restart = rescan + reconcile).

#include <QObject>
#include <QFileSystemWatcher>
#include <QHash>
#include <QSet>
#include <QTimer>

class FolderWatcher : public QObject
{
    Q_OBJECT

public:
    explicit FolderWatcher(QObject *parent = nullptr);

    void setDir(const QString &dir);
    QString dir() const { return m_dir; }

signals:
    void fileReady(const QString &absPath, qint64 mtimeMs);

private slots:
    void scan();

private:
    struct Pending { qint64 size = -1; int stableTicks = 0; };

    QString m_dir;
    QFileSystemWatcher m_fsw;
    QTimer m_tick;
    QHash<QString, Pending> m_pending;   // absPath → stability state
    QSet<QString> m_known;               // already announced
};
