#pragma once
// LiveImageProvider.h — hands LiveLink's waterfall QImage to QML.
// QML requests "image://live/w?<serial>"; the serial busts Qt's cache.

#include <QQuickImageProvider>
#include "LiveLink.h"

class LiveImageProvider : public QQuickImageProvider
{
public:
    explicit LiveImageProvider(LiveLink *link)
        : QQuickImageProvider(QQuickImageProvider::Image), m_link(link) {}

    QImage requestImage(const QString &, QSize *size, const QSize &) override
    {
        const QImage img = m_link->waterfall();
        if (size)
            *size = img.size();
        return img;
    }

private:
    LiveLink *m_link;
};
