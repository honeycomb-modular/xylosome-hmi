// Xylosome Suite — entry point.
// Phase 0: splash + empty main window. See docs/concept/review_suite_plan.md.

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QIcon>
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
    QGuiApplication::setApplicationVersion("0.1.0");

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
