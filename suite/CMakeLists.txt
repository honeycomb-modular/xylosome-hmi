cmake_minimum_required(VERSION 3.21)

project(XylosomeSuite VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# Qt >= 6.2 (CI uses 6.8; 6.2 floor keeps stock Ubuntu 22.04 buildable)
find_package(Qt6 6.2 REQUIRED COMPONENTS Quick QuickControls2 Svg)

if(COMMAND qt_standard_project_setup)
    qt_standard_project_setup()
endif()

qt_add_executable(xylosome-suite
    src/main.cpp
    src/XylodLink.h
    src/XylodLink.cpp
    src/FolderWatcher.h
    src/FolderWatcher.cpp
    src/SessionStore.h
    src/SessionStore.cpp
)

qt_add_qml_module(xylosome-suite
    URI XylosomeSuite
    VERSION 1.0
    RESOURCE_PREFIX /qt/qml
    QML_FILES
        qml/Main.qml
    RESOURCES
        assets/hm_logo_black.svg
)

set_target_properties(xylosome-suite PROPERTIES
    WIN32_EXECUTABLE TRUE
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "Xylosome Suite"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.honeycomb-modular.xylosome-suite"
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
)

target_link_libraries(xylosome-suite PRIVATE
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Svg
)

install(TARGETS xylosome-suite
    BUNDLE DESTINATION .
    RUNTIME DESTINATION bin
)
