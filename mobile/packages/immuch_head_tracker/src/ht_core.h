// The part of the head tracker that does not depend on Windows: the processor check, the detector DLLs, the clock,
// and the analysis of one frame (box filter of the luma plane, face detection, face state). gcc builds it on Linux for
// the native tests (test_native/); immuch_head_tracker.dll builds it with the Media Foundation sources
// (ht_windows.cpp).

#ifndef IMMUCH_HEAD_TRACKER_HT_CORE_H_
#define IMMUCH_HEAD_TRACKER_HT_CORE_H_

#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "face_detect.h"
#include "ht_api.h"

namespace ht {

// A face is lost after this long without a detection, as on the phones (HeadTracker.kt)
constexpr int64_t kLostAfterUs = 300000;
constexpr int32_t kMaxFaces = 16;

// A loaded detector DLL
struct Detector {
  int32_t build = 0;
  FdDetectFunction detect = nullptr;
};

// The AVX2 build can run: AVX2, FMA, BMI1, BMI2, LZCNT and MOVBE (what /arch:AVX2 may use) on the processor, and the
// AVX registers saved by the system (OSXSAVE, XCR0 bits 1 and 2)
bool CpuHasAvx2();

// Microseconds of a monotonic clock
int64_t NowUs();

// The requested build (HT_DETECTOR_*) loaded from the folder of immuch_head_tracker's own library, once per process.
// HT_OK, HT_E_NO_AVX2 or HT_E_NO_DETECTOR.
int32_t LoadDetector(int32_t requested, Detector* detector);

// The options with their defaults filled in and their ranges checked; false when one is out of range
bool NormaliseOptions(const HtOptions* given, HtOptions* options);

// How the luma of a frame is laid out: one byte per pixel (NV12, I420, YV12, grey) or every other byte (YUY2 at
// offset 0, UYVY at offset 1), rows [stride] bytes apart (negative for a bottom up image)
struct LumaPlane {
  const uint8_t* data = nullptr;
  int32_t width = 0;
  int32_t height = 0;
  ptrdiff_t stride = 0;
  int32_t pixel_step = 1;
};

// The size of the detector image for a frame: [long_side] pixels on the long side (never more than the frame), the
// aspect ratio kept
void DetectSize(int32_t width, int32_t height, int32_t long_side, int32_t* out_width, int32_t* out_height);

// Box filter (area average over whole source pixels) of the luma plane into a [width] x [height] grey image
void BoxFilter(const LumaPlane& plane, int32_t width, int32_t height, uint8_t* out);

// The analysis of the frames of one tracker: frames in, samples out. Not thread safe: one source thread uses it.
class Core {
 public:
  Core(const Detector& detector, const HtOptions& options);

  // Counts a frame of the source and says whether it is to be analysed (one in detect_every, the first one included)
  bool CountFrame();

  // Analyses a frame seen at [time_us] into [sample]
  void Analyse(const LumaPlane& plane, int64_t time_us, HtSample* sample);

  int32_t build() const { return detector_.build; }

 private:
  Detector detector_;
  HtOptions options_;
  int64_t frames_ = 0;
  int64_t sequence_ = 0;
  bool started_ = false;
  int64_t last_face_us_ = 0;
  std::vector<uint8_t> small_;
  FdFace faces_[kMaxFaces];
};

}  // namespace ht

#endif  // IMMUCH_HEAD_TRACKER_HT_CORE_H_
