# GitRev.cmake — write a one-line header with the git revision of SRC_DIR.
#
# Run at BUILD time (not configure time) so a rebuild after `git pull` or a
# local edit picks up the new revision without reconfiguring:
#
#   add_custom_target(<name> ALL
#       COMMAND ${CMAKE_COMMAND} -DSRC_DIR=<dir> -DOUT=<file> -P GitRev.cmake)
#
# OUT is only rewritten when its content changes, so the one translation unit
# that includes it is not recompiled on every build.
#
# Format: <short hash>[-dirty] or "unknown" (no git, not a checkout).
# "dirty" ignores CR-at-EOL differences: the Pi and the C6920 checkouts differ
# from HEAD only by line endings and must not read as modified.

execute_process(
    COMMAND git -C "${SRC_DIR}" rev-parse --short=9 HEAD
    OUTPUT_VARIABLE rev
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE rc
    ERROR_QUIET)

if(NOT rc EQUAL 0 OR rev STREQUAL "")
    set(rev "unknown")
else()
    execute_process(
        COMMAND git -C "${SRC_DIR}" diff --ignore-cr-at-eol --name-only HEAD --
        OUTPUT_VARIABLE changed
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE drc
        ERROR_QUIET)
    if(drc EQUAL 0 AND NOT changed STREQUAL "")
        set(rev "${rev}-dirty")
    endif()
endif()

set(content "#pragma once\n#define GIT_REV \"${rev}\"\n")
set(old "")
if(EXISTS "${OUT}")
    file(READ "${OUT}" old)
endif()
if(NOT old STREQUAL content)
    file(WRITE "${OUT}" "${content}")
endif()
