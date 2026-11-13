# The version of the CornSyrup C library in this package, for find_package(cornsyrup <version>).
# Written by `cargo xtask capi` from capi/package/cornsyrupConfigVersion.cmake.in.
#
# A request is met by this version or a later one of the same major version; a range, by a version
# in it of the same major version as its lower end.

set(PACKAGE_VERSION "1.5.0")
string(REGEX MATCH "^[0-9]+" _cornsyrup_major "${PACKAGE_VERSION}")

set(PACKAGE_VERSION_COMPATIBLE FALSE)
set(PACKAGE_VERSION_EXACT FALSE)
if(PACKAGE_FIND_VERSION_RANGE)
    if(PACKAGE_FIND_VERSION_MIN_MAJOR STREQUAL _cornsyrup_major
       AND PACKAGE_VERSION VERSION_GREATER_EQUAL PACKAGE_FIND_VERSION_MIN
       AND ((PACKAGE_FIND_VERSION_RANGE_MAX STREQUAL "INCLUDE" AND PACKAGE_VERSION VERSION_LESS_EQUAL PACKAGE_FIND_VERSION_MAX)
            OR (PACKAGE_FIND_VERSION_RANGE_MAX STREQUAL "EXCLUDE" AND PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION_MAX)))
        set(PACKAGE_VERSION_COMPATIBLE TRUE)
    endif()
elseif(PACKAGE_FIND_VERSION)
    if(PACKAGE_FIND_VERSION_MAJOR STREQUAL _cornsyrup_major AND PACKAGE_VERSION VERSION_GREATER_EQUAL PACKAGE_FIND_VERSION)
        set(PACKAGE_VERSION_COMPATIBLE TRUE)
    endif()
    if(PACKAGE_FIND_VERSION VERSION_EQUAL PACKAGE_VERSION)
        set(PACKAGE_VERSION_EXACT TRUE)
    endif()
else()
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
unset(_cornsyrup_major)
