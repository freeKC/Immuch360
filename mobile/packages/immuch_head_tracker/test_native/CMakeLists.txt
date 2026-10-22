# The head tracker built with gcc on Linux for its native tests (run.sh): the same sources as windows/CMakeLists.txt,
# with ht_no_media.cpp instead of the Media Foundation sources, and the two detector builds as shared libraries next to
# libimmuch_head_tracker.so. Not part of the app.
cmake_minimum_required(VERSION 3.14)
project(immuch_head_tracker_native_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/../src")
set(LIBFACEDETECTION "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libfacedetection/src")

add_library(immuch_head_tracker SHARED "${SOURCES}/ht_api.cpp" "${SOURCES}/ht_core.cpp" "${SOURCES}/ht_no_media.cpp")
target_include_directories(immuch_head_tracker PRIVATE "${SOURCES}")
target_compile_options(immuch_head_tracker PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
target_link_libraries(immuch_head_tracker PRIVATE dl pthread)

function(add_face_detector TARGET BUILD)
  add_library(${TARGET} SHARED "${SOURCES}/face_detect.cpp" "${LIBFACEDETECTION}/facedetectcnn.cpp"
              "${LIBFACEDETECTION}/facedetectcnn-model.cpp" "${LIBFACEDETECTION}/facedetectcnn-data.cpp")
  target_compile_definitions(${TARGET} PRIVATE FD_BUILD=${BUILD})
  target_compile_options(${TARGET} PRIVATE -fvisibility=hidden)
  target_include_directories(${TARGET} PRIVATE "${SOURCES}" "${LIBFACEDETECTION}")
endfunction()
add_face_detector(immuch_head_tracker_detect 1)
add_face_detector(immuch_head_tracker_detect_avx2 2)
target_compile_definitions(immuch_head_tracker_detect_avx2 PRIVATE _ENABLE_AVX2)
target_compile_options(immuch_head_tracker_detect_avx2 PRIVATE -mavx2 -mfma)

# The test links the core statically for its unit tests and the shared library for the tracker as a whole
add_executable(ht_core_test ht_core_test.cpp "${SOURCES}/ht_core.cpp")
target_include_directories(ht_core_test PRIVATE "${SOURCES}")
target_compile_options(ht_core_test PRIVATE -Wall -Wextra -Werror)
target_link_libraries(ht_core_test PRIVATE immuch_head_tracker dl pthread)
set_target_properties(ht_core_test PROPERTIES BUILD_RPATH "$ORIGIN")
