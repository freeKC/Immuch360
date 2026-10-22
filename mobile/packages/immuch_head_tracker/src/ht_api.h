// The C interface of immuch_head_tracker.dll, called from Dart through dart:ffi (lib/src/native_head_tracker.dart
// mirrors every structure and constant here; a change on one side needs the same change on the other, and
// HT_API_VERSION goes up).
//
// A tracker turns frames into head samples: the grey image of each analysed frame is box filtered to 160 pixels on its
// long side, libfacedetection looks for faces in it, and the largest face gives the sample. Three sources feed a
// tracker. A webcam (ht_open_camera): Media Foundation on a capture thread of the DLL; the frames never leave that
// thread, nothing is written anywhere, and the caller only ever sees samples. A video file (ht_open_file), for the
// tests: the same source reader setup and the same Y plane path as the webcam, one frame per ht_next call, at the
// file's own timestamps. Raw grey frames (ht_open_frames and ht_process_frame), for the tests.
// The webcam and the file need Windows; on other systems those calls answer HT_E_NO_MEDIA_FOUNDATION, which lets the
// rest be built and tested with gcc (test_native/).

#ifndef IMMUCH_HEAD_TRACKER_HT_API_H_
#define IMMUCH_HEAD_TRACKER_HT_API_H_

#include <stdint.h>

#ifdef _WIN32
#define HT_EXPORT __declspec(dllexport)
#else
#define HT_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
#define HT_API extern "C" HT_EXPORT
#else
#define HT_API HT_EXPORT
#endif

#define HT_API_VERSION 1

// Status codes: 0 or more is success, every error is negative
#define HT_OK 0
// The camera is turned off for desktop apps in Settings, Privacy and security, Camera (E_ACCESSDENIED)
#define HT_E_ACCESS_DENIED (-1)
// mfplat.dll, mfreadwrite.dll or mf.dll is missing: a Windows N edition without the Media Feature Pack, a Windows
// Server without the Media Foundation feature, or not Windows at all
#define HT_E_NO_MEDIA_FOUNDATION (-2)
// No camera with that id, or no camera at all
#define HT_E_NO_CAMERA (-3)
// Another app holds the camera
#define HT_E_CAMERA_BUSY (-4)
// The camera went away while streaming (unplugged, disabled, the driver reset)
#define HT_E_DEVICE_LOST (-5)
// The face detector DLL could not be loaded
#define HT_E_NO_DETECTOR (-6)
// The AVX2 build of the detector was asked for on a processor or a Windows without AVX2
#define HT_E_NO_AVX2 (-7)
// The source gives no frame the tracker can read (no video stream, no decoder for it)
#define HT_E_FORMAT (-8)
// A bad argument (a null pointer, a size out of range)
#define HT_E_ARGUMENT (-9)
// Anything else; ht_info gives the HRESULT
#define HT_E_FAILED (-10)

// The detector builds
#define HT_DETECTOR_AUTO 0
#define HT_DETECTOR_PLAIN 1
#define HT_DETECTOR_AVX2 2

// The face state of a sample
#define HT_STATE_FACE 1
// No face in this frame, the last one less than 300 ms ago
#define HT_STATE_NO_FACE 2
// No face for more than 300 ms (or none since the start, after 300 ms)
#define HT_STATE_LOST 3

// What the tracker knows about Windows Studio Effects automatic framing on the camera
#define HT_FRAMING_UNKNOWN 0
// The camera has no automatic framing (or no extended controls)
#define HT_FRAMING_ABSENT 1
// Automatic framing was on and the tracker turned it off for its stream
#define HT_FRAMING_TURNED_OFF 2
// The camera has automatic framing and it was off already
#define HT_FRAMING_OFF 3
// Automatic framing is on and the driver did not let the tracker turn it off: the face stays centred
#define HT_FRAMING_STUCK_ON 4

// The options of a tracker. Zero means the default for every field.
typedef struct HtOptions {
  // HT_DETECTOR_*: AUTO takes the AVX2 build when the processor and Windows allow it, unless the environment variable
  // IMMUCH360_FACE_DETECTOR is "plain"
  int32_t detector;
  // Analyse one frame in this many (default 2: 15 analyses a second from a 30 fps camera)
  int32_t detect_every;
  // The lowest detector score, 0 to 100, that counts as a face (default 50)
  int32_t min_score;
  // The long side of the image the detector gets (default 160, at most 640)
  int32_t detect_long_side;
  // The camera stream asked for: the native format closest to this size and rate (default 640 x 480 at 30)
  int32_t width;
  int32_t height;
  int32_t fps;
  int32_t reserved;
} HtOptions;

// One analysed frame. Positions are normalised to the frame: x from 0 (left of the image as the camera delivers it,
// not mirrored) to 1, y from 0 (top) to 1. Without a face they are NaN.
typedef struct HtSample {
  // The frame's time in microseconds: the file's timestamp, the time given to ht_process_frame, or for a camera the
  // clock of ht_now_us when the frame reached the tracker
  int64_t time_us;
  // Analysed frames since the tracker opened, from 1
  int64_t sequence;
  double face_x;
  double face_y;
  double face_width;
  double face_height;
  // The detector score of the face, 0 to 1 (0 without a face)
  double confidence;
  // HT_STATE_*
  int32_t state;
  // How long the detector took, microseconds
  int32_t detect_us;
  // The size of the source frame
  int32_t frame_width;
  int32_t frame_height;
  // HT_OK, or the error that stopped a camera (the last sample then carries it)
  int32_t status;
  // Faces found in the frame (the sample describes the largest)
  int32_t faces;
} HtSample;

// What a tracker runs with
typedef struct HtInfo {
  // HT_DETECTOR_PLAIN or HT_DETECTOR_AVX2
  int32_t detector;
  // HT_FRAMING_*
  int32_t framing;
  // The stream as read: its size, its frame rate (numerator and denominator) and its native subtype as a FOURCC
  int32_t width;
  int32_t height;
  int32_t fps_numerator;
  int32_t fps_denominator;
  uint32_t native_fourcc;
  // The last HRESULT that failed, 0 when none
  int32_t hresult;
} HtInfo;

// Called on the capture thread after each analysed frame of a camera, and once with the error that stops it. It must
// return quickly: a Dart NativeCallable.listener, which only posts the call. The sample itself is read with ht_latest.
typedef void (*HtSampleCallback)(int64_t sequence, int32_t status);

HT_API int32_t ht_api_version(void);

// The clock of the camera samples, microseconds (QueryPerformanceCounter on Windows, CLOCK_MONOTONIC elsewhere)
HT_API int64_t ht_now_us(void);

// 1 when the AVX2 build of the detector can run here (AVX2, FMA, BMI1, BMI2 and an OS that saves the AVX state)
HT_API int32_t ht_cpu_avx2(void);

// The video cameras as JSON, [{"id": symbolic link, "name": friendly name}, ...], written to json (UTF-8, no NUL
// added). Returns the length of the JSON, which may be more than capacity (call again with a larger buffer), or an
// error. Opens no camera.
HT_API int32_t ht_list_cameras(char* json, int32_t capacity);

// Starts tracking with the camera whose id ht_list_cameras gave. Returns at once: the camera opens on the capture
// thread, and an error to open it comes through the callback (and ht_latest's status). Returns null and sets *status
// for an error found before that (no Media Foundation, no detector, bad arguments).
HT_API void* ht_open_camera(const char* id_utf8, const HtOptions* options, HtSampleCallback callback, int32_t* status);

// Opens a video file for the tests. Null and *status on error.
HT_API void* ht_open_file(const char* path_utf8, const HtOptions* options, int32_t* status);

// A tracker fed by ht_process_frame only. Null and *status on error.
HT_API void* ht_open_frames(const HtOptions* options, int32_t* status);

// File source: reads frames up to the next analysed one and writes its sample. 1 with a sample, 0 at the end of the
// file, or an error.
HT_API int32_t ht_next(void* tracker, HtSample* sample);

// Analyses one 8 bit grey frame (or the Y plane of a YUV frame) given at time_ns. Every frame given is analysed
// (detect_every does not apply). 1 with a sample, or an error.
HT_API int32_t ht_process_frame(void* tracker, const uint8_t* grey, int32_t width, int32_t height, int32_t stride,
                                int64_t time_ns, HtSample* sample);

// The newest sample of any tracker: 1 with one, 0 before the first.
HT_API int32_t ht_latest(void* tracker, HtSample* sample);

HT_API int32_t ht_info(void* tracker, HtInfo* info);

// Stops a camera (the camera is released and its light goes off before this returns, unless the driver hangs for more
// than two seconds) and frees the tracker. The callback is never called once this has returned.
HT_API void ht_close(void* tracker);

#endif  // IMMUCH_HEAD_TRACKER_HT_API_H_
