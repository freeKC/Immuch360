// The exported functions of ht_api.h

#include "ht_api.h"

#include <string.h>

#include <string>

#include "ht_core.h"
#include "ht_tracker.h"

namespace {

void SetStatus(int32_t* status, int32_t value) {
  if (status != nullptr) {
    *status = value;
  }
}

// A tracker with its options checked and its detector loaded, or null with the error in *status
ht::Tracker* NewTracker(const HtOptions* given, int32_t* status) {
  HtOptions options;
  if (!ht::NormaliseOptions(given, &options)) {
    SetStatus(status, HT_E_ARGUMENT);
    return nullptr;
  }
  ht::Detector detector;
  const int32_t loaded = ht::LoadDetector(options.detector, &detector);
  if (loaded != HT_OK) {
    SetStatus(status, loaded);
    return nullptr;
  }
  auto* tracker = new ht::Tracker();
  tracker->options = options;
  tracker->core = std::make_unique<ht::Core>(detector, options);
  tracker->shared->info.detector = detector.build;
  SetStatus(status, HT_OK);
  return tracker;
}

}  // namespace

HT_API int32_t ht_api_version(void) { return HT_API_VERSION; }

HT_API int64_t ht_now_us(void) { return ht::NowUs(); }

HT_API int32_t ht_cpu_avx2(void) { return ht::CpuHasAvx2() ? 1 : 0; }

HT_API int32_t ht_list_cameras(char* json, int32_t capacity) {
  if (capacity < 0 || (json == nullptr && capacity > 0)) {
    return HT_E_ARGUMENT;
  }
  std::string text;
  const int32_t result = ht::ListCameras(&text);
  if (result < 0) {
    return result;
  }
  if (text.size() > 0x7fffffff) {
    return HT_E_FAILED;
  }
  const int32_t length = static_cast<int32_t>(text.size());
  if (length <= capacity) {
    memcpy(json, text.data(), text.size());
  }
  return length;
}

HT_API void* ht_open_camera(const char* id_utf8, const HtOptions* options, HtSampleCallback callback, int32_t* status) {
  if (id_utf8 == nullptr || callback == nullptr) {
    SetStatus(status, HT_E_ARGUMENT);
    return nullptr;
  }
  ht::Tracker* tracker = NewTracker(options, status);
  if (tracker == nullptr) {
    return nullptr;
  }
  tracker->shared->callback = callback;
  const int32_t opened = ht::OpenCamera(tracker, id_utf8, &tracker->source);
  if (opened != HT_OK) {
    {
      std::lock_guard<std::mutex> lock(tracker->shared->callback_mutex);
      tracker->shared->callback = nullptr;
    }
    delete tracker;
    SetStatus(status, opened);
    return nullptr;
  }
  return tracker;
}

HT_API void* ht_open_file(const char* path_utf8, const HtOptions* options, int32_t* status) {
  if (path_utf8 == nullptr) {
    SetStatus(status, HT_E_ARGUMENT);
    return nullptr;
  }
  ht::Tracker* tracker = NewTracker(options, status);
  if (tracker == nullptr) {
    return nullptr;
  }
  const int32_t opened = ht::OpenFile(tracker, path_utf8, &tracker->source);
  if (opened != HT_OK) {
    delete tracker;
    SetStatus(status, opened);
    return nullptr;
  }
  return tracker;
}

HT_API void* ht_open_frames(const HtOptions* options, int32_t* status) { return NewTracker(options, status); }

HT_API int32_t ht_next(void* handle, HtSample* sample) {
  auto* tracker = static_cast<ht::Tracker*>(handle);
  if (tracker == nullptr || sample == nullptr || tracker->source == nullptr) {
    return HT_E_ARGUMENT;
  }
  return tracker->source->Next(tracker, sample);
}

HT_API int32_t ht_process_frame(void* handle, const uint8_t* grey, int32_t width, int32_t height, int32_t stride,
                                int64_t time_ns, HtSample* sample) {
  auto* tracker = static_cast<ht::Tracker*>(handle);
  if (tracker == nullptr || grey == nullptr || sample == nullptr || width < 16 || height < 16 || width > 8192 ||
      height > 8192 || stride < width || tracker->source != nullptr) {
    return HT_E_ARGUMENT;
  }
  ht::LumaPlane plane;
  plane.data = grey;
  plane.width = width;
  plane.height = height;
  plane.stride = stride;
  plane.pixel_step = 1;
  tracker->core->Analyse(plane, time_ns / 1000, sample);
  {
    std::lock_guard<std::mutex> lock(tracker->shared->mutex);
    tracker->shared->latest = *sample;
    tracker->shared->has_latest = true;
    tracker->shared->info.width = width;
    tracker->shared->info.height = height;
  }
  return 1;
}

HT_API int32_t ht_latest(void* handle, HtSample* sample) {
  auto* tracker = static_cast<ht::Tracker*>(handle);
  if (tracker == nullptr || sample == nullptr) {
    return HT_E_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(tracker->shared->mutex);
  if (!tracker->shared->has_latest) {
    return 0;
  }
  *sample = tracker->shared->latest;
  return 1;
}

HT_API int32_t ht_info(void* handle, HtInfo* info) {
  auto* tracker = static_cast<ht::Tracker*>(handle);
  if (tracker == nullptr || info == nullptr) {
    return HT_E_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(tracker->shared->mutex);
  *info = tracker->shared->info;
  return HT_OK;
}

HT_API void ht_close(void* handle) {
  auto* tracker = static_cast<ht::Tracker*>(handle);
  if (tracker == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(tracker->shared->callback_mutex);
    tracker->shared->callback = nullptr;
  }
  if (tracker->source != nullptr) {
    tracker->source->Stop();
  }
  delete tracker;
}
