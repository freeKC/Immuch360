// The tracker behind the handles of ht_api.h, shared by ht_api.cpp and the sources of frames (ht_windows.cpp,
// ht_linux.cpp, ht_macos.mm, the fake cameras of ht_fake.cpp, ht_no_media.cpp in the builds without a capture system).

#ifndef IMMUCH_HEAD_TRACKER_HT_TRACKER_H_
#define IMMUCH_HEAD_TRACKER_HT_TRACKER_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

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
  // The same core once a camera source owns it, for ht_recenter
  Core* core_ptr = nullptr;
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

// What a source running on its own thread and ht_close share. The thread keeps its own reference, so that a thread
// that outlives ht_close (a driver that hangs) never touches freed memory.
struct ThreadState {
  HtOptions options{};
  std::unique_ptr<Core> core;
  std::shared_ptr<Shared> shared;
  std::string id;
  std::atomic<bool> stop{false};
  // Wakes the thread when stop is set (a condition the thread waits on, or a pipe its poll watches)
  std::mutex stop_mutex;
  std::condition_variable stop_signal;
  std::function<void()> wake;
  std::mutex done_mutex;
  std::condition_variable done_signal;
  bool done = false;
  int64_t sequence = 0;

  // Analyses a frame and publishes its sample, when the frame is one to analyse
  void Frame(const LumaPlane& plane, int64_t time_us) {
    if (!core->CountFrame()) {
      return;
    }
    HtSample sample;
    core->Analyse(plane, time_us, &sample);
    sequence = sample.sequence;
    shared->Publish(sample);
  }

  // Publishes the error that stops the session: the last sample again, with the status
  void Fail(int32_t status) {
    HtSample sample{};
    {
      std::lock_guard<std::mutex> lock(shared->mutex);
      if (shared->has_latest) {
        sample = shared->latest;
      }
    }
    sample.sequence = sequence + 1;
    sample.status = status;
    sample.time_us = NowUs();
    shared->Publish(sample);
  }

  // Waits up to [time] for a stop; true when stopped
  bool WaitStop(std::chrono::microseconds time) {
    std::unique_lock<std::mutex> lock(stop_mutex);
    return stop_signal.wait_for(lock, time, [this] { return stop.load(); });
  }

  void Done() {
    std::lock_guard<std::mutex> lock(done_mutex);
    done = true;
    done_signal.notify_all();
  }
};

// A source whose frames come on a thread of its own. Stop asks the thread to end and waits two seconds for it (the
// camera released, its light off), then lets it go: a driver that hangs never hangs the app.
class ThreadSource : public Source {
 public:
  using Body = std::function<void(std::shared_ptr<ThreadState>)>;

  ThreadSource(std::shared_ptr<ThreadState> state, Body body) : state_(state) {
    thread_ = std::thread([state, body]() {
      body(state);
      state->Done();
    });
  }

  ~ThreadSource() override { Stop(); }

  int32_t Next(Tracker* tracker, HtSample* sample) override {
    (void)tracker;
    (void)sample;
    return HT_E_ARGUMENT;
  }

  void Stop() override {
    if (!thread_.joinable()) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(state_->stop_mutex);
      state_->stop = true;
    }
    state_->stop_signal.notify_all();
    if (state_->wake) {
      state_->wake();
    }
    bool done = false;
    {
      std::unique_lock<std::mutex> lock(state_->done_mutex);
      done = state_->done_signal.wait_for(lock, std::chrono::seconds(2), [this] { return state_->done; });
    }
    if (done) {
      thread_.join();
    } else {
      thread_.detach();
    }
  }

 private:
  std::shared_ptr<ThreadState> state_;
  std::thread thread_;
};

// The state of a thread source for [tracker], which hands it its core
inline std::shared_ptr<ThreadState> NewThreadState(Tracker* tracker, const std::string& id) {
  auto state = std::make_shared<ThreadState>();
  state->options = tracker->options;
  state->core = std::move(tracker->core);
  state->shared = tracker->shared;
  state->id = id;
  return state;
}

// Whether [id] names a fake camera of the tests ("y4m:" or "track:"), which every build has
bool IsFakeCamera(const std::string& id);

// Starts a fake camera on its own thread
int32_t OpenFakeCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source);

// The cameras as JSON, or an error
int32_t ListCameras(std::string* json);

// Starts a camera source on its own thread
int32_t OpenCamera(Tracker* tracker, const std::string& id, std::unique_ptr<Source>* source);

// Opens a file source
int32_t OpenFile(Tracker* tracker, const std::string& path, std::unique_ptr<Source>* source);

}  // namespace ht

#endif  // IMMUCH_HEAD_TRACKER_HT_TRACKER_H_
