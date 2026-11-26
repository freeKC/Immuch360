#include "ht_core.h"

#include <math.h>
#include <string.h>

#include <algorithm>
#include <mutex>
#include <string>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#include <stdlib.h>
#include <time.h>
#endif
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#define HT_X86 1
#ifdef _MSC_VER
#include <immintrin.h>
#include <intrin.h>
#else
#include <cpuid.h>
#endif
#endif

namespace ht {

namespace {

// Its address finds the library this code is in
int g_anchor = 0;

#ifdef HT_X86
void Cpuid(int32_t leaf, int32_t subleaf, uint32_t registers[4]) {
#ifdef _MSC_VER
  int values[4] = {0, 0, 0, 0};
  __cpuidex(values, leaf, subleaf);
  for (int i = 0; i < 4; i++) {
    registers[i] = static_cast<uint32_t>(values[i]);
  }
#else
  unsigned int a = 0, b = 0, c = 0, d = 0;
  __cpuid_count(static_cast<unsigned int>(leaf), static_cast<unsigned int>(subleaf), a, b, c, d);
  registers[0] = a;
  registers[1] = b;
  registers[2] = c;
  registers[3] = d;
#endif
}

uint64_t Xcr0() {
#ifdef _MSC_VER
  return _xgetbv(0);
#else
  uint32_t eax = 0, edx = 0;
  __asm__ volatile("xgetbv" : "=a"(eax), "=d"(edx) : "c"(0));
  return (static_cast<uint64_t>(edx) << 32) | eax;
#endif
}

bool DetectAvx2() {
  uint32_t r[4] = {0, 0, 0, 0};
  Cpuid(0, 0, r);
  if (r[0] < 7) {
    return false;
  }
  Cpuid(1, 0, r);
  const uint32_t ecx1 = r[2];
  const bool fma = (ecx1 & (1u << 12)) != 0;
  const bool movbe = (ecx1 & (1u << 22)) != 0;
  const bool osxsave = (ecx1 & (1u << 27)) != 0;
  const bool avx = (ecx1 & (1u << 28)) != 0;
  if (!(fma && movbe && osxsave && avx)) {
    return false;
  }
  // The system saves the SSE and AVX registers on a thread switch
  if ((Xcr0() & 0x6) != 0x6) {
    return false;
  }
  Cpuid(7, 0, r);
  const uint32_t ebx7 = r[1];
  const bool bmi1 = (ebx7 & (1u << 3)) != 0;
  const bool avx2 = (ebx7 & (1u << 5)) != 0;
  const bool bmi2 = (ebx7 & (1u << 8)) != 0;
  if (!(bmi1 && avx2 && bmi2)) {
    return false;
  }
  Cpuid(static_cast<int32_t>(0x80000000u), 0, r);
  if (r[0] < 0x80000001u) {
    return false;
  }
  Cpuid(static_cast<int32_t>(0x80000001u), 0, r);
  return (r[2] & (1u << 5)) != 0;  // LZCNT
}
#else
bool DetectAvx2() { return false; }
#endif

// "plain" in IMMUCH360_FACE_DETECTOR: the automatic choice takes the plain build (for a support case, and for the
// tests that compare the two builds)
bool PlainForced() {
#ifdef _WIN32
  wchar_t value[16] = {0};
  const DWORD length = GetEnvironmentVariableW(L"IMMUCH360_FACE_DETECTOR", value, 16);
  return length > 0 && length < 16 && _wcsicmp(value, L"plain") == 0;
#else
  const char* value = getenv("IMMUCH360_FACE_DETECTOR");
  return value != nullptr && strcmp(value, "plain") == 0;
#endif
}

#if defined(HT_STATIC_DETECTOR)
// macOS: the detector is linked into the framework, one slice per processor (face_detect.cpp)
#elif defined(_WIN32)
// The detector DLL next to immuch_head_tracker.dll, whatever the current folder
bool LoadFromOwnFolder(const wchar_t* name, Detector* detector) {
  HMODULE self = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCWSTR>(&g_anchor), &self)) {
    return false;
  }
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(self, &path[0], static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return false;
  }
  path.resize(length);
  const size_t slash = path.find_last_of(L"\\/");
  path = (slash == std::wstring::npos ? std::wstring() : path.substr(0, slash + 1)) + name;
  HMODULE module = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (module == nullptr) {
    return false;
  }
  auto build = reinterpret_cast<FdBuildFunction>(reinterpret_cast<void*>(GetProcAddress(module, "fd_build")));
  auto detect = reinterpret_cast<FdDetectFunction>(reinterpret_cast<void*>(GetProcAddress(module, "fd_detect")));
  if (build == nullptr || detect == nullptr) {
    FreeLibrary(module);
    return false;
  }
  detector->build = build();
  detector->detect = detect;
  return true;
}
#else
bool LoadFromOwnFolder(const char* name, Detector* detector) {
  Dl_info info;
  if (dladdr(&g_anchor, &info) == 0 || info.dli_fname == nullptr) {
    return false;
  }
  std::string path(info.dli_fname);
  const size_t slash = path.find_last_of('/');
  path = (slash == std::string::npos ? std::string() : path.substr(0, slash + 1)) + name;
  void* module = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (module == nullptr) {
    return false;
  }
  auto build = reinterpret_cast<FdBuildFunction>(dlsym(module, "fd_build"));
  auto detect = reinterpret_cast<FdDetectFunction>(dlsym(module, "fd_detect"));
  if (build == nullptr || detect == nullptr) {
    dlclose(module);
    return false;
  }
  detector->build = build();
  detector->detect = detect;
  return true;
}
#endif

}  // namespace

bool CpuHasAvx2() {
  static const bool has = DetectAvx2();
  return has;
}

int64_t NowUs() {
#ifdef _WIN32
  static LARGE_INTEGER frequency = [] {
    LARGE_INTEGER value;
    QueryPerformanceFrequency(&value);
    return value;
  }();
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  const int64_t seconds = counter.QuadPart / frequency.QuadPart;
  const int64_t rest = counter.QuadPart % frequency.QuadPart;
  return seconds * 1000000 + rest * 1000000 / frequency.QuadPart;
#else
  timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return static_cast<int64_t>(now.tv_sec) * 1000000 + now.tv_nsec / 1000;
#endif
}

int32_t LoadDetector(int32_t requested, Detector* detector) {
#if defined(HT_STATIC_DETECTOR)
  if (requested == HT_DETECTOR_AVX2) {
    return HT_E_NO_AVX2;
  }
  detector->build = fd_build();
  detector->detect = fd_detect;
  return HT_OK;
#else
  static std::mutex mutex;
  // Index 1 the plain build, 2 the AVX2 build; each loaded once and kept for the life of the process
  static Detector loaded[3];
  static bool tried[3] = {false, false, false};
  int32_t build = requested;
  if (build == HT_DETECTOR_AUTO) {
    build = (!PlainForced() && CpuHasAvx2()) ? HT_DETECTOR_AVX2 : HT_DETECTOR_PLAIN;
  }
  if (build != HT_DETECTOR_PLAIN && build != HT_DETECTOR_AVX2) {
    return HT_E_ARGUMENT;
  }
  if (build == HT_DETECTOR_AVX2 && !CpuHasAvx2()) {
    return HT_E_NO_AVX2;
  }
  std::lock_guard<std::mutex> lock(mutex);
  auto load = [](int32_t which) {
    if (tried[which]) {
      return;
    }
    tried[which] = true;
#ifdef _WIN32
    const wchar_t* name =
        which == HT_DETECTOR_AVX2 ? L"immuch_head_tracker_detect_avx2.dll" : L"immuch_head_tracker_detect.dll";
#else
    const char* name =
        which == HT_DETECTOR_AVX2 ? "libimmuch_head_tracker_detect_avx2.so" : "libimmuch_head_tracker_detect.so";
#endif
    Detector found;
    if (LoadFromOwnFolder(name, &found) && found.build == which) {
      loaded[which] = found;
    }
  };
  load(build);
  // The automatic choice falls back on the plain build when the AVX2 one is missing
  if (loaded[build].detect == nullptr && requested == HT_DETECTOR_AUTO && build == HT_DETECTOR_AVX2) {
    build = HT_DETECTOR_PLAIN;
    load(build);
  }
  if (loaded[build].detect == nullptr) {
    return HT_E_NO_DETECTOR;
  }
  *detector = loaded[build];
  return HT_OK;
#endif
}

bool NormaliseOptions(const HtOptions* given, HtOptions* options) {
  HtOptions o;
  memset(&o, 0, sizeof(o));
  if (given != nullptr) {
    o = *given;
  }
  if (o.detect_every == 0) {
    o.detect_every = 1;
  }
  if (o.min_score == 0) {
    o.min_score = 50;
  }
  if (o.detect_long_side == 0) {
    o.detect_long_side = 160;
  }
  if (o.width == 0) {
    o.width = 640;
  }
  if (o.height == 0) {
    o.height = 480;
  }
  if (o.fps == 0) {
    o.fps = 30;
  }
  if (o.detector < HT_DETECTOR_AUTO || o.detector > HT_DETECTOR_NEON || o.detect_every < 1 ||
      o.detect_every > 30 || o.min_score < 1 || o.min_score > 100 || o.detect_long_side < 32 ||
      o.detect_long_side > 320 || o.width < 16 || o.height < 16 || o.width > 8192 || o.height > 8192 || o.fps < 1 ||
      o.fps > 240 || (o.flags & ~HT_FLAG_COLOUR_ONLY) != 0) {
    return false;
  }
  *options = o;
  return true;
}

void DetectSize(int32_t width, int32_t height, int32_t long_side, int32_t* out_width, int32_t* out_height) {
  if (width >= height) {
    const int32_t w = width < long_side ? width : long_side;
    int32_t h = static_cast<int32_t>((static_cast<int64_t>(height) * w + width / 2) / width);
    *out_width = w;
    *out_height = h < 1 ? 1 : h;
  } else {
    const int32_t h = height < long_side ? height : long_side;
    int32_t w = static_cast<int32_t>((static_cast<int64_t>(width) * h + height / 2) / height);
    *out_width = w < 1 ? 1 : w;
    *out_height = h;
  }
}

void BoxFilter(const LumaPlane& plane, int32_t width, int32_t height, uint8_t* out) {
  // Source column and row bounds of each output pixel: [begin, end), never empty
  std::vector<int32_t> columns(static_cast<size_t>(width) + 1);
  for (int32_t x = 0; x <= width; x++) {
    columns[static_cast<size_t>(x)] =
        static_cast<int32_t>(static_cast<int64_t>(x) * plane.width / static_cast<int64_t>(width));
  }
  std::vector<uint32_t> sums(static_cast<size_t>(plane.width));
  for (int32_t y = 0; y < height; y++) {
    int32_t top = static_cast<int32_t>(static_cast<int64_t>(y) * plane.height / height);
    int32_t bottom = static_cast<int32_t>(static_cast<int64_t>(y + 1) * plane.height / height);
    if (bottom <= top) {
      bottom = top + 1;
    }
    std::fill(sums.begin(), sums.end(), 0u);
    for (int32_t row = top; row < bottom; row++) {
      const uint8_t* line = plane.data + static_cast<ptrdiff_t>(row) * plane.stride;
      if (plane.pixel_step == 1) {
        for (int32_t x = 0; x < plane.width; x++) {
          sums[static_cast<size_t>(x)] += line[x];
        }
      } else {
        for (int32_t x = 0; x < plane.width; x++) {
          sums[static_cast<size_t>(x)] += line[static_cast<ptrdiff_t>(x) * plane.pixel_step];
        }
      }
    }
    const uint32_t rows = static_cast<uint32_t>(bottom - top);
    for (int32_t x = 0; x < width; x++) {
      int32_t left = columns[static_cast<size_t>(x)];
      int32_t right = columns[static_cast<size_t>(x) + 1];
      if (right <= left) {
        right = left + 1;
      }
      uint32_t total = 0;
      for (int32_t column = left; column < right; column++) {
        total += sums[static_cast<size_t>(column)];
      }
      const uint32_t count = rows * static_cast<uint32_t>(right - left);
      out[static_cast<size_t>(y) * static_cast<size_t>(width) + static_cast<size_t>(x)] =
          static_cast<uint8_t>((total + count / 2) / count);
    }
  }
}

double OneEuro::Filter(double x, int64_t time_ns) {
  if (!has_value_) {
    has_value_ = true;
    last_ns_ = time_ns;
    value_ = x;
    derivative_ = 0;
    return x;
  }
  // A repeated or out of order timestamp would divide by zero: count it as one millisecond
  double dt = static_cast<double>(time_ns - last_ns_) / 1e9;
  if (dt < 1e-3) {
    dt = 1e-3;
  }
  last_ns_ = time_ns;
  auto alpha = [dt](double cutoff) {
    const double tau = 1.0 / (2.0 * 3.14159265358979323846 * cutoff);
    return 1.0 / (1.0 + tau / dt);
  };
  const double raw_derivative = (x - value_) / dt;
  derivative_ += alpha(derivative_cutoff_) * (raw_derivative - derivative_);
  const double cutoff = min_cutoff_ + beta_ * fabs(derivative_);
  value_ += alpha(cutoff) * (x - value_);
  return value_;
}

FaceCandidate CandidateOf(const FdFace& face, int32_t width, int32_t height) {
  FaceCandidate c;
  c.score = face.score;
  c.x = (face.x + face.width / 2.0) / width;
  c.y = (face.y + face.height / 2.0) / height;
  c.width = static_cast<double>(face.width) / width;
  c.height = static_cast<double>(face.height) / height;
  c.pixels = face.width;
  // landmarks[0..1] the right eye, [2..3] the left eye (the person's), in pixels of the detector image
  const double rx = face.landmarks[0], ry = face.landmarks[1], lx = face.landmarks[2], ly = face.landmarks[3];
  const double distance = hypot(lx - rx, ly - ry);
  const double mx = (rx + lx) / 2, my = (ry + ly) / 2;
  const bool inside = mx >= face.x && mx <= face.x + face.width && my >= face.y && my <= face.y + face.height;
  if (inside && distance >= face.width / 5.0) {
    c.eye_x = mx / width;
    c.eye_y = my / height;
    c.eye_distance = distance / width;
  } else {
    c.eye_x = c.x;
    c.eye_y = c.y;
    c.eye_distance = c.width / 3;
  }
  return c;
}

bool Predict(const HtSample& sample, int64_t now_us, double* head_x) {
  if (sample.state != HT_STATE_FACE || isnan(sample.filtered_x)) {
    return false;
  }
  double x = sample.filtered_x;
  if (sample.confidence >= HT_PREDICT_MIN_CONFIDENCE && isfinite(sample.velocity_x)) {
    int64_t ahead = now_us - sample.time_us;
    ahead = ahead < 0 ? 0 : (ahead > HT_PREDICT_MAX_US ? HT_PREDICT_MAX_US : ahead);
    double speed = sample.velocity_x;
    speed = speed > HT_PREDICT_MAX_SPEED ? HT_PREDICT_MAX_SPEED : (speed < -HT_PREDICT_MAX_SPEED ? -HT_PREDICT_MAX_SPEED : speed);
    x += speed * static_cast<double>(ahead) / 1e6;
  }
  *head_x = x < -0.5 ? -0.5 : (x > 0.5 ? 0.5 : x);
  return true;
}

Core::Core(const Detector& detector, const HtOptions& options) : detector_(detector), options_(options) {
  memset(faces_, 0, sizeof(faces_));
}

bool Core::CountFrame() {
  const bool analyse = frames_ % options_.detect_every == 0;
  frames_++;
  return analyse;
}

void Core::Begin(int64_t time_us, HtSample* sample) {
  memset(sample, 0, sizeof(*sample));
  sample->time_us = time_us;
  sample->sequence = ++sequence_;
  sample->face_x = sample->face_y = sample->face_width = sample->face_height = NAN;
  sample->eye_x = sample->eye_y = sample->eye_distance = sample->head_x = sample->filtered_x = NAN;
  sample->velocity_x = 0;
  if (!started_) {
    // No face yet: lost 300 ms after the first frame, as on the phones
    started_ = true;
    last_face_us_ = time_us;
  }
  if (recenter_.exchange(false)) {
    following_ = false;
    was_lost_ = true;
  }
}

void Core::Analyse(const LumaPlane& plane, int64_t time_us, HtSample* sample) {
  Begin(time_us, sample);
  sample->frame_width = plane.width;
  sample->frame_height = plane.height;

  int32_t width = 0, height = 0;
  DetectSize(plane.width, plane.height, detect_long_side(), &width, &height);
  int32_t found = 0;
  if (width >= 16 && height >= 16) {
    small_.resize(static_cast<size_t>(width) * static_cast<size_t>(height));
    BoxFilter(plane, width, height, small_.data());
    const int64_t start = NowUs();
    found = detector_.detect(small_.data(), width, height, width, faces_, kMaxFaces);
    sample->detect_us = static_cast<int32_t>(NowUs() - start);
  }
  int32_t count = 0;
  for (int32_t i = 0; i < found; i++) {
    if (faces_[i].width > 0 && faces_[i].height > 0) {
      candidates_[count++] = CandidateOf(faces_[i], width, height);
    }
  }
  Finish(candidates_, count, time_us, width, sample);
}

void Core::AnalyseFaces(const HtFace* faces, int32_t count, int64_t time_us, HtSample* sample) {
  Begin(time_us, sample);
  int32_t kept = 0;
  for (int32_t i = 0; i < count && kept < kMaxFaces; i++) {
    const HtFace& face = faces[i];
    if (!(face.eye_distance > 0) || isnan(face.eye_x) || isnan(face.eye_y)) {
      continue;
    }
    FaceCandidate& c = candidates_[kept++];
    c = FaceCandidate();
    c.score = face.score;
    c.eye_x = c.x = face.eye_x;
    c.eye_y = c.y = face.eye_y;
    c.eye_distance = face.eye_distance;
    // A face box is about three eye distances wide
    c.width = c.height = face.eye_distance * 3;
  }
  Finish(candidates_, kept, time_us, 0, sample);
}

void Core::Finish(const FaceCandidate* candidates, int32_t count, int64_t time_us, int32_t detect_width,
                  HtSample* sample) {
  sample->detect_width = detect_width;
  // Faces scoring enough. The first face, or the first after a recenter, is the largest: the user in front of the
  // screen rather than someone behind. Then the face nearest the one followed, among those at least half its size,
  // so that someone passing behind never takes the view.
  const FaceCandidate* best = nullptr;
  double best_rank = 0;
  int32_t counted = 0;
  for (int32_t i = 0; i < count; i++) {
    const FaceCandidate& c = candidates[i];
    if (c.score < options_.min_score) {
      continue;
    }
    counted++;
    if (following_) {
      if (c.width < follow_width_ / 2) {
        continue;
      }
      const double dx = c.eye_x - follow_x_, dy = c.eye_y - follow_y_;
      const double rank = -(dx * dx + dy * dy);
      if (best == nullptr || rank > best_rank) {
        best = &c;
        best_rank = rank;
      }
    } else if (best == nullptr || c.width * c.height > best_rank) {
      best = &c;
      best_rank = c.width * c.height;
    }
  }
  sample->faces = counted;
  if (best == nullptr) {
    sample->state = time_us - last_face_us_ > kLostAfterUs ? HT_STATE_LOST : HT_STATE_NO_FACE;
    if (sample->state == HT_STATE_LOST) {
      // Lost: the next face starts a new trajectory (HeadXFilter), and may be anyone's again
      was_lost_ = true;
      following_ = false;
      far_ = false;
    }
    return;
  }
  sample->face_x = best->x;
  sample->face_y = best->y;
  sample->face_width = best->width;
  sample->face_height = best->height;
  sample->confidence = best->score / 100.0;
  sample->eye_x = best->eye_x;
  sample->eye_y = best->eye_y;
  sample->eye_distance = best->eye_distance;
  sample->state = HT_STATE_FACE;
  last_face_us_ = time_us;
  following_ = true;
  follow_x_ = best->eye_x;
  follow_y_ = best->eye_y;
  follow_width_ = best->width;
  if (detect_width > 0) {
    if (!far_ && best->pixels < kSmallFacePixels && options_.detect_long_side * 2 <= 640) {
      far_ = true;
    } else if (far_ && best->pixels > kLargeFacePixels) {
      far_ = false;
    }
  }

  double head = 0.5 - best->eye_x;
  head = head < -0.5 ? -0.5 : (head > 0.5 ? 0.5 : head);
  sample->head_x = head;
  if (was_lost_) {
    filter_.Reset();
  }
  was_lost_ = false;
  sample->filtered_x = filter_.Filter(head * kFilterScale, time_us * 1000) / kFilterScale;
  sample->velocity_x = filter_.derivative() / kFilterScale;
}

}  // namespace ht
