cmake_minimum_required(VERSION 3.16)
project(xylod VERSION 0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ──────────────────────────────────────────────────────────────────────────────
# SOEM — use the copy already installed on the C6920 if present
# (`sudo make install` from the SOEM repo), otherwise fetch v1.4.0.
# ──────────────────────────────────────────────────────────────────────────────
find_package(soem QUIET)
if(NOT soem_FOUND)
    include(FetchContent)
    FetchContent_Declare(soem
        GIT_REPOSITORY https://github.com/OpenEtherCATsociety/SOEM.git
        GIT_TAG        v1.4.0)
    set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(soem)
endif()

# nlohmann/json — header-only, system package or fetched
find_package(nlohmann_json 3.10 QUIET)
if(NOT nlohmann_json_FOUND)
    include(FetchContent)
    FetchContent_Declare(json
        URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz)
    FetchContent_MakeAvailable(json)
endif()

add_executable(xylod
    src/main.cpp
    src/Config.cpp
    src/SimBackend.cpp
    src/EcBackend.cpp
    src/Sequencer.cpp
    src/TcpServer.cpp
)
target_link_libraries(xylod PRIVATE soem nlohmann_json::nlohmann_json pthread)

# ── bench tools ───────────────────────────────────────────────────────────────
add_executable(ec_scan    ../tools/ec_scan.cpp)
target_link_libraries(ec_scan PRIVATE soem pthread)

add_executable(motor_test ../tools/motor_test.cpp)
target_link_libraries(motor_test PRIVATE soem pthread)

install(TARGETS xylod ec_scan motor_test RUNTIME DESTINATION /usr/local/bin)
