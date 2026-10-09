# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)
cmake_policy(SET CMP0175 NEW)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)

# Deal with MSVC incompatiblity
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

# ------------------------------------------------------------------------------
# Immuch360: archives are checked by SHA-256 rather than MD5, which no longer protects against a crafted file.
function(download_and_verify url sha256 locationForArchive)
  # Check if the archive exists.
  if(EXISTS "${locationForArchive}")
    file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)

    # If SHA-256 doesn't match, delete the archive to download again.
    if(NOT sha256 STREQUAL ARCHIVE_SHA256)
      file(REMOVE "${locationForArchive}")
      message(STATUS "SHA-256 mismatch. File deleted.")
    endif()
  endif()

  # Download the archive if it doesn't exist.
  if(NOT EXISTS "${locationForArchive}")
    message(STATUS "Downloading archive from ${url}...")
    file(DOWNLOAD "${url}" "${locationForArchive}")
    message(STATUS "Downloaded archive to ${locationForArchive}.")

    # Verify SHA-256 of the newly downloaded file.
    file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)

    if(sha256 STREQUAL ARCHIVE_SHA256)
      message(STATUS "${locationForArchive} Verification successful.")
    else()
      message(FATAL_ERROR "${locationForArchive} Integrity check failed, please try to re-build project again.")
    endif()
  endif()
endfunction()

function(check_directory_exists_and_not_empty dir result_var)
  # Check if the directory exists
  if(EXISTS "${dir}")
    # Check if the directory is not empty
    file(GLOB dir_contents "${dir}/*")

    if(dir_contents)
      set(${result_var} TRUE PARENT_SCOPE)
    else()
      set(${result_var} FALSE PARENT_SCOPE)
      message(STATUS "Directory ${dir} exists but is empty!")
    endif()
  else()
    set(${result_var} FALSE PARENT_SCOPE)
    message(STATUS "Directory ${dir} does not exist!")
  endif()
endfunction()

# Immuch360: which libmpv the app bundles.
#   OFF (the default): media-kit's 2024 archive, the one media_kit_libs_windows_video 1.0.12 downloads (mpv
#       v0.39.0-179-g0f78584518, FFmpeg N-117622-g8d940a07d), now checked by SHA-256.
#   ON: the libmpv the fork rebuilds with .github/workflows/immuch360-libmpv.yml, with a recent FFmpeg and its
#       sources published next to it, pinned by the release and the SHA-256 values below.
# It stays OFF until that workflow has published a release and the values below are filled from the release's
# SHA256SUMS.txt (the run summary prints these lines); then the default here turns ON. The environment variable of the
# same name turns it on or off for one build without editing this file (win_flutter.sh --env IMMUCH360_LIBMPV_FROM_CI).
# The licences of both are in ../../media_kit_video/windows/NOTICES.md.
if(DEFINED ENV{IMMUCH360_LIBMPV_FROM_CI})
  set(IMMUCH360_LIBMPV_FROM_CI "$ENV{IMMUCH360_LIBMPV_FROM_CI}")
elseif(NOT DEFINED IMMUCH360_LIBMPV_FROM_CI)
  set(IMMUCH360_LIBMPV_FROM_CI OFF)
endif()
set(IMMUCH360_LIBMPV_RELEASES "https://github.com/freeKC/Immuch360/releases/download")
set(IMMUCH360_LIBMPV_TAG "")
set(IMMUCH360_LIBMPV_X64 "")
set(IMMUCH360_LIBMPV_X64_SHA256 "")
set(IMMUCH360_LIBMPV_ARM64 "")
set(IMMUCH360_LIBMPV_ARM64_SHA256 "")

# Detect architecture and set appropriate libmpv archive
if(${FLUTTER_TARGET_PLATFORM} STREQUAL "windows-x64")
  set(LIBMPV_ARCH "x86_64")
  set(LIBMPV_2024_SHA256 "e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007")
  set(LIBMPV_CI "${IMMUCH360_LIBMPV_X64}")
  set(LIBMPV_CI_SHA256 "${IMMUCH360_LIBMPV_X64_SHA256}")
else()
  set(LIBMPV_ARCH "aarch64")
  set(LIBMPV_2024_SHA256 "d445d02ab2ee60b1b5988f08ce4d2394cdcc594e98321b746a313313e96133ae")
  set(LIBMPV_CI "${IMMUCH360_LIBMPV_ARM64}")
  set(LIBMPV_CI_SHA256 "${IMMUCH360_LIBMPV_ARM64_SHA256}")
endif()

if(IMMUCH360_LIBMPV_FROM_CI)
  if(NOT IMMUCH360_LIBMPV_TAG OR NOT LIBMPV_CI OR NOT LIBMPV_CI_SHA256)
    message(FATAL_ERROR "IMMUCH360_LIBMPV_FROM_CI is on but no build of immuch360-libmpv.yml is pinned yet: fill "
      "IMMUCH360_LIBMPV_TAG and the archive names and SHA-256 values in ${CMAKE_CURRENT_LIST_FILE}")
  endif()
  set(LIBMPV "${LIBMPV_CI}")
  set(LIBMPV_SHA256 "${LIBMPV_CI_SHA256}")
  set(LIBMPV_URL "${IMMUCH360_LIBMPV_RELEASES}/${IMMUCH360_LIBMPV_TAG}/${LIBMPV}")
else()
  set(LIBMPV "mpv-dev-${LIBMPV_ARCH}-20241021-git-0f78584.7z")
  set(LIBMPV_SHA256 "${LIBMPV_2024_SHA256}")
  # Download URL for the libmpv archive from the latest release
  set(LIBMPV_URL "https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/${LIBMPV}")
endif()
message(STATUS "libmpv: ${LIBMPV}")

# Download location of the libmpv archive.
set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")

download_and_verify(
  ${LIBMPV_URL}
  ${LIBMPV_SHA256}
  ${LIBMPV_ARCHIVE}
)

# Immuch360: the extracted folder is marked with the hash of its archive, so that a change of archive (the switch
# above, a new pin) extracts again instead of bundling the DLL already there.
set(LIBMPV_STAMP "${LIBMPV_SRC}/.immuch360-${LIBMPV_SHA256}")
if(EXISTS "${LIBMPV_SRC}" AND NOT EXISTS "${LIBMPV_STAMP}")
  message(STATUS "${LIBMPV_SRC} came from another archive, extracting again.")
  file(REMOVE_RECURSE "${LIBMPV_SRC}")
endif()

check_directory_exists_and_not_empty(${LIBMPV_SRC} LIBMPV_SRC_VALID)

# Find 7zip for extraction (preferred for .7z files)
find_program(SEVENZ_EXECUTABLE NAMES 7z 7za)

# Extract the libmpv archive.
if(NOT LIBMPV_SRC_VALID)
  message(STATUS "Extracting ${LIBMPV}...")
  make_directory("${LIBMPV_SRC}")
  add_custom_target("${PROJECT_NAME}_LIBMPV_EXTRACT" ALL)
  
  if(SEVENZ_EXECUTABLE)
    message(STATUS "Using 7zip for extraction: ${SEVENZ_EXECUTABLE}")
    add_custom_command(
      TARGET "${PROJECT_NAME}_LIBMPV_EXTRACT"
      POST_BUILD
      COMMAND "${SEVENZ_EXECUTABLE}" x -y "\"${LIBMPV_ARCHIVE}\""
      COMMAND xcopy "\"${LIBMPV_SRC}/include/mpv\"" "\"${LIBMPV_SRC}/mpv\"" /E /H /C /I
      COMMAND rmdir "\"${LIBMPV_SRC}/include\"" /S /Q
      COMMAND ren "\"${LIBMPV_SRC}/mpv\"" "\"include\""
      COMMAND "${CMAKE_COMMAND}" -E touch "${LIBMPV_STAMP}"
      WORKING_DIRECTORY "${LIBMPV_SRC}"
    )
  else()
    message(STATUS "7zip not found, falling back to CMake tar")
    add_custom_command(
      TARGET "${PROJECT_NAME}_LIBMPV_EXTRACT"
      POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${LIBMPV_ARCHIVE}\""
      COMMAND xcopy "\"${LIBMPV_SRC}/include/mpv\"" "\"${LIBMPV_SRC}/mpv\"" /E /H /C /I
      COMMAND rmdir "\"${LIBMPV_SRC}/include\"" /S /Q
      COMMAND ren "\"${LIBMPV_SRC}/mpv\"" "\"include\""
      COMMAND "${CMAKE_COMMAND}" -E touch "${LIBMPV_STAMP}"
      WORKING_DIRECTORY "${LIBMPV_SRC}"
    )
  endif()
endif()

# ------------------------------------------------------------------------------

# ANGLE archive containing the pre-built shared libraries & headers.
set(ANGLE "ANGLE.7z")

# Download URL & SHA-256 hash of the ANGLE archive.
set(ANGLE_URL "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z")
set(ANGLE_SHA256 "cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a")

# Download location of the ANGLE archive.
set(ANGLE_ARCHIVE "${CMAKE_BINARY_DIR}/${ANGLE}")
set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")

download_and_verify(
  ${ANGLE_URL}
  ${ANGLE_SHA256}
  ${ANGLE_ARCHIVE}
)

check_directory_exists_and_not_empty(${ANGLE_SRC} ANGLE_SRC_VALID)

# Extract the ANGLE archive.
if(NOT ANGLE_SRC_VALID)
  message(STATUS "Extracting ${ANGLE}...")
  make_directory("${ANGLE_SRC}")
  add_custom_target("${PROJECT_NAME}_ANGLE_EXTRACT" ALL)
  
  if(SEVENZ_EXECUTABLE)
    message(STATUS "Using 7zip for extraction: ${SEVENZ_EXECUTABLE}")
    add_custom_command(
      TARGET "${PROJECT_NAME}_ANGLE_EXTRACT"
      POST_BUILD
      COMMAND "${SEVENZ_EXECUTABLE}" x -y "\"${ANGLE_ARCHIVE}\""
      WORKING_DIRECTORY "${ANGLE_SRC}"
    )
  else()
    message(STATUS "7zip not found, falling back to CMake tar")
    # Immuch360: POST_BUILD was missing here, which CMP0175 (set to NEW above) makes an error, so a machine without
    # 7z on its PATH could not configure the build at all
    add_custom_command(
      TARGET "${PROJECT_NAME}_ANGLE_EXTRACT"
      POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${ANGLE_ARCHIVE}\""
      WORKING_DIRECTORY "${ANGLE_SRC}"
    )
  endif()
endif()

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

# Immuch360: the zlib.dll of ANGLE.7z is not bundled. It is a debug build (it imports VCRUNTIME140D.dll and
# ucrtbased.dll, which only a machine with Visual Studio has), and no file of the folder imports it or names it, so
# nothing loads it. The release bundle check refuses a debug runtime: with it, no ZIP could be made.
set(
  media_kit_libs_windows_video_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  "${ANGLE_SRC}/d3dcompiler_47.dll"
  "${ANGLE_SRC}/libEGL.dll"
  "${ANGLE_SRC}/libGLESv2.dll"
  "${ANGLE_SRC}/vk_swiftshader.dll"
  "${ANGLE_SRC}/vulkan-1.dll"
  PARENT_SCOPE
)
