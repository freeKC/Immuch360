# The decoder probe of Immuch360 Desktop (../README.md): a DLL with a C interface that the Dart side calls through
# dart:ffi, so that the plugin registers nothing with Flutter (ffiPlugin in the pubspec); Flutter bundles it next to
# the executable through immuch_desktop_video_bundled_libraries.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "immuch_desktop_video")
project(${PROJECT_NAME} LANGUAGES CXX)

add_library(${PROJECT_NAME} SHARED "immuch_desktop_video.cpp")

# The app's settings for native code (C++17, warnings as errors, no exceptions), as the other plugins get them
apply_standard_settings(${PROJECT_NAME})
set_target_properties(${PROJECT_NAME} PROPERTIES OUTPUT_NAME "immuch_desktop_video")
target_compile_definitions(${PROJECT_NAME} PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
# d3d12.dll is loaded at run time instead (immuch_desktop_video.cpp, VideoDevice12)
target_link_libraries(${PROJECT_NAME} PRIVATE d3d11 dxgi)

set(immuch_desktop_video_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  PARENT_SCOPE
)
