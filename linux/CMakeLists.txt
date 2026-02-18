# Project-level configuration.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
cmake_minimum_required(VERSION 3.13)

# Since we are building from the client, we need to point vcpkg to the core's manifest
if(NOT DEFINED VCPKG_MANIFEST_DIR)
    get_filename_component(NEBULA_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../nebula_core" ABSOLUTE)
    if(EXISTS "${NEBULA_CORE_DIR}/vcpkg.json" AND NOT DEFINED ENV{IN_NIX_SHELL})
        set(VCPKG_MANIFEST_DIR "${NEBULA_CORE_DIR}")
        message(STATUS "Setting VCPKG_MANIFEST_DIR to ${VCPKG_MANIFEST_DIR}")
    endif()
endif()

# Setup vcpkg toolchain
if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    if(DEFINED ENV{VCPKG_ROOT})
        set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake")
    elseif(DEFINED NEBULA_CORE_DIR AND EXISTS "${NEBULA_CORE_DIR}/vcpkg/scripts/buildsystems/vcpkg.cmake")
        set(CMAKE_TOOLCHAIN_FILE "${NEBULA_CORE_DIR}/vcpkg/scripts/buildsystems/vcpkg.cmake")
    endif()
endif()

if(DEFINED CMAKE_TOOLCHAIN_FILE)
    message(STATUS "Using vcpkg toolchain: ${CMAKE_TOOLCHAIN_FILE}")
else()
    message(WARNING "Vcpkg toolchain not found. Build may fail if dependencies are missing.")
endif()

# Fix for NixOS: Bypass pkg-config wrapper to allow vcpkg to work
if(DEFINED ENV{IN_NIX_SHELL})
    find_program(PKG_CONFIG_EXECUTABLE pkg-config)
    if(PKG_CONFIG_EXECUTABLE)
        # Check if it's a shell script (wrapper)
        file(READ "${PKG_CONFIG_EXECUTABLE}" PKG_CONFIG_CONTENT LIMIT 20)
        if(PKG_CONFIG_CONTENT MATCHES "^#!")
            # It's a script, try to extract the real binary path
            # We assume the wrapper execs the real binary
            execute_process(
                COMMAND grep -o "/nix/store/.*pkg-config.*/bin/pkg-config" "${PKG_CONFIG_EXECUTABLE}"
                COMMAND head -n1
                OUTPUT_VARIABLE REAL_PKG_CONFIG
                OUTPUT_STRIP_TRAILING_WHITESPACE
            )
            if(REAL_PKG_CONFIG)
                set(ENV{PKG_CONFIG} "${REAL_PKG_CONFIG}")
                message(STATUS "NixOS detected: Setting PKG_CONFIG to unwrapped binary: ${REAL_PKG_CONFIG}")
            else()
                message(WARNING "NixOS detected: Could not find unwrapped pkg-config in wrapper.")
            endif()
        endif()
    endif()
endif()

project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "nebula_client")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.nebula.nebula_client")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Import nebula_core from stable location
set(NEBULA_STABLE_LIB_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../nebula_core/linux/libnebula_core.so")

if(EXISTS "${NEBULA_STABLE_LIB_PATH}")
  install(FILES "${NEBULA_STABLE_LIB_PATH}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  message(STATUS "Loaded nebula_core from stable path: ${NEBULA_STABLE_LIB_PATH}")

  # Bundle dependencies from the same directory (e.g. vcpkg or nix-built libs)
  get_filename_component(NEBULA_CORE_LIB_DIR "${NEBULA_STABLE_LIB_PATH}" DIRECTORY)
  
  # Also check the build output directory in case they aren't synced to stable yet
  get_filename_component(NEBULA_CORE_BUILD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../nebula_core/build/lib" ABSOLUTE)

  # Path to external TDLib libraries
  set(TDLIB_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../nebula_core/external/tdlib/lib")

  file(GLOB CORE_DEPENDENCIES
    "${NEBULA_CORE_LIB_DIR}/libjsoncpp.so*"
    "${NEBULA_CORE_LIB_DIR}/libsqlcipher.so*"
    "${NEBULA_CORE_BUILD_DIR}/libjsoncpp.so*"
    "${NEBULA_CORE_BUILD_DIR}/libsqlcipher.so*"
    "${TDLIB_LIB_DIR}/libtdjson.so*"
  )
  if(CORE_DEPENDENCIES)
    install(FILES ${CORE_DEPENDENCIES}
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      COMPONENT Runtime)
    message(STATUS "Bundled core dependencies: ${CORE_DEPENDENCIES}")
  endif()
else()
  message(WARNING "nebula_core library not found at: ${NEBULA_STABLE_LIB_PATH}")
  message(WARNING "Building the core is required before building the client.")
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
if(EXISTS "${NATIVE_ASSETS_DIR}")
  install(DIRECTORY "${NATIVE_ASSETS_DIR}"
     DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
     COMPONENT Runtime)
endif()

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
