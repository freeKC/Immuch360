// Native tests of the head tracker, built with gcc on Linux (run.sh): the box filter, the detector size, the face state
// machine with a scripted detector, and the whole tracker (ht_open_frames, ht_process_frame, both detector builds) on
// the frames of the recorded clip, mobile/test/fixtures/video/painted-head-12s.mp4 (a public domain painted face moving
// along a known path, absent from 8 s to 9 s).
//
//   ht_core_test <frames.y8> <width> <height>     frames: the clip's luma planes, one after the other

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <vector>

#include "ht_api.h"
#include "ht_core.h"

namespace {

int g_failures = 0;

#define CHECK(condition)                                                \
  do {                                                                  \
    if (!(condition)) {                                                 \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
      g_failures++;                                                     \
    }                                                                   \
  } while (0)

void TestDetectSize() {
  int32_t w = 0, h = 0;
  ht::DetectSize(640, 480, 160, &w, &h);
  CHECK(w == 160 && h == 120);
  ht::DetectSize(1280, 720, 160, &w, &h);
  CHECK(w == 160 && h == 90);
  ht::DetectSize(480, 640, 160, &w, &h);
  CHECK(w == 120 && h == 160);
  ht::DetectSize(100, 80, 160, &w, &h);
  CHECK(w == 100 && h == 80);
}

void TestBoxFilter() {
  // 4 x 4 into 2 x 2: each output pixel is the rounded mean of its 2 x 2 block
  const uint8_t grey[16] = {0, 2, 10, 10, 4, 6, 10, 11, 100, 100, 255, 255, 100, 101, 255, 254};
  uint8_t out[4] = {0, 0, 0, 0};
  ht::LumaPlane plane;
  plane.data = grey;
  plane.width = 4;
  plane.height = 4;
  plane.stride = 4;
  ht::BoxFilter(plane, 2, 2, out);
  CHECK(out[0] == 3 && out[1] == 10 && out[2] == 100 && out[3] == 255);

  // YUY2: the luma is every other byte, from the first
  const uint8_t yuy2[16] = {10, 99, 20, 99, 30, 99, 40, 99, 50, 99, 60, 99, 70, 99, 80, 99};
  plane.data = yuy2;
  plane.width = 4;
  plane.height = 2;
  plane.stride = 8;
  plane.pixel_step = 2;
  uint8_t one[1] = {0};
  ht::BoxFilter(plane, 1, 1, one);
  CHECK(one[0] == 45);

  // Bottom up rows: a negative stride from the last row in memory
  const uint8_t rows[8] = {1, 1, 1, 1, 9, 9, 9, 9};
  plane.data = rows + 4;
  plane.width = 4;
  plane.height = 2;
  plane.stride = -4;
  plane.pixel_step = 1;
  uint8_t two[2] = {0, 0};
  ht::BoxFilter(plane, 1, 2, two);
  CHECK(two[0] == 9 && two[1] == 1);
}

// A scripted detector: the faces of the next call
std::vector<FdFace> g_script;

int32_t ScriptedDetect(const uint8_t*, int32_t, int32_t, int32_t, FdFace* faces, int32_t max_faces) {
  const int32_t n = std::min<int32_t>(static_cast<int32_t>(g_script.size()), max_faces);
  for (int32_t i = 0; i < n; i++) {
    faces[i] = g_script[static_cast<size_t>(i)];
  }
  return n;
}

FdFace Face(int32_t score, int32_t x, int32_t y, int32_t w, int32_t h) {
  FdFace face;
  memset(&face, 0, sizeof(face));
  face.score = score;
  face.x = x;
  face.y = y;
  face.width = w;
  face.height = h;
  return face;
}

void TestCoreStates() {
  HtOptions options;
  ht::NormaliseOptions(nullptr, &options);
  CHECK(options.detect_every == 2 && options.min_score == 50 && options.detect_long_side == 160);
  ht::Detector detector;
  detector.build = HT_DETECTOR_PLAIN;
  detector.detect = ScriptedDetect;
  ht::Core core(detector, options);
  std::vector<uint8_t> frame(320 * 240, 128);
  ht::LumaPlane plane;
  plane.data = frame.data();
  plane.width = 320;
  plane.height = 240;
  plane.stride = 320;
  HtSample sample;

  // One frame in two is analysed, the first one included
  CHECK(core.CountFrame());
  CHECK(!core.CountFrame());
  CHECK(core.CountFrame());

  // No face from the start: no face, then lost once 300 ms have passed
  g_script.clear();
  core.Analyse(plane, 1000000, &sample);
  CHECK(sample.state == HT_STATE_NO_FACE && sample.sequence == 1 && isnan(sample.face_x));
  core.Analyse(plane, 1300000, &sample);
  CHECK(sample.state == HT_STATE_NO_FACE);
  core.Analyse(plane, 1300001, &sample);
  CHECK(sample.state == HT_STATE_LOST);

  // The largest face scoring at least min_score, normalised to the detector image (160 x 120)
  g_script = {Face(90, 10, 10, 20, 20), Face(95, 80, 30, 40, 48), Face(40, 0, 0, 100, 100)};
  core.Analyse(plane, 2000000, &sample);
  CHECK(sample.state == HT_STATE_FACE && sample.faces == 2);
  CHECK(fabs(sample.face_x - 100.0 / 160) < 1e-9 && fabs(sample.face_y - 54.0 / 120) < 1e-9);
  CHECK(fabs(sample.face_width - 40.0 / 160) < 1e-9 && fabs(sample.confidence - 0.95) < 1e-9);
  CHECK(sample.frame_width == 320 && sample.frame_height == 240 && sample.time_us == 2000000);

  // Then none: held for 300 ms, lost after
  g_script.clear();
  core.Analyse(plane, 2300000, &sample);
  CHECK(sample.state == HT_STATE_NO_FACE);
  core.Analyse(plane, 2300001, &sample);
  CHECK(sample.state == HT_STATE_LOST);
  g_script = {Face(60, 0, 0, 20, 20)};
  core.Analyse(plane, 2400000, &sample);
  CHECK(sample.state == HT_STATE_FACE && sample.sequence == 7);
}

// The clip: where the painted face is, as the fraction of the width of its centre, or a negative number in the gap
double TruthX(int frame) {
  const double t = frame / 15.0;
  double x;
  if (t < 8) {
    x = 105 + 90 * sin(2 * M_PI * t / 4);
  } else if (t < 9) {
    return -1;
  } else {
    x = 105 + 40 * sin(2 * M_PI * (t - 9) / 3);
  }
  return (x + 55) / 320;
}

struct Run {
  std::vector<HtSample> samples;
  bool ok = false;
};

Run RunClip(int32_t detector, const std::vector<uint8_t>& frames, int32_t width, int32_t height) {
  Run run;
  HtOptions options;
  memset(&options, 0, sizeof(options));
  options.detector = detector;
  int32_t status = 0;
  void* tracker = ht_open_frames(&options, &status);
  if (tracker == nullptr) {
    fprintf(stderr, "ht_open_frames(%d): %d\n", detector, status);
    return run;
  }
  HtInfo info;
  ht_info(tracker, &info);
  CHECK(info.detector == detector);
  const size_t size = static_cast<size_t>(width) * height;
  const int count = static_cast<int>(frames.size() / size);
  for (int i = 0; i < count; i++) {
    HtSample sample;
    const int64_t time_ns = static_cast<int64_t>(i) * 1000000000LL / 15;
    if (ht_process_frame(tracker, frames.data() + size * i, width, height, width, time_ns, &sample) != 1) {
      fprintf(stderr, "ht_process_frame failed at %d\n", i);
      ht_close(tracker);
      return run;
    }
    run.samples.push_back(sample);
  }
  HtSample latest;
  CHECK(ht_latest(tracker, &latest) == 1 && latest.sequence == count);
  ht_close(tracker);
  run.ok = true;
  return run;
}

void CheckClip(const Run& run, const char* name) {
  int holding = 0, found = 0, false_faces = 0;
  std::vector<double> errors, times;
  int first_lost = -1;
  for (size_t i = 0; i < run.samples.size(); i++) {
    const HtSample& s = run.samples[i];
    const double truth = TruthX(static_cast<int>(i));
    times.push_back(s.detect_us / 1000.0);
    if (truth < 0) {
      if (s.state == HT_STATE_FACE) {
        false_faces++;
      }
      if (s.state == HT_STATE_LOST && first_lost < 0) {
        first_lost = static_cast<int>(i);
      }
      continue;
    }
    holding++;
    if (s.state == HT_STATE_FACE) {
      found++;
      errors.push_back(fabs(s.face_x - truth));
    }
  }
  std::sort(errors.begin(), errors.end());
  std::sort(times.begin(), times.end());
  const double median = errors.empty() ? 1 : errors[errors.size() / 2];
  const double worst = errors.empty() ? 1 : errors.back();
  printf("%s: faces %d of %d, false faces in the gap %d, lost from frame %d, centre error median %.4f max %.4f of the "
         "width, detection median %.2f ms p95 %.2f ms\n",
         name, found, holding, false_faces, first_lost, median, worst, times[times.size() / 2],
         times[times.size() * 95 / 100]);
  CHECK(found * 100 >= holding * 95);
  CHECK(false_faces == 0);
  // The last face is frame 119 (7.933 s): lost once more than 300 ms passed, frame 124 (8.267 s)
  CHECK(first_lost == 124);
  CHECK(run.samples[120].state == HT_STATE_NO_FACE && run.samples[123].state == HT_STATE_NO_FACE);
  CHECK(worst < 0.02);
}

}  // namespace

int main(int argc, char** argv) {
  TestDetectSize();
  TestBoxFilter();
  TestCoreStates();
  CHECK(ht_api_version() == HT_API_VERSION);
  int32_t status = 0;
  CHECK(ht_open_file("x.mp4", nullptr, &status) == nullptr && status == HT_E_NO_MEDIA_FOUNDATION);
  CHECK(ht_list_cameras(nullptr, 0) == HT_E_NO_MEDIA_FOUNDATION);
  HtOptions bad;
  memset(&bad, 0, sizeof(bad));
  bad.detect_every = -1;
  CHECK(ht_open_frames(&bad, &status) == nullptr && status == HT_E_ARGUMENT);
  // The colour only flag is the one flag there is: it passes, any other bit is refused
  HtOptions flags;
  memset(&flags, 0, sizeof(flags));
  flags.flags = HT_FLAG_COLOUR_ONLY;
  HtOptions kept;
  CHECK(ht::NormaliseOptions(&flags, &kept) && kept.flags == HT_FLAG_COLOUR_ONLY);
  flags.flags = 2;
  CHECK(!ht::NormaliseOptions(&flags, &kept));
  CHECK(ht_open_frames(&flags, &status) == nullptr && status == HT_E_ARGUMENT);

  if (argc == 4) {
    const int32_t width = atoi(argv[2]);
    const int32_t height = atoi(argv[3]);
    FILE* file = fopen(argv[1], "rb");
    CHECK(file != nullptr);
    std::vector<uint8_t> frames;
    if (file != nullptr) {
      uint8_t buffer[65536];
      size_t n;
      while ((n = fread(buffer, 1, sizeof(buffer), file)) > 0) {
        frames.insert(frames.end(), buffer, buffer + n);
      }
      fclose(file);
    }
    printf("%zu frames of %d x %d, AVX2 build usable: %d\n", frames.size() / (static_cast<size_t>(width) * height),
           width, height, ht_cpu_avx2());
    Run plain = RunClip(HT_DETECTOR_PLAIN, frames, width, height);
    CHECK(plain.ok);
    if (plain.ok) {
      CheckClip(plain, "plain");
    }
    if (ht_cpu_avx2()) {
      Run avx2 = RunClip(HT_DETECTOR_AVX2, frames, width, height);
      CHECK(avx2.ok);
      if (avx2.ok && plain.ok) {
        CheckClip(avx2, "avx2");
        int differ = 0;
        double largest = 0;
        for (size_t i = 0; i < plain.samples.size(); i++) {
          if (plain.samples[i].state != avx2.samples[i].state) {
            differ++;
          } else if (plain.samples[i].state == HT_STATE_FACE) {
            largest = std::max(largest, fabs(plain.samples[i].face_x - avx2.samples[i].face_x));
          }
        }
        printf("plain against avx2: %d states differ, centres at most %.5f apart\n", differ, largest);
        CHECK(differ == 0 && largest <= 1.0 / 160);
      }
    }
  }
  if (g_failures != 0) {
    fprintf(stderr, "%d checks failed\n", g_failures);
    return 1;
  }
  printf("all checks passed\n");
  return 0;
}
