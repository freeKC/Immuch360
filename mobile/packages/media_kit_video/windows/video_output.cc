// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output.h"

#include <algorithm>
#include <chrono>
#include <exception>

// Limit the frame size to 1080p in software rendering.
// This is for performance reasons & to avoid allocating too much memory.
#define SW_RENDERING_MAX_WIDTH 1920
#define SW_RENDERING_MAX_HEIGHT 1080
#define SW_RENDERING_PIXEL_BUFFER_SIZE \
  (SW_RENDERING_MAX_WIDTH) * (SW_RENDERING_MAX_HEIGHT) * (4)

VideoOutput::VideoOutput(int64_t handle,
                         VideoOutputConfiguration configuration,
                         flutter::PluginRegistrarWindows* registrar,
                         ThreadPool* thread_pool_ref)
    : handle_(reinterpret_cast<mpv_handle*>(handle)),
      width_(configuration.width),
      height_(configuration.height),
      configuration_(configuration),
      registrar_(registrar),
      thread_pool_ref_(thread_pool_ref) {
  // The constructor must be invoked through the thread pool, because
  // |ANGLESurfaceManager| & libmpv render context creation can conflict with
  // the existing |Render| or |Resize| calls from another |VideoOutput|
  // instances (which will result in access violation).
  auto future = thread_pool_ref_->Post([&]() {
    mpv_set_option_string(handle_, "video-sync", "audio");
    mpv_set_option_string(handle_, "video-timing-offset", "0");
    // First try to initialize video playback with hardware acceleration &
    // |ANGLESurfaceManager|, use S/W API as fallback.
    auto is_hardware_acceleration_enabled = false;
    // Attempt to use H/W rendering.
    if (configuration.enable_hardware_acceleration) {
      try {
        // OpenGL context needs to be set before |mpv_render_context_create|.
        surface_manager_ = std::make_unique<ANGLESurfaceManager>(
            static_cast<int32_t>(width_.value_or(1)),
            static_cast<int32_t>(height_.value_or(1)));
        surface_manager_->MakeCurrent(true);
        Resize(width_.value_or(1), height_.value_or(1));
        mpv_opengl_init_params gl_init_params{
            [](auto, auto name) {
              return reinterpret_cast<void*>(eglGetProcAddress(name));
            },
            nullptr,
        };
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init_params},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        // Create render context.
        if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
          mpv_render_context_set_update_callback(
              render_context_,
              [](void* context) {
                // Notify Flutter that a new frame is available. The actual
                // rendering will take place in the |Render| method, which will
                // be called by Flutter on the render thread.
                auto that = reinterpret_cast<VideoOutput*>(context);
                that->NotifyRender();
              },
              reinterpret_cast<void*>(this));
          // Set flag to true, indicating that H/W rendering is supported.
          is_hardware_acceleration_enabled = true;
          std::cout << "media_kit: VideoOutput: Using H/W rendering."
                    << std::endl;
        }
      } catch (...) {
        // Do nothing.
        // Likely received an |std::runtime_error| from |ANGLESurfaceManager|,
        // which indicates that H/W rendering is not supported.
      }
    }
    if (!is_hardware_acceleration_enabled) {
      std::cout << "media_kit: VideoOutput: Using S/W rendering." << std::endl;
      // Allocate a "large enough" buffer ahead of time.
      pixel_buffer_ =
          std::make_unique<uint8_t[]>(SW_RENDERING_PIXEL_BUFFER_SIZE);
      Resize(width_.value_or(1), height_.value_or(1));
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
        mpv_render_context_set_update_callback(
            render_context_,
            [](void* context) {
              // Notify Flutter that a new frame is available. The actual
              // rendering will take place in the |Render| method, which will be
              // called by Flutter on the render thread.
              auto that = reinterpret_cast<VideoOutput*>(context);
              that->NotifyRender();
            },
            reinterpret_cast<void*>(this));
      }
    }
  });
  future.wait();
}

VideoOutput::~VideoOutput() {
  destroyed_ = true;
  auto promise = std::promise<void>();
  // Runs on the thread pool once every task posted before it has run, so
  // that no |Render| or |Resize| reaches the objects freed here.
  auto free_on_pool = [&]() {
    std::cout << "VideoOutput::~VideoOutput: "
              << reinterpret_cast<int64_t>(handle_) << std::endl;
    std::lock_guard<std::mutex> lock(textures_mutex_);
    texture_variants_.clear();
    // H/W
    textures_.clear();
    // S/W
    pixel_buffer_textures_.clear();
    // Immuch360: the objects of renderer C belong to the context of
    // |surface_manager_|, which is destroyed next (patch 6).
    if (projection_renderer_ != nullptr && surface_manager_ != nullptr) {
      surface_manager_->MakeCurrent(true);
      projection_renderer_->Release();
      surface_manager_->MakeCurrent(false);
    }
    projection_renderer_.reset();
    // Free (call destructor) |ANGLESurfaceManager| through the thread
    // pool. This will ensure synchronized EGL or ANGLE usage & won't
    // conflict with |Render| or |CheckAndResize| of other
    // |VideoOutput|s.
    surface_manager_.reset(nullptr);
    promise.set_value();
  };
  if (texture_id_) {
    registrar_->texture_registrar()->UnregisterTexture(
        texture_id_, [&, texture_id = texture_id_]() {
          std::cout << "media_kit: VideoOutput: Free Texture: " << texture_id
                    << std::endl;
          // Add one more task into the thread pool queue & exit the destructor
          // only when it gets executed. This will ensure that all the tasks
          // posted to the thread pool i.e. render or resize before this are
          // executed (and won't reference the dead object anymore), most
          // notably |CheckAndResize| & |Render|.
          thread_pool_ref_->Post(free_on_pool);
        });
  } else {
    // Immuch360: no texture is registered after a lost device (patch 4) or a
    // failed |Resize|; upstream then waited here for a promise that nothing
    // would ever fulfil, holding |VideoOutputManager|'s mutex, so that every
    // later player of the app hung (patch 6).
    thread_pool_ref_->Post(free_on_pool);
  }

  promise.get_future().wait();
  texture_id_ = 0;

  thread_pool_ref_->Post([render_context = render_context_]() {
    mpv_render_context_free(render_context);
  });
}

void VideoOutput::NotifyRender() {
  if (destroyed_) {
    return;
  }
  thread_pool_ref_->Post(std::bind(&VideoOutput::CheckAndResize, this));
  thread_pool_ref_->Post(std::bind(&VideoOutput::Render, this));
}

void VideoOutput::Render() {
  if (texture_id_) {
    // H/W
    if (surface_manager_ != nullptr) {
      // Immuch360: a frame drawn on a lost device never shows; Dart replaces
      // the player (IMMUCH360-NOTE.md, patch 4).
      if (device_lost_) {
        return;
      }
      if (surface_manager_->IsDeviceLost()) {
        ReportDeviceLost();
        return;
      }
      // Immuch360: renderer C draws the frame and the view (patch 6).
      if (const auto projection = CurrentProjection()) {
        DrawProjection(*projection);
        return;
      }
      surface_manager_->Draw([&]() {
        mpv_opengl_fbo fbo{
            0,
            surface_manager_->width(),
            surface_manager_->height(),
            0,
        };
        mpv_render_param params[]{
            {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        mpv_render_context_render(render_context_, params);
      });
    }
    // S/W
    if (pixel_buffer_ != nullptr) {
      int32_t size[]{
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->width),
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->height),
      };
      auto pitch = 4 * size[0];
      mpv_render_param params[]{
          {MPV_RENDER_PARAM_SW_SIZE, size},
          {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
          {MPV_RENDER_PARAM_SW_POINTER, pixel_buffer_.get()},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      mpv_render_context_render(render_context_, params);
    }
    try {
      // Notify Flutter that a new frame is available.
      registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
    } catch (...) {
      // Prevent any redundant exceptions if the texture is unregistered etc.
    }
  }
}

void VideoOutput::SetTextureUpdateCallback(
    std::function<void(int64_t, int64_t, int64_t)> callback) {
  texture_update_callback_ = callback;
  texture_update_callback_(texture_id_, GetVideoWidth(), GetVideoHeight());
}

void VideoOutput::SetSize(std::optional<int64_t> width,
                          std::optional<int64_t> height) {
  thread_pool_ref_->Post([&, width, height]() {
    if (width.has_value()) {
      // H/W
      if (surface_manager_ != nullptr) {
        width_ = width.value();
      }
      // S/W
      if (pixel_buffer_ != nullptr) {
        // Limit width if software rendering is being used.
        width_ = std::clamp(width.value(), static_cast<int64_t>(0),
                            static_cast<int64_t>(SW_RENDERING_MAX_WIDTH));
      }
    } else {
      width_ = std::nullopt;
    }
    if (height.has_value()) {
      // H/W
      if (surface_manager_ != nullptr) {
        height_ = height.value();
      }
      // S/W
      if (pixel_buffer_ != nullptr) {
        // Limit width if software rendering is being used.
        height_ = std::clamp(height.value(), static_cast<int64_t>(0),
                             static_cast<int64_t>(SW_RENDERING_MAX_HEIGHT));
      }
    } else {
      height_ = std::nullopt;
    }
  });
}

void VideoOutput::CheckAndResize() {
  // Check if a new texture with different dimensions is needed.
  auto required_width = GetVideoWidth(), required_height = GetVideoHeight();
  // Immuch360: with renderer C the texture is the view, at the output size
  // Dart gave, capped; the video's size only sizes the intermediate texture
  // (patch 6).
  if (const auto projection = CurrentProjection();
      projection != nullptr && surface_manager_ != nullptr) {
    int32_t width = 1, height = 1;
    projection->OutputSize(&width, &height);
    required_width = width;
    required_height = height;
  }
  if (required_width < 1 || required_height < 1) {
    // Invalid.
    return;
  }
  int64_t current_width = -1, current_height = -1;
  if (surface_manager_ != nullptr) {
    current_width = surface_manager_->width();
    current_height = surface_manager_->height();
  }
  if (pixel_buffer_ != nullptr) {
    current_width = pixel_buffer_textures_.at(texture_id_)->width;
    current_height = pixel_buffer_textures_.at(texture_id_)->height;
  }
  // Currently rendered video output dimensions.
  // Either H/W or S/W rendered.
  assert(current_width > 0);
  assert(current_height > 0);
  if (required_width == current_width && required_height == current_height) {
    // No creation of new texture required.
    return;
  }
  Resize(required_width, required_height);
}

void VideoOutput::Resize(int64_t required_width, int64_t required_height) {
  std::cout << required_width << " " << required_height << std::endl;
  // Unregister previously registered texture & delete underlying objects.
  if (texture_id_) {
    const auto previous_id = texture_id_;
    {
      // Immuch360: zeroed under the lock its callbacks read it with, before
      // the texture is unregistered and its entries erased: a frame asked for
      // meanwhile gets no texture rather than an id no longer in |textures_|
      // (IMMUCH360-NOTE.md, patch 5).
      std::lock_guard<std::mutex> lock(textures_mutex_);
      texture_id_ = 0;
    }
    registrar_->texture_registrar()->UnregisterTexture(
        previous_id, [&, id = previous_id]() {
          if (id) {
            std::cout << "media_kit: VideoOutput: Free Texture: " << id
                      << std::endl;
            std::lock_guard<std::mutex> lock(textures_mutex_);
            if (destroyed_) {
              return;
            }
            if (texture_variants_.find(id) != texture_variants_.end()) {
              texture_variants_.erase(id);
            }
            // H/W
            if (textures_.find(id) != textures_.end()) {
              textures_.erase(id);
            }
            // S/W
            if (pixel_buffer_textures_.find(id) !=
                pixel_buffer_textures_.end()) {
              pixel_buffer_textures_.erase(id);
            }
          }
        });
  }
  // H/W
  if (surface_manager_ != nullptr) {
    if (device_lost_) {
      return;
    }
    // Destroy internal ID3D11Texture2D & EGLSurface & create new with updated
    // dimensions while preserving previous EGLDisplay & EGLContext.
    try {
      surface_manager_->SetSize(static_cast<int32_t>(required_width),
                                static_cast<int32_t>(required_height));
    } catch (const std::exception& error) {
      // Immuch360: no texture can be made on a lost device. The exception
      // used to end in the thread pool's task, with |texture_id_| already 0
      // and Dart never told (IMMUCH360-NOTE.md, patch 4).
      std::cout << "media_kit: VideoOutput: " << error.what() << std::endl;
      ReportDeviceLost();
      return;
    }
    auto texture = std::make_unique<FlutterDesktopGpuSurfaceDescriptor>();
    texture->struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    texture->handle = surface_manager_->handle();
    texture->width = texture->visible_width = surface_manager_->width();
    texture->height = texture->visible_height = surface_manager_->height();
    texture->release_context = nullptr;
    texture->release_callback = [](void*) {};
    texture->format = kFlutterDesktopPixelFormatBGRA8888;
    auto texture_variant =
        std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
              std::lock_guard<std::mutex> lock(textures_mutex_);
              if (texture_id_) {
                surface_manager_->Read();
                return textures_.at(texture_id_).get();
              } else {
                return (FlutterDesktopGpuSurfaceDescriptor*)nullptr;
              }
            }));
    // Register new texture.
    // Immuch360: |texture_id_| changes only once the texture is in |textures_|,
    // under the lock its callbacks take: a frame Flutter asked for meanwhile
    // looked |texture_id_| up in |textures_|, did not find it and threw
    // std::out_of_range inside the engine, which ended the app
    // (IMMUCH360-NOTE.md, patch 5).
    const auto id =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    std::cout << "media_kit: VideoOutput: Create Texture: " << id << std::endl;
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      textures_.emplace(std::make_pair(id, std::move(texture)));
      texture_variants_.emplace(std::make_pair(id, std::move(texture_variant)));
      texture_id_ = id;
    }
    // Notify public texture update callback.
    texture_update_callback_(id, required_width, required_height);
  }
  // S/W
  if (pixel_buffer_ != nullptr) {
    auto pixel_buffer_texture = std::make_unique<FlutterDesktopPixelBuffer>();
    pixel_buffer_texture->buffer = pixel_buffer_.get();
    pixel_buffer_texture->width = required_width;
    pixel_buffer_texture->height = required_height;
    pixel_buffer_texture->release_context = nullptr;
    pixel_buffer_texture->release_callback = [](void*) {};
    auto texture_variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([&](auto, auto) {
          std::lock_guard<std::mutex> lock(textures_mutex_);
          if (texture_id_) {
            return pixel_buffer_textures_.at(texture_id_).get();
          } else {
            return (FlutterDesktopPixelBuffer*)nullptr;
          }
        }));
    // Register new texture.
    // Immuch360: published under the lock, as for H/W above (patch 5).
    const auto id =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    std::cout << "media_kit: VideoOutput: Create Texture: " << id << std::endl;
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      pixel_buffer_textures_.emplace(
          std::make_pair(id, std::move(pixel_buffer_texture)));
      texture_variants_.emplace(std::make_pair(id, std::move(texture_variant)));
      texture_id_ = id;
    }
    // Notify public texture update callback.
    texture_update_callback_(id, required_width, required_height);
  }
}

void VideoOutput::ReportDeviceLost() {
  if (device_lost_) {
    return;
  }
  device_lost_ = true;
  std::cout << "media_kit: VideoOutput: Direct3D device lost" << std::endl;
  // Texture ID 0 is never given otherwise: the Dart side of Immuch360 reads it
  // as "no picture any more" (DesktopPlayer.textureLost).
  texture_update_callback_(0, 0, 0);
}

int64_t VideoOutput::GetVideoWidth() {
  // Fixed width.
  if (width_) {
    return width_.value();
  }
  // Video resolution dependent width.
  int64_t width = 0;
  int64_t height = 0;

  mpv_node params;
  mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (pixel_buffer_ != nullptr) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return SW_RENDERING_MAX_WIDTH;
    }
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return width / height * SW_RENDERING_MAX_HEIGHT;
    }
  }

  return width;
}

int64_t VideoOutput::GetVideoHeight() {
  // Fixed height.
  if (height_) {
    return height_.value();
  }
  // Video resolution dependent height.
  int64_t width = 0;
  int64_t height = 0;

  mpv_node params;
  mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (pixel_buffer_ != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return SW_RENDERING_MAX_HEIGHT;
    }
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return height / width * SW_RENDERING_MAX_WIDTH;
    }
  }

  return height;
}

// Immuch360: renderer C (IMMUCH360-NOTE.md, patch 6).

namespace {

// GL_RGBA8, the format of the intermediate texture, told to mpv so that it
// dithers for 8 bits
constexpr int kFrameFormat = 0x8058;

// Times kept between two reads of the statistics: about two minutes of
// frames at 30 a second plus views at 60
constexpr size_t kMaxTimes = 12000;

double MillisecondsSince(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now() - start)
      .count();
}

void Keep(std::vector<double>& times, double value) {
  if (times.size() < kMaxTimes) {
    times.push_back(value);
  }
}

}  // namespace

std::shared_ptr<const ProjectionSetup> VideoOutput::CurrentProjection() {
  std::lock_guard<std::mutex> lock(projection_mutex_);
  return projection_;
}

std::pair<int64_t, int64_t> VideoOutput::VideoParamsSize() {
  mpv_node params;
  if (mpv_get_property(handle_, "video-out-params", MPV_FORMAT_NODE, &params) <
      0) {
    return {0, 0};
  }
  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      const char* key = params.u.list->keys[i];
      const auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        } else if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        } else if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
  }
  mpv_free_node_contents(&params);
  return rotate == 90 || rotate == 270 ? std::make_pair(dh, dw)
                                       : std::make_pair(dw, dh);
}

void VideoOutput::DrawProjection(const ProjectionSetup& setup) {
  if (projection_renderer_ == nullptr || render_context_ == nullptr) {
    return;
  }
  const auto start = std::chrono::steady_clock::now();
  // Whether mpv has a frame to show: a new one while playing, the current one
  // again after a seek or an option change. Without it only the view changed.
  const auto flags = mpv_render_context_update(render_context_);
  const bool mpv_frame = (flags & MPV_RENDER_UPDATE_FRAME) != 0;
  const bool frame_wanted = mpv_frame || !projection_renderer_->has_frame();
  ProjectionView view;
  uint64_t generation = 0;
  bool probe = false;
  {
    std::lock_guard<std::mutex> lock(projection_mutex_);
    view = view_;
    generation = view_generation_;
    probe = projection_counters_.probe_requested;
  }
  if (!frame_wanted && generation == drawn_generation_ && !probe) {
    return;
  }
  const auto width = surface_manager_->width();
  const auto height = surface_manager_->height();
  // Everything is drawn into the texture Flutter does not copy from, and
  // finished, before the two are swapped under the lock (|SwapBack|)
  surface_manager_->MakeBackCurrent();
  bool drew_frame = false;
  bool drew_flat = false;
  double size_ms = 0.0;
  double mpv_ms = 0.0;
  if (frame_wanted) {
    const auto size_start = std::chrono::steady_clock::now();
    const auto [video_width, video_height] = VideoParamsSize();
    size_ms = MillisecondsSince(size_start);
    const auto mpv_start = std::chrono::steady_clock::now();
    if (projection_renderer_->EnsureFrame(video_width, video_height, setup)) {
      mpv_opengl_fbo fbo{
          static_cast<int>(projection_renderer_->frame_fbo()),
          projection_renderer_->frame_width(),
          projection_renderer_->frame_height(),
          kFrameFormat,
      };
      mpv_render_param params[]{
          {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      mpv_render_context_render(render_context_, params);
      projection_renderer_->set_has_frame(true);
      drew_frame = true;
    } else if (mpv_frame) {
      // mpv waits for each frame it hands over to be drawn (vo_libmpv's
      // flip_page): without an intermediate texture (no size yet, or none
      // could be made) the frame goes to the output as it is, so that the
      // playback goes on.
      mpv_opengl_fbo fbo{0, width, height, 0};
      mpv_render_param params[]{
          {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      mpv_render_context_render(render_context_, params);
      drew_flat = true;
    }
    mpv_ms = MillisecondsSince(mpv_start);
  }
  const auto view_start = std::chrono::steady_clock::now();
  const bool drawn =
      !drew_flat && projection_renderer_->DrawView(setup, view, width, height);
  // mpv's frame and the view, finished outside the lock: a GPU that idles
  // between the draws of a paused video took 14 to 16 ms to finish each one
  // on the RTX 4060 (2026-10-09), all of it while Flutter's raster thread
  // waited for the lock when the drawing happened under it
  glFinish();
  const auto view_ms = MillisecondsSince(view_start);
  bool read = false;
  uint32_t pixels[5] = {0, 0, 0, 0, 0};
  if (drawn && probe) {
    projection_renderer_->ReadProbe(width, height, pixels);
    read = true;
  }
  surface_manager_->MakeCurrent(false);
  const auto locked_start = std::chrono::steady_clock::now();
  if (drawn || drew_flat) {
    surface_manager_->SwapBack();
  }
  const auto locked_ms = MillisecondsSince(locked_start);
  const auto total_ms = MillisecondsSince(start);
  drawn_generation_ = generation;
  {
    std::lock_guard<std::mutex> lock(projection_mutex_);
    auto& counters = projection_counters_;
    if (drawn) {
      if (drew_frame) {
        counters.frames++;
        Keep(counters.frame_ms, total_ms);
        Keep(counters.size_ms, size_ms);
        Keep(counters.mpv_ms, mpv_ms);
        Keep(counters.view_ms, view_ms);
      } else {
        counters.redraws++;
        Keep(counters.redraw_ms, total_ms);
      }
      Keep(counters.locked_ms, locked_ms);
    } else {
      counters.failed++;
    }
    counters.frame_width = projection_renderer_->frame_width();
    counters.frame_height = projection_renderer_->frame_height();
    counters.error = projection_renderer_->error();
    if (read) {
      std::copy(pixels, pixels + 5, counters.probe);
      counters.probe_ready = true;
      counters.probe_requested = false;
    }
  }
  if (drawn || drew_flat) {
    try {
      registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_);
    } catch (...) {
      // The texture may be unregistered meanwhile, as in |Render|.
    }
  }
  // No mpv_render_context_report_swap here (design 2.11 asked whether swaps
  // should be reported): once a swap is reported, vo_libmpv waits for the
  // next one before it hands over each frame, so mpv's frames waited for this
  // thread's glFinish. On the RTX 4060 an 8K video then had 30 to 53 frame
  // intervals over 50 ms in 10 s instead of none (2026-10-09).
}

flutter::EncodableMap VideoOutput::SetProjection(
    std::optional<ProjectionSetup> setup) {
  flutter::EncodableMap result;
  auto future = thread_pool_ref_->Post([&]() {
    const auto fail = [&](const std::string& reason) {
      result[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
      result[flutter::EncodableValue("reason")] =
          flutter::EncodableValue(reason);
    };
    if (surface_manager_ == nullptr) {
      fail("software rendering");
      return;
    }
    if (device_lost_ || surface_manager_->IsDeviceLost()) {
      fail("graphics device lost");
      return;
    }
    result[flutter::EncodableValue("clientVersion")] =
        flutter::EncodableValue(surface_manager_->client_version());
    // Back to upstream's texture at the size of the video, and the frame
    // drawn into it at once, also when the video is paused
    const auto to_flat = [&]() {
      {
        std::lock_guard<std::mutex> lock(projection_mutex_);
        projection_ = nullptr;
      }
      if (projection_renderer_ != nullptr) {
        surface_manager_->MakeCurrent(true);
        projection_renderer_->Release();
        surface_manager_->MakeCurrent(false);
        projection_renderer_.reset();
      }
      surface_manager_->SetDoubleBuffered(false);
      CheckAndResize();
      Render();
    };
    if (!setup.has_value()) {
      to_flat();
      result[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
      return;
    }
    if (projection_renderer_ == nullptr) {
      projection_renderer_ = std::make_unique<ProjectionRenderer>();
    }
    surface_manager_->MakeCurrent(true);
    // The pass of this kind compiled and linked now: a driver that refuses it
    // refuses the projection with the shader's log, and the page plays the
    // video flat with its message, rather than a view that stays black while
    // the video plays (the draws would only count as failed)
    const auto ready =
        projection_renderer_->Prepare(surface_manager_->client_version()) &&
        projection_renderer_->PrepareProgram(setup->kind);
    surface_manager_->MakeCurrent(false);
    result[flutter::EncodableValue("glRenderer")] =
        flutter::EncodableValue(projection_renderer_->gl_renderer());
    if (!ready) {
      fail(projection_renderer_->error());
      if (CurrentProjection() != nullptr) {
        // Without its renderer a projection still on would leave the texture
        // as it is: the player is flat again, as before its first projection
        to_flat();
      } else {
        surface_manager_->MakeCurrent(true);
        projection_renderer_->Release();
        surface_manager_->MakeCurrent(false);
        projection_renderer_.reset();
      }
      return;
    }
    // Drawn into one of two internal textures while Flutter copies the
    // other (|ANGLESurfaceManager::SetDoubleBuffered|)
    surface_manager_->SetDoubleBuffered(true);
    const auto previous = CurrentProjection();
    if (previous != nullptr &&
        (previous->max_frame_width != setup->max_frame_width ||
         previous->max_frame_pixels != setup->max_frame_pixels)) {
      // Another tier: mpv draws its current frame again at the new size
      projection_renderer_->set_has_frame(false);
    } else if (previous != nullptr && !previous->SameFrameLayout(*setup)) {
      // Another frame layout for the same player, given before the next file
      // of a raw video's fallback chain opens (one lens, the LRV copy): the
      // frame kept is the previous file's, and read with the new lens regions
      // it would show a wrong picture, at once and at each view change, until
      // the new file's first frame. The output keeps its last view instead.
      projection_renderer_->set_has_frame(false);
    }
    const auto projection =
        std::make_shared<const ProjectionSetup>(std::move(setup.value()));
    {
      std::lock_guard<std::mutex> lock(projection_mutex_);
      projection_ = projection;
      view_generation_++;
      projection_counters_.gl_renderer = projection_renderer_->gl_renderer();
    }
    // The texture at the output size, then the view drawn into it from the
    // frame kept or from mpv's current frame, so that a paused video shows
    // at once
    CheckAndResize();
    if (texture_id_ && !device_lost_) {
      DrawProjection(*projection);
    }
    int32_t width = 1, height = 1;
    projection->OutputSize(&width, &height);
    result[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    result[flutter::EncodableValue("outputWidth")] =
        flutter::EncodableValue(width);
    result[flutter::EncodableValue("outputHeight")] =
        flutter::EncodableValue(height);
  });
  future.wait();
  return result;
}

void VideoOutput::SetView(const ProjectionView& view) {
  {
    std::lock_guard<std::mutex> lock(projection_mutex_);
    view_ = view;
    view_generation_++;
    if (projection_ == nullptr) {
      return;
    }
  }
  PostRedraw();
}

void VideoOutput::PostRedraw() {
  if (redraw_pending_.exchange(true)) {
    return;
  }
  thread_pool_ref_->Post([this]() {
    redraw_pending_ = false;
    if (destroyed_ || !texture_id_ || surface_manager_ == nullptr ||
        device_lost_) {
      return;
    }
    if (surface_manager_->IsDeviceLost()) {
      ReportDeviceLost();
      return;
    }
    if (const auto projection = CurrentProjection()) {
      DrawProjection(*projection);
    }
  });
}

flutter::EncodableMap VideoOutput::ProjectionStats(bool probe) {
  flutter::EncodableMap map;
  bool redraw = false;
  {
    std::lock_guard<std::mutex> lock(projection_mutex_);
    auto& counters = projection_counters_;
    const auto value = [&map](const char* key, flutter::EncodableValue v) {
      map[flutter::EncodableValue(key)] = std::move(v);
    };
    value("enabled", flutter::EncodableValue(projection_ != nullptr));
    value("frames", flutter::EncodableValue(counters.frames));
    value("redraws", flutter::EncodableValue(counters.redraws));
    value("failed", flutter::EncodableValue(counters.failed));
    // Lists of doubles rather than Float64List: Dart's decoder refused the
    // typed list this codec wrote ("Message corrupted")
    const auto list = [](const std::vector<double>& times) {
      flutter::EncodableList values;
      values.reserve(times.size());
      for (const auto time : times) {
        values.push_back(flutter::EncodableValue(time));
      }
      return flutter::EncodableValue(values);
    };
    value("frameMs", list(counters.frame_ms));
    value("redrawMs", list(counters.redraw_ms));
    value("lockedMs", list(counters.locked_ms));
    value("sizeMs", list(counters.size_ms));
    value("mpvMs", list(counters.mpv_ms));
    value("viewMs", list(counters.view_ms));
    value("frameWidth", flutter::EncodableValue(counters.frame_width));
    value("frameHeight", flutter::EncodableValue(counters.frame_height));
    if (projection_ != nullptr) {
      int32_t width = 1, height = 1;
      projection_->OutputSize(&width, &height);
      value("outputWidth", flutter::EncodableValue(width));
      value("outputHeight", flutter::EncodableValue(height));
    }
    value("error", flutter::EncodableValue(counters.error));
    value("glRenderer", flutter::EncodableValue(counters.gl_renderer));
    if (counters.probe_ready) {
      flutter::EncodableList pixels;
      for (const auto pixel : counters.probe) {
        pixels.push_back(flutter::EncodableValue(static_cast<int64_t>(pixel)));
      }
      value("probe", flutter::EncodableValue(pixels));
      counters.probe_ready = false;
    }
    counters.frames = 0;
    counters.redraws = 0;
    counters.failed = 0;
    counters.frame_ms.clear();
    counters.redraw_ms.clear();
    counters.locked_ms.clear();
    counters.size_ms.clear();
    counters.mpv_ms.clear();
    counters.view_ms.clear();
    if (probe && projection_ != nullptr) {
      counters.probe_requested = true;
      view_generation_++;
      redraw = true;
    }
  }
  if (redraw) {
    PostRedraw();
  }
  return map;
}
