// Xylosome Suite — entry point.
// Phase 0: splash + empty main window. See docs/concept/review_suite_plan.md.

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QUrl>

#include "XylodLink.h"

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

    auto *xylod = new XylodLink(&app);
    qmlRegisterSingletonInstance("XylosomeSuite.Link", 1, 0, "Xylod", xylod);

    QQmlApplicationEngine engine;
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
