cmake_minimum_required(VERSION 3.16)
project(xylosome_hmi VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# ──────────────────────────────────────────────────────────────────────────────
# Qt6 modules
# QHttpServer is optional (Qt ≥ 6.4, needs qt6-httpserver-dev on Pi).
# The build falls back to the built-in QTcpServer-based server if absent.
# ──────────────────────────────────────────────────────────────────────────────
find_package(Qt6 REQUIRED COMPONENTS Core Quick Network)
find_package(Qt6 OPTIONAL_COMPONENTS HttpServer)

qt_standard_project_setup(REQUIRES 6.2)

# ──────────────────────────────────────────────────────────────────────────────
# Mark Theme.qml as a QML singleton so it is accessible as Theme.ACCENT etc.
# (qt_add_qml_module picks this up automatically in Qt ≥ 6.4; for 6.2/6.3 it
# still works but the singleton pragma in Theme.qml does the heavy lifting.)
# ──────────────────────────────────────────────────────────────────────────────
set_source_files_properties(qml/Theme.qml PROPERTIES
    QT_QML_SINGLETON_TYPE TRUE
)

# ──────────────────────────────────────────────────────────────────────────────
# Executable + QML module (same target — Qt6 "inline" style)
# ──────────────────────────────────────────────────────────────────────────────
qt_add_executable(xylosome_hmi
    src/main.cpp
    src/MotorModel.h
    src/MotorModel.cpp
    src/HttpServer.h
    src/HttpServer.cpp
    src/MetadataRecorder.h
    src/MetadataRecorder.cpp
)

qt_add_qml_module(xylosome_hmi
    URI XylosomeHMI
    VERSION 1.0
    QML_FILES
        qml/Theme.qml
        qml/main.qml
        # ── Reusable components ──
        qml/Hairline.qml
        qml/NavRow.qml
        qml/LabelledValue.qml
        qml/TerminalButton.qml
        qml/BackButton.qml
        qml/FocusController.qml
        qml/FocusIndicator.qml
        qml/ChoiceList.qml
        # ── Screens ──
        qml/ScreenSplash.qml
        qml/ScreenHome.qml
        qml/ScreenLive.qml
        qml/ScreenScan.qml
        qml/ScreenCapture.qml
        qml/ScreenSettings.qml
        qml/ScreenMetadata.qml
        qml/ScreenPlaceholder.qml
        # ── Settings sub-pages ──
        qml/ScreenNetwork.qml
        qml/ScreenCamera.qml
        qml/ScreenAxis.qml
        qml/ScreenCalibration.qml
        qml/ScreenDisplay.qml
        qml/ScreenSystem.qml
        # ── Menu targets ──
        qml/ScreenPresets.qml
        qml/ScreenDevices.qml
    RESOURCES
        HMLOGO.png
        qml_bg.png
)

# ──────────────────────────────────────────────────────────────────────────────
# Link libraries
# ──────────────────────────────────────────────────────────────────────────────
target_link_libraries(xylosome_hmi PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::Network
)

if(TARGET Qt6::HttpServer)
    target_link_libraries(xylosome_hmi PRIVATE Qt6::HttpServer)
    target_compile_definitions(xylosome_hmi PRIVATE XYLOSOME_HAVE_HTTPSERVER)
    message(STATUS "[xylosome] QHttpServer found — using native HTTP server")
else()
    message(STATUS "[xylosome] QHttpServer not found — using QTcpServer fallback")
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Pi / embedded: keep RPATH so Qt libs resolve at runtime if installed in a
# non-standard prefix (e.g. /opt/qt6).
# ──────────────────────────────────────────────────────────────────────────────
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|armv7l")
    set_target_properties(xylosome_hmi PROPERTIES
        INSTALL_RPATH_USE_LINK_PATH TRUE
    )
endif()

install(TARGETS xylosome_hmi RUNTIME DESTINATION bin)
