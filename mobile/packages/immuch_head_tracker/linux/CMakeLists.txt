# The head tracker of Spatial 2.5D on Linux (../README.md): three shared libraries with a C interface, called through
# dart:ffi (ffiPlugin in the pubspec: nothing is registered with Flutter), bundled in the lib folder of the app through
# immuch_head_tracker_bundled_libraries.
#   libimmuch_head_tracker.so               the webcams through V4L2 (uncompressed formats), the fake cameras of the
#                                           tests and the analysis of the frames (../src)
#   libimmuch_head_tracker_detect.so        libfacedetection (../third_party/libfacedetection), plain
#   libimmuch_head_tracker_detect_avx2.so   the same with its AVX2 code (x86_64 only): the library chooses its SIMD
#                                           code when it is compiled, so the tracker picks one at run time (cpuid)
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "immuch_head_tracker")
project(${PROJECT_NAME} LANGUAGES CXX)

set(HEAD_TRACKER_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/../src")
set(LIBFACEDETECTION "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libfacedetection/src")

add_library(${PROJECT_NAME} SHARED
  "${HEAD_TRACKER_SOURCES}/ht_api.cpp"
  "${HEAD_TRACKER_SOURCES}/ht_core.cpp"
  "${HEAD_TRACKER_SOURCES}/ht_fake.cpp"
  "${HEAD_TRACKER_SOURCES}/ht_linux.cpp"
)
# The app's settings for native code (C++14 or later, -Wall -Werror), as the other plugins get them
apply_standard_settings(${PROJECT_NAME})
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_VISIBILITY_PRESET hidden)
target_include_directories(${PROJECT_NAME} PRIVATE "${HEAD_TRACKER_SOURCES}")
target_link_libraries(${PROJECT_NAME} PRIVATE dl pthread)

# libfacedetection is third party code: its own warnings are not the app's, so it does not get -Werror
function(add_face_detector TARGET BUILD)
  add_library(${TARGET} SHARED
    "${HEAD_TRACKER_SOURCES}/face_detect.cpp"
    "${LIBFACEDETECTION}/facedetectcnn.cpp"
    "${LIBFACEDETECTION}/facedetectcnn-model.cpp"
    "${LIBFACEDETECTION}/facedetectcnn-data.cpp"
  )
  set_target_properties(${TARGET} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_VISIBILITY_PRESET hidden)
  target_compile_definitions(${TARGET} PRIVATE FD_BUILD=${BUILD})
  target_compile_options(${TARGET} PRIVATE -O3)
  target_include_directories(${TARGET} PRIVATE "${HEAD_TRACKER_SOURCES}" "${LIBFACEDETECTION}")
endfunction()

add_face_detector(immuch_head_tracker_detect 1)
set(DETECTORS $<TARGET_FILE:immuch_head_tracker_detect>)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
  add_face_detector(immuch_head_tracker_detect_avx2 2)
  target_compile_definitions(immuch_head_tracker_detect_avx2 PRIVATE _ENABLE_AVX2)
  target_compile_options(immuch_head_tracker_detect_avx2 PRIVATE -mavx2 -mfma)
  list(APPEND DETECTORS $<TARGET_FILE:immuch_head_tracker_detect_avx2>)
endif()

set(immuch_head_tracker_bundled_libraries
  $<TARGET_FILE:${PROJECT_NAME}>
  ${DETECTORS}
  PARENT_SCOPE
)
