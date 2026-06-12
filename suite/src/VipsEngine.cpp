// VipsEngine.cpp — see VipsEngine.h.
//
// Uses the libvips C API (not vips-cpp): the C ABI is stable across
// compilers, which is what lets the official MinGW-built Windows binaries
// link against an MSVC build. It also dodges the Qt `signals` macro ⇄ glib
// struct-field collision — but vips headers still come first, defensively.

#ifdef HAVE_VIPS
#include <vips/vips.h>
#endif

#include "VipsEngine.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QVector>
#include <QDebug>

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

#ifdef HAVE_VIPS
// 16-bit → 8-bit fixed mapping (rshift 8 + cast). Returns new ref or null.
static VipsImage *to8(VipsImage *in)
{
    VipsImage *shifted = nullptr, *out = nullptr;
    double c = 8;
    if (vips_boolean_const(in, &shifted, VIPS_OPERATION_BOOLEAN_RSHIFT, &c, 1, nullptr))
        return nullptr;
    if (vips_cast(shifted, &out, VIPS_FORMAT_UCHAR, nullptr)) {
        g_object_unref(shifted);
        return nullptr;
    }
    g_object_unref(shifted);
    return out;
}
#endif

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

    auto fail = [&](const char *stage) {
        const QString err = QStringLiteral("%1: %2")
                                .arg(QLatin1String(stage),
                                     QString::fromUtf8(vips_error_buffer()));
        vips_error_clear();
        qWarning() << "[vips] ingest failed —" << err;
        emit failed(sessionUuid, passIndex, err);
    };

    // Idempotent: wipe any partial previous attempt.
    QDir().mkpath(proxyDir);
    QDir(base + QStringLiteral("_files")).removeRecursively();
    QFile::remove(base + QStringLiteral(".dzi"));
    QFile::remove(previewPath);

    qInfo() << "[vips] ingest" << QFileInfo(absPath).fileName()
            << "→" << QFileInfo(proxyDir).fileName() << "pass" << passIndex;

    const QByteArray pathU = absPath.toUtf8();

    VipsImage *src = vips_image_new_from_file(pathU.constData(), nullptr);
    if (!src) { fail("open"); return; }
    const bool sixteen = vips_image_get_format(src) == VIPS_FORMAT_USHORT;
    const int pxW = vips_image_get_width(src);
    const int pxH = vips_image_get_height(src);

    // ── tile pyramid (fixed 16→8 mapping for judging; TIFF stays truth)
    VipsImage *v8 = sixteen ? to8(src) : (VipsImage *)g_object_ref(src);
    if (!v8) { fail("to8"); g_object_unref(src); return; }
    int r = vips_dzsave(v8, base.toUtf8().constData(),
                        "layout", VIPS_FOREIGN_DZ_LAYOUT_DZ,
                        "suffix", ".jpg[Q=90]",
                        "tile_size", 256,
                        "overlap", 0,
                        "depth", VIPS_FOREIGN_DZ_DEPTH_ONEPIXEL,
                        nullptr);
    g_object_unref(v8);
    if (r) { fail("dzsave"); g_object_unref(src); return; }

    // ── fit preview (filmstrip + fit-to-screen view)
    VipsImage *prev = nullptr;
    if (vips_thumbnail(pathU.constData(), &prev, 2048, nullptr)) {
        fail("thumbnail");
        g_object_unref(src);
        return;
    }
    VipsImage *prev8 = vips_image_get_format(prev) == VIPS_FORMAT_USHORT
                           ? to8(prev) : (VipsImage *)g_object_ref(prev);
    g_object_unref(prev);
    if (!prev8) { fail("to8 preview"); g_object_unref(src); return; }
    r = vips_jpegsave(prev8, previewPath.toUtf8().constData(), "Q", 90, nullptr);
    g_object_unref(prev8);
    if (r) { fail("jpegsave"); g_object_unref(src); return; }

    // ── histogram + clip stats, one pass over the original
    VipsImage *hist = nullptr;
    if (vips_hist_find(src, &hist, nullptr)) {
        fail("hist_find");
        g_object_unref(src);
        return;
    }
    g_object_unref(src);

    const int bins = vips_image_get_width(hist);
    const bool histIsUint = vips_image_get_format(hist) == VIPS_FORMAT_UINT;
    size_t len = 0;
    void *mem = vips_image_write_to_memory(hist, &len);
    g_object_unref(hist);
    if (!mem) { fail("hist memory"); return; }

    QVariantList hist256;
    double total = 0, clip0 = 0, clipMax = 0;
    {
        const int fold = qMax(1, bins / 256);
        QVector<double> folded(qMin(bins, 256), 0.0);
        auto at = [&](int i) -> double {
            return histIsUint ? double(static_cast<quint32 *>(mem)[i])
                              : static_cast<double *>(mem)[i];
        };
        for (int i = 0; i < bins; ++i) {
            const double v = at(i);
            total += v;
            folded[qMin(i / fold, int(folded.size()) - 1)] += v;
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
    emit ingested(sessionUuid, passIndex, previewPath, pxW, pxH,
                  clipBlackPct, clipWhitePct, hist256);
#endif
}
