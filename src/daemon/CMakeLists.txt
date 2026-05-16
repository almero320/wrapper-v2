cmake_minimum_required(VERSION 3.22)
project(daemon LANGUAGES CXX)

# This sub-build is invoked by the top-level CMakeLists.txt with the NDK
# toolchain pre-configured. It produces the chrooted daemon binary 'main'.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

# -----------------------------------------------------------------------------
# Third-party deps
# -----------------------------------------------------------------------------
# cpp-httplib: header-only HTTP/1.1 server. MIT license.
FetchContent_Declare(
    httplib
    GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
    GIT_TAG        v0.18.5
    GIT_SHALLOW    TRUE
)
set(HTTPLIB_COMPILE OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(httplib)

# nlohmann::json: JSON parser/serializer. MIT license.
FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG        v3.11.3
    GIT_SHALLOW    TRUE
)
set(JSON_BuildTests OFF CACHE INTERNAL "")
FetchContent_MakeAvailable(nlohmann_json)

# Dobby (optional): function hooking for debug-only cert-pinning bypass.
option(WRAPPER_DEBUG_HOOKS "Build with Dobby-based debug hooks" OFF)
if(WRAPPER_DEBUG_HOOKS)
    FetchContent_Declare(
        dobby
        GIT_REPOSITORY https://github.com/jmpews/Dobby.git
        GIT_TAG        master
        GIT_SHALLOW    TRUE
    )
    set(DOBBY_BUILD_EXAMPLE OFF CACHE BOOL "" FORCE)
    set(DOBBY_BUILD_TEST    OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(dobby)
endif()

# -----------------------------------------------------------------------------
# Daemon executable
# -----------------------------------------------------------------------------
add_executable(main
    main.cpp
)

target_include_directories(main PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(main PRIVATE
    httplib::httplib
    nlohmann_json::nlohmann_json
)

if(WRAPPER_DEBUG_HOOKS)
    target_link_libraries(main PRIVATE dobby)
    target_compile_definitions(main PRIVATE WRAPPER_DEBUG_HOOKS=1)
endif()

target_compile_options(main PRIVATE
    -Wall -Wextra -Wpedantic -Werror=return-type
    -fno-rtti
    -fexceptions
)

# Our vendored `linker64` is from an older Android build that requires
# DT_HASH and does not understand GNU-hash-only executables. NDK r23b's
# default is `--hash-style=gnu`, which produces only DT_GNU_HASH and trips
# the linker with "empty/missing DT_HASH in <argv[0]>". Force `both` so the
# daemon ELF carries both hash sections - works with old and new linkers.
target_link_options(main PRIVATE
    -Wl,--hash-style=both
)

# Phase 0: the daemon does NOT yet link against Apple's libs. That comes in
# Phase 1 once we have the C++ symbol bindings written. LIBS_DIR is forwarded
# from the top level for use by future link scripts; we only validate it for
# now, to fail fast if the build environment is missing libs.
if(DEFINED LIBS_DIR)
    if(NOT EXISTS "${LIBS_DIR}/libstoreservicescore.so")
        message(WARNING
            "LIBS_DIR='${LIBS_DIR}' has no libstoreservicescore.so. "
            "This is fine for Phase 0 (no Apple-lib calls yet) but Phase 1 "
            "will require tools/extract-libs.sh to be run first.")
    endif()
endif()

set_target_properties(main PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)
