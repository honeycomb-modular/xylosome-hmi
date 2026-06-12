// VipsEngine.cpp — see VipsEngine.h.
#include "VipsEngine.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QVector>
#include <QDebug>

#ifdef HAVE_VIPS
#include <vips/vips8>
using vips::VImage;
using vips::VError;
#endif

VipsEngine::VipsEngine(QObject *parent)
    : QObject(parent)
{
#ifdef HAVE_VIPS
    if (VIPS_INIT("xylosome-suite"))
        qWarning() << "[vips] init failed:" << vips_error_buffer();
    else
        qInfo() << "[vips] libvips" << vips_version(0) << "." << vips_version(1);
#else
    qWarning() << "[vips] built without libvips — ingest disabled, judging still works";
#endif
}

VipsEngine::~VipsEngine()
{
#ifdef HAVE_VIPS
    vips_shutdown();
#endif
}

bool VipsEngine::available()
{
#ifdef HAVE_VIPS
    return true;
#else
    return false;
#endif
}

void VipsEngine::ingest(const QString &sessionUuid, int passIndex,
                        const QString &absPath, const QString &proxyDir)
{
#ifndef HAVE_VIPS
    emit failed(sessionUuid, passIndex, QStringLiteral("built without libvips"));
    Q_UNUSED(absPath)
    Q_UNUSED(proxyDir)
#else
    const QString base = proxyDir + QStringLiteral("/pass_%1").arg(passIndex);
    const QString previewPath = base + QStringLiteral("_preview.jpg");

    // Idempotent: wipe any partial previous attempt.
    QDir().mkpath(proxyDir);
    QDir(base + QStringLiteral("_files")).removeRecursively();
    QFile::remove(base + QStringLiteral(".dzi"));
    QFile::remove(previewPath);

    qInfo() << "[vips] ingest" << QFileInfo(absPath).fileName()
            << "→" << QFileInfo(proxyDir).fileName() << "pass" << passIndex;

    try {
        VImage src = VImage::new_from_file(absPath.toUtf8().constData());
        const bool sixteen = src.format() == VIPS_FORMAT_USHORT;

        auto to8 = [](const VImage &img) {
            return img.boolean_const(VIPS_OPERATION_BOOLEAN_RSHIFT, { 8.0 })
                      .cast(VIPS_FORMAT_UCHAR);
        };

        // ── tile pyramid (fixed 16→8 mapping for judging; TIFF stays truth)
        VImage v8 = sixteen ? to8(src) : src;
        v8.dzsave(base.toUtf8().constData(),
                  VImage::option()
                      ->set("layout", VIPS_FOREIGN_DZ_LAYOUT_DZ)
                      ->set("suffix", ".jpg[Q=90]")
                      ->set("tile_size", 256)
                      ->set("overlap", 0)
                      ->set("depth", VIPS_FOREIGN_DZ_DEPTH_ONEPIXEL));

        // ── fit preview (filmstrip + fit-to-screen view)
        VImage prev = VImage::thumbnail(absPath.toUtf8().constData(), 2048);
        if (prev.format() == VIPS_FORMAT_USHORT)
            prev = to8(prev);
        prev.jpegsave(previewPath.toUtf8().constData(),
                      VImage::option()->set("Q", 90));

        // ── histogram + clip stats, one pass over the original
        VImage hist = src.hist_find();
        const int bins = hist.width();
        size_t len = 0;
        void *mem = hist.write_to_memory(&len);
        QVariantList hist256;
        double total = 0, clip0 = 0, clipMax = 0;
        {
            const int fold = qMax(1, bins / 256);
            QVector<double> folded(qMin(bins, 256), 0.0);
            auto at = [&](int i) -> double {
                if (hist.format() == VIPS_FORMAT_UINT)
                    return double(static_cast<quint32 *>(mem)[i]);
                return static_cast<double *>(mem)[i];
            };
            for (int i = 0; i < bins; ++i) {
                const double v = at(i);
                total += v;
                folded[qMin(i / fold, folded.size() - 1)] += v;
            }
            clip0 = at(0);
            clipMax = at(bins - 1);
            for (double v : folded)
                hist256 << v;
        }
        g_free(mem);

        const double clipBlackPct = total > 0 ? clip0 / total * 100.0 : 0.0;
        const double clipWhitePct = total > 0 ? clipMax / total * 100.0 : 0.0;

        qInfo() << "[vips] done pass" << passIndex
                << QStringLiteral("clip %1% / %2%")
                       .arg(clipBlackPct, 0, 'f', 3)
                       .arg(clipWhitePct, 0, 'f', 3);
        emit ingested(sessionUuid, passIndex, previewPath,
                      clipBlackPct, clipWhitePct, hist256);
    } catch (const VError &e) {
        qWarning() << "[vips] ingest failed:" << e.what();
        emit failed(sessionUuid, passIndex, QString::fromUtf8(e.what()));
    }
#endif
}
