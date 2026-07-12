#pragma once
// VipsEngine.h — the ingest worker (plan → Proxy pipeline).
//
// Lives in its own QThread. For each paired TIFF it produces, beside the
// originals in <captureDir>/.xylosome/proxies/<sessionUuid>/:
//
//   pass_<i>.dzi + pass_<i>_files/   deep-zoom JPEG tile pyramid (q90,
//                                    256 px tiles, 16→8 bit fixed mapping)
//   pass_<i>_preview.jpg             ≤2048 px single JPEG (filmstrip + fit view)
//
// and computes from one histogram pass over the 16-bit original:
//   clip black %, clip white %, 256-bin histogram → sidecar JSON.
//
// The TIFF is opened read-only and never modified. Ingest is idempotent:
// the proxy dir is wiped and rebuilt, so a crash mid-ingest just re-runs.
//
// Built without libvips (CMake: vips-cpp not found) every job fails
// gracefully with a log line — the suite still runs, judging still works.

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>

class VipsEngine : public QObject
{
    Q_OBJECT

public:
    explicit VipsEngine(QObject *parent = nullptr);
    ~VipsEngine() override;

    static bool available();

public slots:
    // absPath: the TIFF. proxyDir: .../proxies/<uuid> (created if needed).
    void ingest(const QString &sessionUuid, int passIndex,
                const QString &absPath, const QString &proxyDir);

signals:
    // previewRel/dziRel are relative to proxyDir's parent (the proxies root).
    void ingested(const QString &sessionUuid, int passIndex,
                  const QString &previewAbs, int pxW, int pxH,
                  double clipBlackPct, double clipWhitePct,
                  const QVariantList &hist256);
    void failed(const QString &sessionUuid, int passIndex, const QString &error);
};
