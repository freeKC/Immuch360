// The interface of the two face detector DLLs, immuch_head_tracker_detect.dll (plain x86_64) and
// immuch_head_tracker_detect_avx2.dll (AVX2): libfacedetection compiled twice, because the library chooses its SIMD
// code at compile time only. immuch_head_tracker.dll loads one of them at run time (ht_core.cpp, LoadDetector) after
// checking the processor, so that a computer without AVX2 never loads code it cannot run.

#ifndef IMMUCH_HEAD_TRACKER_FACE_DETECT_H_
#define IMMUCH_HEAD_TRACKER_FACE_DETECT_H_

#include <stdint.h>

#ifdef _WIN32
#define FD_EXPORT __declspec(dllexport)
#else
#define FD_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
#define FD_API extern "C" FD_EXPORT
#else
#define FD_API FD_EXPORT
#endif

// One face, in pixels of the image given
typedef struct FdFace {
  // libfacedetection's score, 0 to 100
  int32_t score;
  int32_t x;
  int32_t y;
  int32_t width;
  int32_t height;
  // Right eye, left eye, nose tip, right and left corners of the mouth, as (x, y) pairs
  int32_t landmarks[10];
} FdFace;

// 1 for the plain build, 2 for the AVX2 build (HT_DETECTOR_PLAIN and HT_DETECTOR_AVX2)
FD_API int32_t fd_build(void);

// Finds the faces of an 8 bit grey image, at most max_faces of them, in the detector's order. Returns their number, or
// -1 for a bad argument. Calls are serialised inside the DLL: libfacedetection sets up its weights on first use
// without a lock.
FD_API int32_t fd_detect(const uint8_t* grey, int32_t width, int32_t height, int32_t stride, FdFace* faces,
                         int32_t max_faces);

typedef int32_t (*FdBuildFunction)(void);
typedef int32_t (*FdDetectFunction)(const uint8_t* grey, int32_t width, int32_t height, int32_t stride, FdFace* faces,
                                    int32_t max_faces);

#endif  // IMMUCH_HEAD_TRACKER_FACE_DETECT_H_
