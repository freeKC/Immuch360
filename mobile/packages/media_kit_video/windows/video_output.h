// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef VIDEO_OUTPUT_H_
#define VIDEO_OUTPUT_H_

#include <optional>

#include <client.h>
#include <render.h>
#include <render_gl.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "angle_surface_manager.h"
#include "projection_renderer.h"
#include "thread_pool.h"

typedef struct _VideoOutputConfiguration {
  std::optional<int64_t> width;
  std::optional<int64_t> height;
  bool enable_hardware_acceleration;

  _VideoOutputConfiguration(std::optional<int64_t> width = std::nullopt,
                            std::optional<int64_t> height = std::nullopt,
                            bool enable_hardware_acceleration = true)
      : width(width),
        height(height),
        enable_hardware_acceleration(enable_hardware_acceleration) {}
} VideoOutputConfiguration;

// Immuch360: wakes the primary player of a pair once a frame waited long
// enough for its partner's (IMMUCH360-NOTE.md, patch 7). One thread that
// sleeps until the earliest time asked, then calls |fire|.
class PairTimer {
 public:
  explicit PairTimer(std::function<void()> fire);
  ~PairTimer();
  void Arm(std::chrono::steady_clock::time_point at);

 private:
  void Run();

  std::function<void()> fire_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::optional<std::chrono::steady_clock::time_point> at_;
  bool stop_ = false;
  std::thread thread_;
};

class VideoOutput {
 public:
  int64_t texture_id() const { return texture_id_; }
  int64_t width() const {
    // H/W
    if (surface_manager_ != nullptr && texture_id_) {
      return surface_manager_->width();
    }
    // S/W
    if (pixel_buffer_ != nullptr && texture_id_) {
      return pixel_buffer_textures_.at(texture_id_)->width;
    }
    return width_.value_or(1);
  }
  int64_t height() const {
    // H/W
    if (surface_manager_ != nullptr && texture_id_) {
      return surface_manager_->height();
    }
    // S/W
    if (pixel_buffer_ != nullptr && texture_id_) {
      return pixel_buffer_textures_.at(texture_id_)->height;
    }
    return height_.value_or(1);
  }

  VideoOutput(int64_t handle,
              VideoOutputConfiguration configuration,
              flutter::PluginRegistrarWindows* registrar,
              ThreadPool* thread_pool_ref);

  ~VideoOutput();

  void SetTextureUpdateCallback(
      std::function<void(int64_t, int64_t, int64_t)> callback);

  void SetSize(std::optional<int64_t> width, std::optional<int64_t> height);

  // Immuch360: renderer C (IMMUCH360-NOTE.md, patch 6). Draws through
  // |setup| from now on, or as upstream again with std::nullopt; a new
  // |setup| with another output size or tier replaces the previous one. Runs
  // on the thread pool and waits for it; returns "ok" and, when false,
  // "reason", with the OpenGL ES version and renderer of the context.
  flutter::EncodableMap SetProjection(std::optional<ProjectionSetup> setup);

  // Immuch360: the view of renderer C, from any thread. The newest view is
  // kept and at most one redraw waits in the thread pool: views that come
  // faster than the pass draws are merged, never queued.
  void SetView(const ProjectionView& view);

  // Immuch360: what renderer C did since the last call (counts and times of
  // the draws), its sizes, and the five pixels of |ProjectionRenderer::
  // ReadProbe| asked for by an earlier call with |probe| true.
  flutter::EncodableMap ProjectionStats(bool probe);

  // Immuch360: the two streams of a raw 360 file decoded by two players
  // (IMMUCH360-NOTE.md, patch 7). |partner|, whose projection is a secondary
  // one, decodes stream 1 into its intermediate texture; this player draws the
  // view from its own frame and the partner's, the two frames of one time
  // together. nullptr ends the pairing. Runs on the thread pool and waits;
  // "ok", and "reason" when false.
  flutter::EncodableMap SetPartner(VideoOutput* partner);

 private:
  // Immuch360: the setup of renderer C, null when it is off.
  std::shared_ptr<const ProjectionSetup> CurrentProjection();

  // Immuch360: one draw of renderer C on the thread pool: mpv's new frame
  // into the intermediate texture when there is one, then the view into the
  // surface; nothing when neither the frame nor the view changed.
  void DrawProjection(const ProjectionSetup& setup);

  // Immuch360: a draw of renderer C for a new view, unless one already waits
  // in the thread pool (it will draw the newest view).
  void PostRedraw();

  // Immuch360: the size of the decoded video (rotation applied), 0 x 0 when
  // mpv does not know it yet.
  std::pair<int64_t, int64_t> VideoParamsSize();

  // Immuch360, two players for one raw file (patch 7). |DrawPaired| replaces
  // |DrawProjection| on the primary player: it draws each frame of either
  // player into its intermediate texture when the other's frame of the same
  // time is there too (or once it waited long enough), then the view.
  void DrawPaired(const ProjectionSetup& setup);
  // Notes whether mpv has a new frame to draw, and its time, once per frame;
  // the context of this player must be current. |period| is the frame period
  // of the pair, in seconds.
  void NotePending(int64_t now_ns, double period);
  // mpv's frame into the intermediate texture of |setup|, or into the current
  // surface while the video has no size yet; the context must be current.
  bool RenderFrame(const ProjectionSetup& setup);
  // A secondary player without its primary: its frames are drawn into its
  // texture and nothing else, so that its mpv does not wait.
  void DrawSecondaryAlone(const ProjectionSetup& setup);
  // Ends the pairing this player is part of, either side. Thread pool only.
  void Unpair();
  // A draw of the pair from the thread pool, for |PairTimer|.
  void PostPairDraw();


  void NotifyRender();

  void Render();

  void CheckAndResize();

  void Resize(int64_t required_width, int64_t required_height);

  int64_t GetVideoWidth();

  int64_t GetVideoHeight();

  // Immuch360: tells Dart, once, that the texture can no longer show a picture
  // (IMMUCH360-NOTE.md, patch 4).
  void ReportDeviceLost();

  std::optional<int64_t> height_ = std::nullopt;
  std::optional<int64_t> width_ = std::nullopt;
  VideoOutputConfiguration configuration_ = VideoOutputConfiguration{};

  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_context_ = nullptr;
  int64_t texture_id_ = 0;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  ThreadPool* thread_pool_ref_ = nullptr;
  // For preventing any asynchronous operations (primarily texture objects
  // deletion after unregister in |Resize|) access this object after
  // destruction.
  bool destroyed_ = false;
  // Immuch360: the Direct3D device of |surface_manager_| was lost; only read
  // and written on the thread pool, which has one worker.
  bool device_lost_ = false;

  std::mutex textures_mutex_ = std::mutex();

  // Immuch360: renderer C (patch 6). |projection_|, |view_|,
  // |view_generation_| and the statistics are written under
  // |projection_mutex_|; |projection_renderer_| and |drawn_generation_| live
  // on the thread pool only.
  std::mutex projection_mutex_;
  std::shared_ptr<const ProjectionSetup> projection_ = nullptr;
  ProjectionView view_ = ProjectionView{};
  uint64_t view_generation_ = 0;
  uint64_t drawn_generation_ = 0;
  std::atomic<bool> redraw_pending_{false};
  std::unique_ptr<ProjectionRenderer> projection_renderer_ = nullptr;
  struct ProjectionCounters {
    int64_t frames = 0;
    int64_t redraws = 0;
    int64_t failed = 0;
    std::vector<double> frame_ms;
    std::vector<double> redraw_ms;
    std::vector<double> locked_ms;
    // The parts of a draw with a new frame: mpv's size asked, mpv's render
    // call, the view and the end of all of it on the GPU
    std::vector<double> size_ms;
    std::vector<double> mpv_ms;
    std::vector<double> view_ms;
    bool probe_requested = false;
    bool probe_ready = false;
    uint32_t probe[5] = {0, 0, 0, 0, 0};
    int32_t frame_width = 0;
    int32_t frame_height = 0;
    std::string error;
    std::string gl_renderer;
    // Immuch360, two players (patch 7): draws of both frames of one time, of
    // one frame alone after the wait, of a frame drawn to catch up without a
    // view, and the partner's frames; the partner's delay and speed
    int64_t paired = 0;
    int64_t alone = 0;
    int64_t catch_up = 0;
    int64_t partner_frames = 0;
    double partner_offset_ms = 0.0;
    double partner_speed = 0.0;
  };
  ProjectionCounters projection_counters_;

  // Immuch360: the pairing of two players (patch 7). |partner_| on the
  // primary player, |primary_| on the secondary one; thread pool only, as
  // |pending_| and |pair_|. |update_ns_| is when mpv last said it has a frame,
  // written by mpv's thread.
  struct PendingFrame {
    bool waiting = false;
    double pts = -1.0;
    int64_t since_ns = 0;
  };
  struct PairState {
    // The frame period and the last time drawn, to tell the frames apart
    double period = 1.0 / 30.0;
    double last_pts = -1.0;
    int32_t period_samples = 0;
    int32_t fps_reads = 0;
    // The time and the arrival of the frame each player drew last, which
    // tell how much later the partner's frames come than this player's
    double mine_pts = -1.0;
    int64_t mine_since_ns = 0;
    double theirs_pts = -1.0;
    int64_t theirs_since_ns = 0;
    // That delay, smoothed, the speed the partner was last given to close it,
    // and this player's speed
    double offset_ms = 0.0;
    double partner_speed = 0.0;
    double speed = 1.0;
    int64_t speed_at_ns = 0;
    int64_t seek_at_ns = 0;
  };
  VideoOutput* partner_ = nullptr;
  VideoOutput* primary_ = nullptr;
  PendingFrame pending_;
  PairState pair_;
  std::atomic<int64_t> update_ns_{0};
  std::unique_ptr<PairTimer> pair_timer_ = nullptr;

  std::unordered_map<int64_t, std::unique_ptr<flutter::TextureVariant>>
      texture_variants_ = {};

  // H/W rendering.

  std::unique_ptr<ANGLESurfaceManager> surface_manager_ = nullptr;
  std::unordered_map<int64_t,
                     std::unique_ptr<FlutterDesktopGpuSurfaceDescriptor>>
      textures_ = {};

  // S/W rendering.

  std::unique_ptr<uint8_t[]> pixel_buffer_ = nullptr;
  std::unordered_map<int64_t, std::unique_ptr<FlutterDesktopPixelBuffer>>
      pixel_buffer_textures_ = {};

  // Public notifier. This is called when a new texture is registered & texture
  // ID is changed. Only happens when video output resolution changes.
  std::function<void(int64_t, int64_t, int64_t)> texture_update_callback_ =
      [](int64_t, int64_t, int64_t) {};
};

#endif  // VIDEO_OUTPUT_H_
