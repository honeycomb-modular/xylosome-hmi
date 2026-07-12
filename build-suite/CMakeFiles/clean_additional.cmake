# Additional clean files
cmake_minimum_required(VERSION 3.16)

if("${CONFIG}" STREQUAL "" OR "${CONFIG}" STREQUAL "Release")
  file(REMOVE_RECURSE
  "CMakeFiles\\xylosome-suite_autogen.dir\\AutogenUsed.txt"
  "CMakeFiles\\xylosome-suite_autogen.dir\\ParseCache.txt"
  "xylosome-suite_autogen"
  )
endif()
