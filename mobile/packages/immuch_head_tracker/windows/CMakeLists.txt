# The head tracker of Spatial 2.5D on Windows (../README.md): three DLLs with a C interface, called through dart:ffi
# (ffiPlugin in the pubspec: nothing is registered with Flutter), bundled next to the executable through
# immuch_head_tracker_bundled_libraries.
#   immuch_head_tracker.dll                  the webcam and file sources (Media Foundation, loaded at run time) and
#                                            the analysis of the frames (../src)
#   immuch_head_tracker_detect.dll           libfacedetection (../third_party/libfacedetection), plain x86_64
#   immuch_head_tracker_detect_avx2.dll      the same with its AVX2 code: the library chooses its SIMD code when it is
#                                            compiled, so the tracker picks one of the two at run time (cpuid, xgetbv)
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "immuch_head_tracker")
project(${PROJECT_NAME} LANGUAGES CXX)

set(HEAD_TRACKER_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/../src")
set(LIBFACEDETECTION "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libfacedetection/src")

add_library(${PROJECT_NAME} SHARED
  "${HEAD_TRACKER_SOURCES}/ht_api.cpp"
  "${HEAD_TRACKER_SOURCES}/ht_core.cpp"
  "${HEAD_TRACKER_SOURCES}/ht_windows.cpp"
)
# The app's settings for native code (C++17, warnings as errors, no exceptions), as the other plugins get them
apply_standard_settings(${PROJECT_NAME})
set_target_properties(${PROJECT_NAME} PROPERTIES OUTPUT_NAME "immuch_head_tracker")
target_compile_definitions(${PROJECT_NAME} PRIVATE NOMINMAX)
target_include_directories(${PROJECT_NAME} PRIVATE "${HEAD_TRACKER_SOURCES}")
# mfplat, mfreadwrite and mf are loaded at run time (ht_windows.cpp); mfuuid holds the GUIDs of their headers only.
# cfgmgr32 reads where a camera sits (its panel), and is part of every Windows edition.
target_link_libraries(${PROJECT_NAME} PRIVATE ole32 mfuuid cfgmgr32)

# libfacedetection is third party code: its own warnings are not the app's, so it does not get the app's /W4 /WX
function(add_face_detector TARGET BUILD)
  add_library(${TARGET} SHARED
    "${HEAD_TRACKER_SOURCES}/face_detect.cpp"
    "${LIBFACEDETECTION}/facedetectcnn.cpp"
    "${LIBFACEDETECTION}/facedetectcnn-model.cpp"
    "${LIBFACEDETECTION}/facedetectcnn-data.cpp"
  )
  target_compile_features(${TARGET} PRIVATE cxx_std_17)
  target_compile_definitions(${TARGET} PRIVATE FD_BUILD=${BUILD} _CRT_SECURE_NO_WARNINGS NOMINMAX)
  target_compile_options(${TARGET} PRIVATE /wd4244 /wd4267 /wd4305)
  target_include_directories(${TARGET} PRIVATE "${HEAD_TRACKER_SOURCES}" "${LIBFACEDETECTION}")
  set_target_properties(${TARGET} PROPERTIES OUTPUT_NAME "${TARGET}")
endfunction()

add_face_detector(immuch_head_tracker_detect 1)
add_face_detector(immuch_head_tracker_detect_avx2 2)
target_compile_definitions(immuch_head_tracker_detect_avx2 PRIVATE _ENABLE_AVX2)
target_compile_options(immuch_head_tracker_detect_avx2 PRIVATE /arch:AVX2)

set(immuch_head_tracker_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  $<TARGET_FILE:immuch_head_tracker_detect>
  $<TARGET_FILE:immuch_head_tracker_detect_avx2>
  PARENT_SCOPE
)
