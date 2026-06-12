cmake_minimum_required(VERSION 3.16)
project(xylod VERSION 0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# SOEM v1.4.0 declares an ancient cmake_minimum_required; allow it on CMake ≥ 4
set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
# SOEM builds its C with -Werror; newer GCC flags a strncpy pattern in oshw.c
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wno-error=stringop-truncation")

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
    # SOEM 1.4.0 doesn't export include dirs on its target — attach them here
    target_include_directories(soem INTERFACE
        ${soem_SOURCE_DIR}/soem
        ${soem_SOURCE_DIR}/osal
        ${soem_SOURCE_DIR}/osal/linux
        ${soem_SOURCE_DIR}/oshw/linux)
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

add_executable(ec_blink   ../tools/ec_blink.cpp)
target_link_libraries(ec_blink PRIVATE soem pthread)

add_executable(ec_meter   ../tools/ec_meter.cpp)
target_link_libraries(ec_meter PRIVATE soem nlohmann_json::nlohmann_json pthread)

add_executable(ec_step    ../tools/ec_step.cpp)
target_link_libraries(ec_step PRIVATE soem pthread)

install(TARGETS xylod ec_scan motor_test ec_blink ec_meter ec_step RUNTIME DESTINATION /usr/local/bin)
