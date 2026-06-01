// main.cpp — XYLOSOME HMI  ── Qt6/QML port of art_motion_hmi_elecrow
//
// Boot order mirrors the ESP32 setup():
//   1. MotorModel  (starts 10 Hz tick timer)
//   2. HttpServer  (listens on :8080)
//   3. QML engine  (loads main.qml)
//
// Platform notes:
//   Pi (EGLFS / no desktop):
//     Run with:  ./xylosome_hmi -platform eglfs
//     Touch is auto-detected by Qt via /dev/input/event* (libinput or evdev).
//
//   Pi (Wayland):
//     Run with:  ./xylosome_hmi -platform wayland
//     (Requires weston or labwc running, and QT_WAYLAND_SHELL_INTEGRATION=xdg-shell)
//
//   Mac / X11 (development):
//     Run normally: ./xylosome_hmi   (800×480 window)

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDebug>
#include <QCursor>

#include "MotorModel.h"
#include "PendantReader.h"
#include "HttpServer.h"

int main(int argc, char *argv[])
{
    // On Pi EGLFS the default OpenGL context may not support the full desktop
    // profile.  Force RHI software rendering as a fallback during bring-up.
    // Comment this out once the Pi GPU drivers are confirmed working:
    //   QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);

    QGuiApplication app(argc, argv);
    app.setOverrideCursor(Qt::BlankCursor);   // kiosk — no mouse pointer
    app.setApplicationName(QStringLiteral("XYLOSOME"));
    app.setApplicationVersion(QStringLiteral("0.1-qt"));
    app.setOrganizationName(QStringLiteral("xylosome"));

    // ── 1. Motor model ────────────────────────────────────────────────────────
    MotorModel motor;

    // ── 2. Pendant reader ────────────────────────────────────────────────────────
    PendantReader pendant;
    qmlRegisterSingletonInstance<PendantReader>("XylosomeHMI", 1, 0, "Pendant", &pendant);
    pendant.start();

    // ── 3. HTTP server ────────────────────────────────────────────────────────
    // Default port 8080 (no root required).
    // To bind :80 on Pi without root:
    //   sudo setcap cap_net_bind_service+ep ./xylosome_hmi
    // then change the port argument to 80.
    HttpServer httpServer(&motor);
    if (httpServer.listen(8080))
        qInfo("[boot] web control: http://localhost:8080/");

    // ── 3. QML engine ─────────────────────────────────────────────────────────
    // Register MotorModel as a QML singleton accessible as "Motor" in any
    // file that does:  import XylosomeHMI 1.0
    qmlRegisterSingletonInstance<MotorModel>("XylosomeHMI", 1, 0, "Motor", &motor);

    QQmlApplicationEngine engine;

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed,
        &app,    []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);

    // Qt6.4+ can use engine.loadFromModule("XylosomeHMI", "main").
    // The QRC URL below works on all Qt 6.2+ builds.
    engine.load(QUrl(QStringLiteral("qrc:/XylosomeHMI/qml/main.qml")));

    if (engine.rootObjects().isEmpty()) {
        qCritical("[boot] QML root object failed to load — aborting");
        return -1;
    }

    qInfo("[boot] XYLOSOME temporal scanning unit — Qt port ready");
    return app.exec();
}
