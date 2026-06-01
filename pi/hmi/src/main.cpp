// main.cpp — XYLOSOME HMI  ── Qt6/QML port of art_motion_hmi_elecrow
//
// Boot order mirrors the ESP32 setup():
//   1. MotorModel  (starts 10 Hz tick timer)
//   2. HttpServer  (listens on :8080)
//   3. QML engine  (loads main.qml)
//   4. PendantReader (Teensy over USB serial -> key events)
//
// Platform notes:
//   Pi (Wayland):
//     Run with:  ./xylosome_hmi -platform wayland
//     (Requires labwc running, and QT_WAYLAND_SHELL_INTEGRATION=xdg-shell)
//   Mac / X11 (development):
//     Run normally: ./xylosome_hmi

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDebug>
#include <QCursor>
#include <QWindow>

#include "MotorModel.h"
#include "HttpServer.h"
#include "MetadataRecorder.h"
#include "PendantReader.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setOverrideCursor(Qt::BlankCursor);   // kiosk — no mouse pointer
    app.setApplicationName(QStringLiteral("XYLOSOME"));
    app.setApplicationVersion(QStringLiteral("0.1-qt"));
    app.setOrganizationName(QStringLiteral("xylosome"));

    // ── 1. Motor model ────────────────────────────────────────────────────────
    MotorModel motor;

    // ── 1b. Metadata recorder ─────────────────────────────────────────────────
    MetadataRecorder recorder(&motor);

    // ── 2. HTTP server ────────────────────────────────────────────────────────
    HttpServer httpServer(&motor);
    if (httpServer.listen(8080))
        qInfo("[boot] web control: http://localhost:8080/");

    // ── 3. QML engine ─────────────────────────────────────────────────────────
    qmlRegisterSingletonInstance<MotorModel>("XylosomeHMI", 1, 0, "Motor", &motor);
    qmlRegisterSingletonInstance<MetadataRecorder>("XylosomeHMI", 1, 0, "Recorder", &recorder);

    QQmlApplicationEngine engine;

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed,
        &app,    []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);

    engine.load(QUrl(QStringLiteral("qrc:/XylosomeHMI/qml/main.qml")));

    if (engine.rootObjects().isEmpty()) {
        qCritical("[boot] QML root object failed to load — aborting");
        return -1;
    }

    // ── 4. Pendant (Teensy over USB-CDC serial) ───────────────────────────────
    // Posts key events to the root window, so main.qml's existing keyboard
    // focus router drives the UI. No screen changes needed.
    PendantReader pendant;
    if (auto *win = qobject_cast<QWindow *>(engine.rootObjects().first())) {
        pendant.setTargetWindow(win);
        pendant.open(QStringLiteral("/dev/ttyACM0"));   // auto-retries if absent
    }

    qInfo("[boot] XYLOSOME temporal scanning unit — Qt port ready");
    return app.exec();
}
