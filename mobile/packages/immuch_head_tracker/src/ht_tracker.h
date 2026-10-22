// The tracker behind the handles of ht_api.h, shared by ht_api.cpp and the sources of frames (ht_windows.cpp on
// Windows, ht_no_media.cpp elsewhere).

#ifndef IMMUCH_HEAD_TRACKER_HT_TRACKER_H_
#define IMMUCH_HEAD_TRACKER_HT_TRACKER_H_

#include <memory>
#include <mutex>
#include <string>

#include "ht_api.h"
#include "ht_core.h"

namespace ht {

class Source;

// What the source thread and the caller share: the newest sample, the information, and the callback. The capture
// thread keeps its own reference, so that a camera thread that outlives ht_close (a driver that hangs) never touches
// freed memory.
struct Shared {
  std::mutex mutex;
  HtSample latest{};
  bool has_latest = false;
  HtInfo info{};
  // Guarded by callback_mutex: set to null by ht_close before it waits, so that no call comes after it returns
  std::mutex callback_mutex;
  HtSampleCallback callback = nullptr;

  void Publish(const HtSample& sample) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      latest = sample;
      has_latest = true;
    }
    std::lock_guard<std::mutex> lock(callback_mutex);
    if (callback != nullptr) {
      callback(sample.sequence, sample.status);
    }
  }
};

struct Tracker {
  HtOptions options{};
  std::unique_ptr<Core> core;
  std::shared_ptr<Shared> shared = std::make_shared<Shared>();
  std::unique_ptr<Source> source;
};

// A source of frames: a camera or a file
class Source {
 public:
  virtual ~Source() = default;
  // File sources: the next analysed frame, 1 with a sample, 0 at the end, or an error
  virtual int32_t Next(Tracker* tracker, HtSample* sample) = 0;
  // Stops a camera and releases it; files close in their destructor
  virtual void Stop() = 0;
};

// The cameras as JSON, or an error
int32_t ListCameras(std::string* json);

// Starts a camera source on its own thread
int32_t OpenCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source);

// Opens a file source
int32_t OpenFile(Tracker* tracker, const std::string& path, std::unique_ptr<Source>* source);

}  // namespace ht

#endif  // IMMUCH_HEAD_TRACKER_HT_TRACKER_H_
