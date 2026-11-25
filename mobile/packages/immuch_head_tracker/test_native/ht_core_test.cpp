// Native tests of the head tracker, built with gcc on Linux (run.sh): the box filter, the detector size, the face state
// machine with a scripted detector, the eye midpoint, the face followed, the far switch, the One Euro filter against
// the phones' values, the prediction, the fake cameras, and the whole tracker (ht_open_frames, ht_process_frame, both
// detector builds) on the frames of the recorded clip, mobile/test/fixtures/video/painted-head-12s.mp4 (a public domain
// painted face moving along a known path, absent from 8 s to 9 s), and through the y4m fake camera.
//
//   ht_core_test <frames.y8> <width> <height> [clip.y4m] [track out]
//     frames: the clip's luma planes, one after the other; clip.y4m: the same clip for the fake camera; track out:
//     where to write the landmark track of the plain detector (the fixture painted-head-12s.track)

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <string>
#include <thread>
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
  CHECK(options.detect_every == 1 && options.min_score == 50 && options.detect_long_side == 160);
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

  // Every frame is analysed on a computer
  CHECK(core.CountFrame());
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

FdFace FaceWithEyes(int32_t score, int32_t x, int32_t y, int32_t w, int32_t h, int32_t rx, int32_t ry, int32_t lx,
                    int32_t ly) {
  FdFace face = Face(score, x, y, w, h);
  face.landmarks[0] = rx;
  face.landmarks[1] = ry;
  face.landmarks[2] = lx;
  face.landmarks[3] = ly;
  return face;
}

void TestEyesAndFollow() {
  HtOptions options;
  ht::NormaliseOptions(nullptr, &options);
  ht::Detector detector;
  detector.build = HT_DETECTOR_PLAIN;
  detector.detect = ScriptedDetect;
  ht::Core core(detector, options);
  std::vector<uint8_t> frame(640 * 480, 128);
  ht::LumaPlane plane;
  plane.data = frame.data();
  plane.width = 640;
  plane.height = 480;
  plane.stride = 640;
  HtSample sample;

  // The eye midpoint from the two eye landmarks, the box centre without them; head_x = 0.5 - eye_x
  g_script = {FaceWithEyes(90, 60, 30, 40, 48, 70, 50, 90, 52)};
  core.Analyse(plane, 1000000, &sample);
  CHECK(sample.state == HT_STATE_FACE && sample.detect_width == 160);
  CHECK(fabs(sample.eye_x - 80.0 / 160) < 1e-9 && fabs(sample.eye_y - 51.0 / 120) < 1e-9);
  CHECK(fabs(sample.eye_distance - sqrt(404.0) / 160) < 1e-9);
  CHECK(fabs(sample.head_x - (0.5 - 80.0 / 160)) < 1e-9);
  // The first face passes through the filter as it is
  CHECK(sample.filtered_x == sample.head_x && sample.velocity_x == 0);
  g_script = {Face(90, 60, 30, 40, 48)};
  core.Analyse(plane, 1033000, &sample);
  CHECK(fabs(sample.eye_x - 80.0 / 160) < 1e-9 && fabs(sample.eye_distance - 40.0 / 3 / 160) < 1e-9);

  // A larger face appears behind: the face followed stays the one nearest the last
  g_script = {Face(95, 0, 0, 58, 70), Face(90, 62, 30, 40, 48)};
  core.Analyse(plane, 1066000, &sample);
  CHECK(sample.faces == 2 && fabs(sample.face_x - 82.0 / 160) < 1e-9);
  // A face under half the size followed is never taken, even alone
  g_script = {Face(95, 64, 30, 16, 16)};
  core.Analyse(plane, 1100000, &sample);
  CHECK(sample.state == HT_STATE_NO_FACE && sample.faces == 1);
  // Recenter: the largest face again
  core.RequestRecenter();
  g_script = {Face(95, 0, 0, 58, 70), Face(90, 62, 30, 40, 48)};
  core.Analyse(plane, 1133000, &sample);
  CHECK(sample.state == HT_STATE_FACE && fabs(sample.face_x - 29.0 / 160) < 1e-9);
  // The filter started afresh at the recenter
  CHECK(sample.filtered_x == sample.head_x);

  // A small face (a user far from the screen): the next frames are analysed at 320, then back at 160 once it is large
  core.RequestRecenter();
  g_script = {Face(90, 70, 50, 20, 22)};
  core.Analyse(plane, 1166000, &sample);
  CHECK(sample.detect_width == 160 && core.detect_long_side() == 320);
  g_script = {Face(90, 140, 100, 70, 80)};
  core.Analyse(plane, 1200000, &sample);
  CHECK(sample.detect_width == 320 && core.detect_long_side() == 160);
}

void TestOneEuro() {
  // The first rows of head_viewpoint_vectors.json "oneEuro", printed by OneEuroFilter.kt: [timeNanos, x, filtered]
  const double rows[3][3] = {{1066666667, 315.0, 315.0},
                             {1134333334, 338.8669330795061, 328.5790281118382},
                             {1203000001, 361.9418342308651, 351.9211186133617}};
  ht::OneEuro filter;
  for (const auto& row : rows) {
    const double value = filter.Filter(row[1], static_cast<int64_t>(row[0]));
    CHECK(fabs(value - row[2]) < 1e-9);
  }
}

void TestPredict() {
  HtSample sample;
  memset(&sample, 0, sizeof(sample));
  sample.state = HT_STATE_FACE;
  sample.time_us = 1000000;
  sample.filtered_x = 0.1;
  sample.velocity_x = 0.5;
  sample.confidence = 0.9;
  double x = 0;
  CHECK(ht::Predict(sample, 1020000, &x) && fabs(x - 0.11) < 1e-12);
  // At most 40 ms ahead, never behind
  CHECK(ht::Predict(sample, 1100000, &x) && fabs(x - 0.12) < 1e-12);
  CHECK(ht::Predict(sample, 900000, &x) && fabs(x - 0.1) < 1e-12);
  // The speed kept under 2 a second
  sample.velocity_x = 10;
  CHECK(ht::Predict(sample, 1040000, &x) && fabs(x - 0.18) < 1e-12);
  // No move when the detector is unsure, nothing without a face
  sample.confidence = 0.55;
  CHECK(ht::Predict(sample, 1040000, &x) && fabs(x - 0.1) < 1e-12);
  sample.state = HT_STATE_NO_FACE;
  CHECK(!ht::Predict(sample, 1040000, &x));
}

std::atomic<int> g_signals{0};
std::atomic<int> g_last_status{0};

void Signal(int64_t sequence, int32_t status) {
  (void)sequence;
  g_signals++;
  g_last_status = status;
}

// Waits up to [seconds] for the session to stop on an error
bool WaitStopped(double seconds) {
  const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
  while (std::chrono::steady_clock::now() < end) {
    if (g_last_status.load() < 0) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return false;
}

void TestTrackCamera(const char* folder) {
  // A track of 2 s at 30 fps: a face moving right, lost from 1 s, two faces at the end (the larger one behind)
  const std::string path = std::string(folder) + "/test.track";
  FILE* file = fopen(path.c_str(), "w");
  CHECK(file != nullptr);
  if (file == nullptr) {
    return;
  }
  fprintf(file, "# time_us score eye_x eye_y eye_distance\n");
  for (int i = 0; i < 60; i++) {
    const int64_t t = static_cast<int64_t>(i) * 33333;
    if (i < 30) {
      fprintf(file, "%lld 90 %.4f 0.45 0.08\n", static_cast<long long>(t), 0.3 + i * 0.005);
    } else if (i < 50) {
      fprintf(file, "%lld\n", static_cast<long long>(t));
    } else {
      fprintf(file, "%lld 95 0.8 0.4 0.2, 90 0.5 0.45 0.08\n", static_cast<long long>(t));
    }
  }
  fclose(file);
  g_signals = 0;
  g_last_status = 0;
  int32_t status = 0;
  const std::string id = "track:" + path;
  void* tracker = ht_open_camera(id.c_str(), nullptr, Signal, &status);
  CHECK(tracker != nullptr && status == HT_OK);
  if (tracker == nullptr) {
    return;
  }
  const bool stopped = WaitStopped(5);
  CHECK(stopped && g_last_status.load() == HT_E_DEVICE_LOST);
  HtSample latest;
  CHECK(ht_latest(tracker, &latest) == 1);
  // 60 samples, then the end of the track; the last face is the largest one, the first after the loss
  CHECK(g_signals.load() == 61);
  CHECK(latest.status == HT_E_DEVICE_LOST && latest.state == HT_STATE_FACE && fabs(latest.eye_x - 0.8) < 1e-9);
  ht_close(tracker);

  // Closed while it plays: ht_close returns at once and no callback follows
  g_signals = 0;
  g_last_status = 0;
  tracker = ht_open_camera(id.c_str(), nullptr, Signal, &status);
  CHECK(tracker != nullptr);
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  const auto start = std::chrono::steady_clock::now();
  ht_close(tracker);
  const double took = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
  const int after_close = g_signals.load();
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  CHECK(took < 0.5 && g_signals.load() == after_close && after_close > 0);

  // A missing track: the error comes through the callback
  g_signals = 0;
  g_last_status = 0;
  tracker = ht_open_camera("track:/nonexistent/x.track", nullptr, Signal, &status);
  CHECK(tracker != nullptr && WaitStopped(2) && g_last_status.load() == HT_E_NO_CAMERA);
  ht_close(tracker);
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

// The clip through the y4m fake camera: the same thread and callback as a webcam, at the clip's 15 frames a second
void TestY4mCamera(const char* clip) {
  g_signals = 0;
  g_last_status = 0;
  int32_t status = 0;
  const std::string id = std::string("y4m:") + clip;
  void* tracker = ht_open_camera(id.c_str(), nullptr, Signal, &status);
  CHECK(tracker != nullptr && status == HT_OK);
  if (tracker == nullptr) {
    return;
  }
  int faces = 0, frames = 0;
  int64_t last = 0;
  const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (g_last_status.load() >= 0 && std::chrono::steady_clock::now() < end) {
    HtSample sample;
    if (ht_latest(tracker, &sample) == 1 && sample.sequence != last && sample.status == HT_OK) {
      frames += static_cast<int>(sample.sequence - last);
      last = sample.sequence;
      if (sample.state == HT_STATE_FACE) {
        faces++;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  HtInfo info;
  ht_info(tracker, &info);
  printf("y4m fake camera: %d callbacks, %d samples read while it played, %d of them with a face, %d x %d at %d/%d, "
         "ended with %d\n",
         g_signals.load(), frames, faces, info.width, info.height, info.fps_numerator, info.fps_denominator,
         g_last_status.load());
  CHECK(g_last_status.load() == HT_E_DEVICE_LOST);
  // 180 frames and the end; the samples read by polling may miss one, as a page reading at its own pace would
  CHECK(g_signals.load() == 181 && frames >= 170 && faces >= 150);
  ht_close(tracker);
}

// The landmark track of a run, one line per frame, as the fake camera "track:" reads it
void WriteTrack(const Run& run, const char* path) {
  FILE* file = fopen(path, "w");
  CHECK(file != nullptr);
  if (file == nullptr) {
    return;
  }
  fprintf(file, "# The landmark track of test/fixtures/video/painted-head-12s.mp4: the plain detector of the head tracker\n");
  fprintf(file, "# on each frame (test_native/run.sh), one line per frame: time in microseconds, then score, eye\n");
  fprintf(file, "# midpoint x and y and eye distance (fractions of the frame) of the face followed; none in the gap.\n");
  for (size_t i = 0; i < run.samples.size(); i++) {
    const HtSample& s = run.samples[i];
    const long long t = static_cast<long long>(i) * 1000000 / 15;
    if (s.state == HT_STATE_FACE) {
      fprintf(file, "%lld %d %.5f %.5f %.5f\n", t, static_cast<int>(lround(s.confidence * 100)), s.eye_x, s.eye_y,
              s.eye_distance);
    } else {
      fprintf(file, "%lld\n", t);
    }
  }
  fclose(file);
}

}  // namespace

int main(int argc, char** argv) {
  TestDetectSize();
  TestBoxFilter();
  TestCoreStates();
  TestEyesAndFollow();
  TestOneEuro();
  TestPredict();
  CHECK(ht_api_version() == HT_API_VERSION);
  int32_t status = 0;
  CHECK(ht_open_file("x.mp4", nullptr, &status) == nullptr && status == HT_E_NO_MEDIA_FOUNDATION);
  // V4L2: the JSON of the webcams (none on a build machine: "[]")
  char json[4096];
  const int32_t listed = ht_list_cameras(json, sizeof(json));
  CHECK(listed >= 2 && listed <= static_cast<int32_t>(sizeof(json)) && json[0] == '[' && json[listed - 1] == ']');
  printf("webcams: %.*s\n", listed, json);
  // A file: no system reader of video files on Linux, refused at once
  CHECK(ht_open_camera("file:/tmp/x.mp4", nullptr, Signal, &status) == nullptr &&
        status == HT_E_NO_MEDIA_FOUNDATION);
  // Not a webcam node: the error comes through the callback, as for a webcam that cannot open
  g_last_status = 0;
  void* missing = ht_open_camera("/tmp/x", nullptr, Signal, &status);
  CHECK(missing != nullptr && WaitStopped(2) && g_last_status.load() == HT_E_NO_CAMERA);
  ht_close(missing);
  const char* folder = getenv("TMPDIR") != nullptr ? getenv("TMPDIR") : "/tmp";
  TestTrackCamera(folder);
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

  if (argc >= 4) {
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
    if (argc >= 5) {
      TestY4mCamera(argv[4]);
    }
    if (argc >= 6 && plain.ok) {
      WriteTrack(plain, argv[5]);
    }
  }
  if (g_failures != 0) {
    fprintf(stderr, "%d checks failed\n", g_failures);
    return 1;
  }
  printf("all checks passed\n");
  return 0;
}
