// The part of the head tracker that does not depend on a capture system: the processor check, the detector libraries,
// the clock, and the analysis of one frame (box filter of the luma plane, face detection, the face followed, its eye
// midpoint, the face state, the One Euro filter and its speed). gcc builds it on Linux for the native tests
// (test_native/); each system's library builds it with its capture source (ht_windows.cpp, ht_linux.cpp,
// ht_macos.mm).

#ifndef IMMUCH_HEAD_TRACKER_HT_CORE_H_
#define IMMUCH_HEAD_TRACKER_HT_CORE_H_

#include <stddef.h>
#include <stdint.h>

#include <algorithm>
#include <atomic>
#include <vector>

#include "face_detect.h"
#include "ht_api.h"

namespace ht {

// A face is lost after this long without a detection, as on the phones (HeadTracker.kt)
constexpr int64_t kLostAfterUs = 300000;
constexpr int32_t kMaxFaces = 16;
// The face followed under this many pixels wide in the detector image: the next frames go at twice the long side
constexpr int32_t kSmallFacePixels = 24;
// And back to the normal side once it is over this many at the doubled side
constexpr int32_t kLargeFacePixels = 64;
// The width of the image the One Euro filter's parameters are tuned for (HeadXFilter in head_viewpoint.dart)
constexpr double kFilterScale = 640.0;

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

// The requested build (HT_DETECTOR_*) loaded from the folder of immuch_head_tracker's own library, once per process
// (on macOS the detector is linked in: the slice of the processor, NEON on arm64). HT_OK, HT_E_NO_AVX2 or
// HT_E_NO_DETECTOR.
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

// The One Euro filter of the phones (OneEuroFilter.kt; one_euro_filter.dart is the Dart port), same steps, same
// constants, in doubles: test/desktop/spatial/head_tracker_native_test.dart checks it against the Kotlin values
class OneEuro {
 public:
  OneEuro(double min_cutoff = 1.0, double beta = 0.02, double derivative_cutoff = 1.0)
      : min_cutoff_(min_cutoff), beta_(beta), derivative_cutoff_(derivative_cutoff) {}

  // Filters [x] measured at [time_ns]
  double Filter(double x, int64_t time_ns);

  // The smoothed speed, in units of the signal per second (0 after a reset)
  double derivative() const { return derivative_; }

  void Reset() {
    has_value_ = false;
    derivative_ = 0;
  }

 private:
  double min_cutoff_;
  double beta_;
  double derivative_cutoff_;
  bool has_value_ = false;
  int64_t last_ns_ = 0;
  double value_ = 0;
  double derivative_ = 0;
};

// One face as the analysis sees it, in fractions of the frame
struct FaceCandidate {
  double score = 0;  // 0 to 100
  double x = 0;      // box centre
  double y = 0;
  double width = 0;  // box size
  double height = 0;
  double eye_x = 0;
  double eye_y = 0;
  double eye_distance = 0;
  // The box width in pixels of the detector image (0 for landmarks given as such)
  int32_t pixels = 0;
};

// The eye midpoint and distance of a detected face from its landmarks, in fractions of the detector image; the box
// centre and a third of its width when the eyes are missing or implausible (closer than a fifth of the box width, or
// outside it)
FaceCandidate CandidateOf(const FdFace& face, int32_t width, int32_t height);

// The prediction of ht_predict from a sample, at now_us
bool Predict(const HtSample& sample, int64_t now_us, double* head_x);

// The analysis of the frames of one tracker: frames in, samples out. Not thread safe: one source thread uses it;
// RequestRecenter may come from any thread.
class Core {
 public:
  Core(const Detector& detector, const HtOptions& options);

  // Counts a frame of the source and says whether it is to be analysed (one in detect_every, the first one included)
  bool CountFrame();

  // Analyses a frame seen at [time_us] into [sample]
  void Analyse(const LumaPlane& plane, int64_t time_us, HtSample* sample);

  // Analyses faces given as landmarks (a track line, ht_process_landmarks) seen at [time_us] into [sample]
  void AnalyseFaces(const HtFace* faces, int32_t count, int64_t time_us, HtSample* sample);

  // The next frame takes the largest face again and the filter starts afresh
  void RequestRecenter() { recenter_.store(true); }

  int32_t build() const { return detector_.build; }

  // The long side of the next detector image
  int32_t detect_long_side() const { return far_ ? std::min(options_.detect_long_side * 2, 640) : options_.detect_long_side; }

 private:
  // The sample of [count] candidates; [detect_width] the detector image's width (0 for landmarks)
  void Finish(const FaceCandidate* candidates, int32_t count, int64_t time_us, int32_t detect_width, HtSample* sample);
  void Begin(int64_t time_us, HtSample* sample);

  Detector detector_;
  HtOptions options_;
  int64_t frames_ = 0;
  int64_t sequence_ = 0;
  bool started_ = false;
  int64_t last_face_us_ = 0;
  bool was_lost_ = true;
  // The face followed: its eye midpoint and box width in the last frame that had it, none at the start
  bool following_ = false;
  double follow_x_ = 0;
  double follow_y_ = 0;
  double follow_width_ = 0;
  // Analysing at twice the long side for a small face
  bool far_ = false;
  std::atomic<bool> recenter_{false};
  OneEuro filter_;
  std::vector<uint8_t> small_;
  FdFace faces_[kMaxFaces];
  FaceCandidate candidates_[kMaxFaces];
};

}  // namespace ht

#endif  // IMMUCH_HEAD_TRACKER_HT_CORE_H_
