// FolderWatcher.cpp — see FolderWatcher.h.
#include "FolderWatcher.h"
#include <QDir>
#include <QFileInfo>
#include <QDebug>

static bool isTiff(const QString &name)
{
    return name.endsWith(QLatin1String(".tif"), Qt::CaseInsensitive)
        || name.endsWith(QLatin1String(".tiff"), Qt::CaseInsensitive);
}

FolderWatcher::FolderWatcher(QObject *parent)
    : QObject(parent)
{
    m_tick.setInterval(1000);
    connect(&m_tick, &QTimer::timeout, this, &FolderWatcher::scan);
    connect(&m_fsw, &QFileSystemWatcher::directoryChanged,
            this, [this] { if (!m_tick.isActive()) m_tick.start(); });
}

void FolderWatcher::setDir(const QString &dir)
{
    if (m_dir == dir)
        return;
    if (!m_dir.isEmpty())
        m_fsw.removePath(m_dir);
    m_dir = dir;
    m_pending.clear();
    m_known.clear();
    if (m_dir.isEmpty())
        return;
    m_fsw.addPath(m_dir);
    qInfo() << "[watcher] watching" << m_dir;
    m_tick.start();
    scan();
}

void FolderWatcher::scan()
{
    if (m_dir.isEmpty())
        return;

    const QFileInfoList entries =
        QDir(m_dir).entryInfoList(QDir::Files | QDir::Readable, QDir::Time);

    bool anythingPending = false;
    for (const QFileInfo &fi : entries) {
        if (!isTiff(fi.fileName()))
            continue;
        const QString path = fi.absoluteFilePath();
        if (m_known.contains(path))
            continue;

        Pending &p = m_pending[path];
        const qint64 size = fi.size();
        if (size == p.size && size > 0) {
            if (++p.stableTicks >= 2) {
                m_known.insert(path);
                m_pending.remove(path);
                qInfo() << "[watcher] file ready:" << fi.fileName() << size << "bytes";
                emit fileReady(path, fi.lastModified().toMSecsSinceEpoch());
                continue;
            }
        } else {
            p.size = size;
            p.stableTicks = 0;
        }
        anythingPending = true;
    }

    if (!anythingPending)
        m_tick.stop();   // directoryChanged re-arms it
}
