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
// 16-bit → 8-bit. Genuine 16-bit data is left-justified, so the meaningful bits
// are the top 8 (>> 8) — which is what the capture agent now emits: it shifts
// the board's right-justified data up at the source (`RAW_SHIFT`), so a 12-bit
// scan is stored as an honest 0..65535 image that any TIFF viewer renders too.
// Scans captured BEFORE that change are 8-bit right-justified in a 16-bit
// container (values 0..255, high byte empty), and there >> 8 would zero
// everything (black scans, grey in the live view). So probe the actual max:
// ≤255 means the data lives in the low byte — cast straight down; otherwise
// shift. Returns a new ref or null.
//
// Edge case, left as-is: a left-justified scan so dark that nothing exceeds 255
// takes the legacy branch and comes out wrong. That needs a peak below 0.4% of
// full scale — a black frame either way. The TIFF's "bits" metadata would settle
// it if this ever stops being theoretical.
static VipsImage *to8(VipsImage *in)
{
    double maxval = 0;
    const bool lowByte = vips_max(in, &maxval, nullptr) == 0 && maxval <= 255.0;

    VipsImage *out = nullptr;
    if (lowByte) {
        if (vips_cast(in, &out, VIPS_FORMAT_UCHAR, nullptr))   // 0..255 already
            return nullptr;
        return out;
    }

    VipsImage *shifted = nullptr;
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

    // ── tile pyramid + fit preview, both from ONE 8-bit mapping so the
    //    filmstrip, fit view and 1:1 tiles all agree (TIFF stays truth).
    VipsImage *mapped = sixteen ? to8(src) : (VipsImage *)g_object_ref(src);
    if (!mapped) { fail("to8"); g_object_unref(src); return; }

    // Display orientation (proxies only — the original TIFF is never touched):
    // the scan axis runs across the sensor, so rotate 90° CW, then flip
    // horizontal to undo the reverse-readout mirror. Histogram below uses the
    // unrotated src (orientation-independent), so clip stats are unchanged.
    VipsImage *rot = nullptr;
    if (vips_rot(mapped, &rot, VIPS_ANGLE_D90, nullptr)) {
        fail("rot"); g_object_unref(mapped); g_object_unref(src); return;
    }
    g_object_unref(mapped);
    VipsImage *v8 = nullptr;
    if (vips_flip(rot, &v8, VIPS_DIRECTION_HORIZONTAL, nullptr)) {
        fail("flip"); g_object_unref(rot); g_object_unref(src); return;
    }
    g_object_unref(rot);
    const int pxW = vips_image_get_width(v8);   // oriented (display) dims
    const int pxH = vips_image_get_height(v8);
    int r = vips_dzsave(v8, base.toUtf8().constData(),
                        "layout", VIPS_FOREIGN_DZ_LAYOUT_DZ,
                        "suffix", ".jpg[Q=90]",
                        "tile_size", 256,
                        "overlap", 0,
                        "depth", VIPS_FOREIGN_DZ_DEPTH_ONEPIXEL,
                        nullptr);
    if (r) { fail("dzsave"); g_object_unref(v8); g_object_unref(src); return; }

    // fit preview: shrink the same mapping to ≤2048 px. (Was vips_thumbnail,
    // which re-scaled the full 16-bit range and blacked out 8-bit-low data.)
    VipsImage *prev = nullptr;
    const double scale = qMin(1.0, 2048.0 / double(vips_image_get_width(v8)));
    if (scale < 1.0) {
        if (vips_resize(v8, &prev, scale, nullptr)) {
            fail("resize"); g_object_unref(v8); g_object_unref(src); return;
        }
    } else {
        prev = (VipsImage *)g_object_ref(v8);
    }
    g_object_unref(v8);
    r = vips_jpegsave(prev, previewPath.toUtf8().constData(), "Q", 90, nullptr);
    g_object_unref(prev);
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
