// libfacedetection's CMake generates this header to export facedetect_cnn from its own library. Here the library is
// built into the detector DLLs of immuch_head_tracker, which export fd_build and fd_detect only (face_detect.h).
#pragma once
#define FACEDETECTION_EXPORT
