# add_subdirectory(<this folder> cornsyrup) sets the CornSyrup C library up as find_package(cornsyrup)
# does: the imported target cornsyrup::cornsyrup, cornsyrup_copy_runtime and cornsyrup_install_runtime,
# and the cornsyrup_* variables, in the calling directory. See cornsyrupConfig.cmake.
cmake_minimum_required(VERSION 3.16...3.31)

include("${CMAKE_CURRENT_LIST_DIR}/cornsyrupConfigVersion.cmake")
set(cornsyrup_VERSION "${PACKAGE_VERSION}")
# The config sets cornsyrup_FOUND to FALSE when it refuses the platform. TRUE first: the one this
# directory inherits may be FALSE, from a find_package(cornsyrup QUIET) that did not find the
# package before the caller fell back to add_subdirectory.
set(cornsyrup_FOUND TRUE)
include("${CMAKE_CURRENT_LIST_DIR}/cornsyrupConfig.cmake")
if(NOT cornsyrup_FOUND)
    message(FATAL_ERROR "${cornsyrup_NOT_FOUND_MESSAGE}")
endif()

foreach(_var cornsyrup_FOUND cornsyrup_VERSION cornsyrup_PLATFORM cornsyrup_LIBRARY cornsyrup_INCLUDE_DIR cornsyrup_CFXLIB_DIR)
    set(${_var} "${${_var}}" PARENT_SCOPE)
endforeach()
