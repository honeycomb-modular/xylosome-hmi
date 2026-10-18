// Xylosome Suite — entry point.
// Phase 0: splash + empty main window. See docs/concept/review_suite_plan.md.

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QIcon>
#include <QLockFile>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QUrl>

#include "CameraLink.h"
#include "HmiLink.h"
#include "LiveImageProvider.h"
#include "LiveLink.h"
#include "SessionStore.h"
#include "XylodLink.h"
#include "gitrev.h"
#ifdef Q_OS_WIN
#include <windows.h>
#endif

// Log file from day one (plan → Foundations #5): everything qInfo/qWarning
// also lands in <AppData>/suite.log, timestamped.
static QFile g_logFile;
static QtMessageHandler g_prevHandler = nullptr;

static void logHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    if (g_logFile.isOpen()) {
        const char *lvl = type == QtWarningMsg ? "WARN"
                        : type == QtCriticalMsg ? "CRIT"
                        : type == QtFatalMsg ? "FATAL" : "INFO";
        g_logFile.write(QStringLiteral("%1 %2 %3\n")
                            .arg(QDateTime::currentDateTime().toString(Qt::ISODateWithMs),
                                 QLatin1String(lvl), msg)
                            .toUtf8());
        g_logFile.flush();
    }
    if (g_prevHandler)
        g_prevHandler(type, ctx, msg);
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    QGuiApplication::setOrganizationName("Honeycomb Modular");
    QGuiApplication::setOrganizationDomain("honeycomb-modular.com");
    QGuiApplication::setApplicationName("Xylosome Suite");
    QGuiApplication::setApplicationVersion("0.1.0+" GIT_REV);


    // Basic style: identical rendering on all three platforms; the suite
    // draws its own design language on top.
    QQuickStyle::setStyle("Basic");

    QGuiApplication::setWindowIcon(
        QIcon(QStringLiteral(":/qt/qml/XylosomeSuite/assets/icon.png")));

    const QString logDir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(logDir);
    g_logFile.setFileName(logDir + QStringLiteral("/suite.log"));
    g_logFile.open(QIODevice::Append | QIODevice::Text);
    g_prevHandler = qInstallMessageHandler(logHandler);
    qInfo() << "[suite] start — log at" << g_logFile.fileName();

    // One Suite at a time. Two instances (2026-10-17: a stale one from dist and
    // a fresh one from build-suite) both watched the folder and both wrote
    // sidecars and proxies: duplicated sessions, torn pyramids, a zeroed
    // sidecar. QLockFile releases on exit or crash (dead-PID detection).
    QLockFile lock(QDir::temp().filePath(QStringLiteral("xylosome-suite.lock")));
    if (!lock.tryLock(500)) {
        qWarning() << "[suite] another Xylosome Suite is already running — not starting a second";
#ifdef Q_OS_WIN
        MessageBoxW(nullptr, L"Xylosome Suite is already running.\nUse the open window.",
                    L"Xylosome Suite", MB_OK | MB_ICONINFORMATION);
#endif
        return 0;
    }

    auto *xylod = new XylodLink(&app);
    qmlRegisterSingletonInstance("XylosomeSuite.Link", 1, 0, "Xylod", xylod);

    auto *sessions = new SessionStore(xylod, &app);
    qmlRegisterSingletonInstance("XylosomeSuite.Link", 1, 0, "Sessions", sessions);

    auto *live = new LiveLink(&app);
    qmlRegisterSingletonInstance("XylosomeSuite.Link", 1, 0, "Live", live);

    auto *camera = new CameraLink(&app);
    qmlRegisterSingletonInstance("XylosomeSuite.Link", 1, 0, "Camera", camera);

    auto *hmi = new HmiLink(&app);
    qmlRegisterSingletonInstance("XylosomeSuite.Link", 1, 0, "Hmi", hmi);

    QQmlApplicationEngine engine;
    engine.addImageProvider(QStringLiteral("live"), new LiveImageProvider(live));
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreated, &app,
        [](QObject *obj, const QUrl &) {
            if (!obj)
                QCoreApplication::exit(1);
        },
        Qt::QueuedConnection);

#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    engine.loadFromModule("XylosomeSuite", "Main");
#else
    // Qt 6.2–6.4 (stock Ubuntu 22.04): load the module's QML directly.
    engine.addImportPath(QStringLiteral("qrc:/qt/qml"));
    engine.load(QUrl(QStringLiteral("qrc:/qt/qml/XylosomeSuite/qml/Main.qml")));
#endif

    return app.exec();
}
