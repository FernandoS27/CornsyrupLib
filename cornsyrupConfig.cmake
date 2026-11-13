# CornSyrup C library: the imported target cornsyrup::cornsyrup, for the platform the project builds for.
#
#   find_package(cornsyrup CONFIG REQUIRED)    # this folder on CMAKE_PREFIX_PATH, or cornsyrup_DIR set to it
#   add_subdirectory(<this folder> cornsyrup)  # the same, through CMakeLists.txt
#
#   target_link_libraries(app PRIVATE cornsyrup::cornsyrup)
#   cornsyrup_copy_runtime(app)                    # the library and cfxlib/ beside app, after each build
#   cornsyrup_install_runtime(DESTINATION bin)     # the same, installed beside app
#
# The platform is the one the project's compiler targets: Windows, Linux or macOS, on x86_64 or arm64,
# or WebAssembly (WASI, through wasi-sdk's toolchain file), each with its folder in lib/.
# -DCORNSYRUP_PLATFORM=<folder> picks one by hand. On WebAssembly the library is a static one, linked
# into app with the standard library compiled in, so the two runtime functions have nothing to do.
#
# Sets cornsyrup_PLATFORM (the folder), cornsyrup_LIBRARY (the library in it: cornsyrup.dll,
# libcornsyrup.so, libcornsyrup.dylib or libcornsyrup.a), cornsyrup_INCLUDE_DIR and
# cornsyrup_CFXLIB_DIR. README.md beside this file says what the library needs at run time.

cmake_policy(PUSH)
cmake_policy(VERSION 3.16...3.31)

get_filename_component(_cornsyrup_root "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
set(_cornsyrup_error "")

# ---- The platform ----------------------------------------------------------------------------------
if(CORNSYRUP_PLATFORM)
    set(cornsyrup_PLATFORM "${CORNSYRUP_PLATFORM}")
else()
    set(_cornsyrup_os "")
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        set(_cornsyrup_os windows)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set(_cornsyrup_os linux)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        set(_cornsyrup_os macos)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "WASI")
        set(_cornsyrup_os wasi)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "")
        set(_cornsyrup_error "the platform is not known yet: call find_package(cornsyrup) after project()")
    else()
        set(_cornsyrup_error "there is no build of the library for ${CMAKE_SYSTEM_NAME}")
    endif()

    # The architecture: on macOS the one CMAKE_OSX_ARCHITECTURES asks for; then the compiler's
    # (MSVC's x64 or ARM64, which a Visual Studio -A or a cross-compiling prompt chooses, whatever
    # the machine is); then the processor the toolchain names.
    set(_cornsyrup_arch "")
    if(_cornsyrup_os STREQUAL "macos" AND CMAKE_OSX_ARCHITECTURES)
        list(LENGTH CMAKE_OSX_ARCHITECTURES _cornsyrup_count)
        if(_cornsyrup_count GREATER 1)
            set(_cornsyrup_error
                "CMAKE_OSX_ARCHITECTURES is ${CMAKE_OSX_ARCHITECTURES}, and the library is one build per "
                "architecture (lib/macos-arm64, lib/macos-x86_64): build one architecture at a time")
        endif()
        set(_cornsyrup_arch "${CMAKE_OSX_ARCHITECTURES}")
    endif()
    if(NOT _cornsyrup_arch)
        foreach(_cornsyrup_lang C CXX)
            if(CMAKE_${_cornsyrup_lang}_COMPILER_ARCHITECTURE_ID)
                set(_cornsyrup_arch "${CMAKE_${_cornsyrup_lang}_COMPILER_ARCHITECTURE_ID}")
                break()
            endif()
        endforeach()
    endif()
    if(NOT _cornsyrup_arch)
        set(_cornsyrup_arch "${CMAKE_GENERATOR_PLATFORM}")
    endif()
    if(NOT _cornsyrup_arch)
        set(_cornsyrup_arch "${CMAKE_SYSTEM_PROCESSOR}")
    endif()
    string(TOLOWER "${_cornsyrup_arch}" _cornsyrup_arch)
    if(_cornsyrup_arch MATCHES "^(x86_64|amd64|x64)$")
        set(_cornsyrup_arch x86_64)
    elseif(_cornsyrup_arch MATCHES "^(aarch64|arm64)$")
        set(_cornsyrup_arch arm64)
    elseif(_cornsyrup_arch STREQUAL "wasm32" AND _cornsyrup_os STREQUAL "wasi")
        # WebAssembly is 32-bit, and one build runs in every WASI runtime.
    elseif(NOT _cornsyrup_error)
        set(_cornsyrup_error "there is no build of the library for the architecture '${_cornsyrup_arch}' (x86_64 and arm64, and wasm32 on WASI)")
    endif()
    if(NOT _cornsyrup_error AND NOT _cornsyrup_os STREQUAL "wasi" AND CMAKE_SIZEOF_VOID_P AND NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
        set(_cornsyrup_error "the project builds for a 32-bit target, and the library is 64-bit only")
    endif()
    set(cornsyrup_PLATFORM "${_cornsyrup_os}-${_cornsyrup_arch}")
    unset(_cornsyrup_os)
    unset(_cornsyrup_arch)
    unset(_cornsyrup_count)
    unset(_cornsyrup_lang)
endif()

set(cornsyrup_INCLUDE_DIR "${_cornsyrup_root}/include")
set(cornsyrup_CFXLIB_DIR "${_cornsyrup_root}/cfxlib")
set(_cornsyrup_libdir "${_cornsyrup_root}/lib/${cornsyrup_PLATFORM}")
# The library's file is named as the platform names a shared library, with the name capi/build.rs
# puts inside it: the DLL's on Windows, the soname on Linux, the install name on macOS. WebAssembly
# has the static library, which a host links into its own module (lib/wasi-wasm32/ also holds
# cornsyrup.wasm, the module for a host that loads one rather than linking C).
if(cornsyrup_PLATFORM MATCHES "^windows-")
    set(_cornsyrup_name cornsyrup.dll)
elseif(cornsyrup_PLATFORM MATCHES "^macos-")
    set(_cornsyrup_name libcornsyrup.dylib)
elseif(cornsyrup_PLATFORM MATCHES "^wasi-")
    set(_cornsyrup_name libcornsyrup.a)
else()
    set(_cornsyrup_name libcornsyrup.so)
endif()
set(cornsyrup_LIBRARY "${_cornsyrup_libdir}/${_cornsyrup_name}")
if(NOT _cornsyrup_error AND NOT EXISTS "${cornsyrup_LIBRARY}")
    file(GLOB _cornsyrup_have RELATIVE "${_cornsyrup_root}/lib" "${_cornsyrup_root}/lib/*")
    string(REPLACE ";" ", " _cornsyrup_have "${_cornsyrup_have}")
    set(_cornsyrup_error "this package has no build for ${cornsyrup_PLATFORM} (lib/ holds ${_cornsyrup_have})")
    unset(_cornsyrup_have)
endif()

if(_cornsyrup_error)
    set(cornsyrup_FOUND FALSE)
    set(cornsyrup_NOT_FOUND_MESSAGE "cornsyrup: ${_cornsyrup_error}.")
    unset(_cornsyrup_root)
    unset(_cornsyrup_error)
    unset(_cornsyrup_libdir)
    unset(_cornsyrup_name)
    cmake_policy(POP)
    return()
endif()

# ---- The imported target ---------------------------------------------------------------------------
# GLOBAL, so the target is seen from the whole project whichever directory found it, and
# add_subdirectory's parent sees it too.
if(NOT TARGET cornsyrup::cornsyrup)
    if(cornsyrup_PLATFORM MATCHES "^wasi-")
        add_library(cornsyrup::cornsyrup STATIC IMPORTED GLOBAL)
    else()
        add_library(cornsyrup::cornsyrup SHARED IMPORTED GLOBAL)
    endif()
    set_target_properties(cornsyrup::cornsyrup PROPERTIES
        IMPORTED_LOCATION "${cornsyrup_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${cornsyrup_INCLUDE_DIR}"
        CORNSYRUP_CFXLIB_DIR "${cornsyrup_CFXLIB_DIR}")
    # The name inside the file, which the host records and its loader looks for: the import
    # library's DLL on Windows, the install name on macOS, the soname on Linux.
    if(cornsyrup_PLATFORM MATCHES "^windows-")
        set_target_properties(cornsyrup::cornsyrup PROPERTIES IMPORTED_IMPLIB "${_cornsyrup_libdir}/cornsyrup.lib")
    elseif(cornsyrup_PLATFORM MATCHES "^macos-")
        set_target_properties(cornsyrup::cornsyrup PROPERTIES IMPORTED_SONAME "@rpath/libcornsyrup.dylib")
    elseif(cornsyrup_PLATFORM MATCHES "^wasi-")
        # A WebAssembly program's stack is the size its link gives it, 64 KiB by default, after its
        # data, where running out writes over the data unnoticed. The program a host links the
        # library into gets CORNSYRUP_WASI_STACK_SIZE bytes, 1 MiB as cornsyrup.wasm has, at the
        # start of its memory, where running out traps. (The largest effects of the game convert
        # in under 20 KiB.)
        set(CORNSYRUP_WASI_STACK_SIZE 1048576 CACHE STRING
            "The stack, in bytes, of a WebAssembly program that links the CornSyrup library")
        set_target_properties(cornsyrup::cornsyrup PROPERTIES
            INTERFACE_LINK_OPTIONS "-Wl,--stack-first;-Wl,-z,stack-size=${CORNSYRUP_WASI_STACK_SIZE}")
    else()
        set_target_properties(cornsyrup::cornsyrup PROPERTIES IMPORTED_SONAME "libcornsyrup.so")
    endif()
endif()

# ---- What a host needs at run time ----------------------------------------------------------------
# The library, and the cfxlib/ its conversions read from beside it, copied beside <target>'s file
# after each build. On Linux and macOS <target> also gets an rpath to its own folder, so it finds the
# copy there once installed. On WebAssembly there is nothing to copy: the static library is in
# <target>, and the standard library in it.
function(cornsyrup_copy_runtime target)
    get_target_property(_type cornsyrup::cornsyrup TYPE)
    if(_type STREQUAL "STATIC_LIBRARY")
        return()
    endif()
    get_target_property(_library cornsyrup::cornsyrup IMPORTED_LOCATION)
    get_target_property(_cfxlib cornsyrup::cornsyrup CORNSYRUP_CFXLIB_DIR)
    get_filename_component(_name "${_library}" NAME)
    if(CMAKE_VERSION VERSION_LESS 3.26)
        set(_copy_dir copy_directory)
    else()
        set(_copy_dir copy_directory_if_different)
    endif()
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_library}" "$<TARGET_FILE_DIR:${target}>/${_name}"
        COMMAND "${CMAKE_COMMAND}" -E ${_copy_dir} "${_cfxlib}" "$<TARGET_FILE_DIR:${target}>/cfxlib"
        VERBATIM)
    if(APPLE)
        set_property(TARGET ${target} APPEND PROPERTY BUILD_RPATH "@loader_path")
        set_property(TARGET ${target} APPEND PROPERTY INSTALL_RPATH "@loader_path")
    elseif(NOT WIN32)
        set_property(TARGET ${target} APPEND PROPERTY BUILD_RPATH "$ORIGIN")
        set_property(TARGET ${target} APPEND PROPERTY INSTALL_RPATH "$ORIGIN")
    endif()
endfunction()

# cornsyrup_install_runtime(DESTINATION <dir> [COMPONENT <component>]): install the library and
# cfxlib/ in <dir>, which is the folder the host's executable is installed in. Nothing on
# WebAssembly, as above.
function(cornsyrup_install_runtime)
    cmake_parse_arguments(_arg "" "DESTINATION;COMPONENT" "" ${ARGN})
    if(NOT _arg_DESTINATION)
        message(FATAL_ERROR "cornsyrup_install_runtime: DESTINATION <dir> is required")
    endif()
    get_target_property(_type cornsyrup::cornsyrup TYPE)
    if(_type STREQUAL "STATIC_LIBRARY")
        return()
    endif()
    set(_component "")
    if(_arg_COMPONENT)
        set(_component COMPONENT "${_arg_COMPONENT}")
    endif()
    get_target_property(_library cornsyrup::cornsyrup IMPORTED_LOCATION)
    get_target_property(_cfxlib cornsyrup::cornsyrup CORNSYRUP_CFXLIB_DIR)
    install(PROGRAMS "${_library}" DESTINATION "${_arg_DESTINATION}" ${_component})
    install(DIRECTORY "${_cfxlib}/" DESTINATION "${_arg_DESTINATION}/cfxlib" ${_component})
endfunction()

unset(_cornsyrup_root)
unset(_cornsyrup_error)
unset(_cornsyrup_libdir)
unset(_cornsyrup_name)
cmake_policy(POP)
