// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "media_kit_video_plugin.h"
#include "utils.h"

#include <Windows.h>

#include <algorithm>
#include <memory>

namespace media_kit_video {

namespace {

// Immuch360: the arguments of the renderer C calls (IMMUCH360-NOTE.md, patch
// 6), whatever number type the standard codec chose for them.

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  auto entry = map.find(flutter::EncodableValue(key));
  return entry == map.end() ? nullptr : &entry->second;
}

int64_t ToInt64(const flutter::EncodableValue* value, int64_t fallback) {
  if (value == nullptr) {
    return fallback;
  }
  if (auto v = std::get_if<int32_t>(value)) {
    return *v;
  }
  if (auto v = std::get_if<int64_t>(value)) {
    return *v;
  }
  if (auto v = std::get_if<double>(value)) {
    return static_cast<int64_t>(*v);
  }
  if (auto v = std::get_if<std::string>(value)) {
    try {
      return std::stoll(*v);
    } catch (...) {
      return fallback;
    }
  }
  return fallback;
}

double ToDouble(const flutter::EncodableValue* value, double fallback) {
  if (value == nullptr) {
    return fallback;
  }
  if (auto v = std::get_if<double>(value)) {
    return *v;
  }
  if (auto v = std::get_if<int32_t>(value)) {
    return *v;
  }
  if (auto v = std::get_if<int64_t>(value)) {
    return static_cast<double>(*v);
  }
  return fallback;
}

bool ToBool(const flutter::EncodableValue* value, bool fallback) {
  if (value == nullptr) {
    return fallback;
  }
  if (auto v = std::get_if<bool>(value)) {
    return *v;
  }
  return fallback;
}

std::vector<float> ToFloats(const flutter::EncodableValue* value) {
  std::vector<float> floats;
  if (value == nullptr) {
    return floats;
  }
  if (auto list = std::get_if<flutter::EncodableList>(value)) {
    for (const auto& item : *list) {
      floats.push_back(static_cast<float>(ToDouble(&item, 0.0)));
    }
  } else if (auto doubles = std::get_if<std::vector<double>>(value)) {
    for (const auto item : *doubles) {
      floats.push_back(static_cast<float>(item));
    }
  } else if (auto singles = std::get_if<std::vector<float>>(value)) {
    floats = *singles;
  }
  return floats;
}

void CopyFloats(const flutter::EncodableValue* value, float* out, size_t size) {
  const auto floats = ToFloats(value);
  if (floats.size() == size) {
    std::copy(floats.begin(), floats.end(), out);
  }
}

ProjectionSetup ToProjectionSetup(const flutter::EncodableMap& arguments) {
  ProjectionSetup setup;
  setup.kind = static_cast<int32_t>(ToInt64(Find(arguments, "kind"), 0));
  CopyFloats(Find(arguments, "eye"), setup.eye, 4);
  CopyFloats(Find(arguments, "crop"), setup.crop, 4);
  setup.tracks = static_cast<int32_t>(ToInt64(Find(arguments, "tracks"), 1));
  CopyFloats(Find(arguments, "streamsEnabled"), setup.enabled, 2);
  if (auto uniforms = Find(arguments, "uniforms")) {
    if (auto map = std::get_if<flutter::EncodableMap>(uniforms)) {
      for (const auto& [key, values] : *map) {
        if (auto name = std::get_if<std::string>(&key)) {
          setup.uniforms[*name] = ToFloats(&values);
        }
      }
    }
  }
  setup.max_frame_width = static_cast<int32_t>(
      ToInt64(Find(arguments, "maxFrameWidth"), setup.max_frame_width));
  setup.max_frame_pixels =
      ToInt64(Find(arguments, "maxFramePixels"), setup.max_frame_pixels);
  setup.output_width =
      static_cast<int32_t>(ToInt64(Find(arguments, "outputWidth"), 1));
  setup.output_height =
      static_cast<int32_t>(ToInt64(Find(arguments, "outputHeight"), 1));
  setup.max_output_height = static_cast<int32_t>(
      ToInt64(Find(arguments, "maxOutputHeight"), setup.max_output_height));
  // Immuch360, two players for one raw file (patch 7)
  setup.partner_stream = ToBool(Find(arguments, "partnerStream"), false);
  setup.secondary = ToBool(Find(arguments, "secondary"), false);
  return setup;
}

// Immuch360: the projection of the Spatial passes (IMMUCH360-NOTE.md, patch
// 11): renderer C's frame, as for an equirectangular projection, and the
// passes' setup. The eye and the crop of the projection are not read by them.
ProjectionSetup ToSpatialSetup(const flutter::EncodableMap& arguments) {
  ProjectionSetup setup;
  setup.kind = 0;
  setup.max_frame_width = static_cast<int32_t>(
      ToInt64(Find(arguments, "maxFrameWidth"), 3840));
  setup.max_frame_pixels =
      ToInt64(Find(arguments, "maxFramePixels"), 3840LL * 2160LL);
  setup.output_width =
      static_cast<int32_t>(ToInt64(Find(arguments, "outputWidth"), 1));
  setup.output_height =
      static_cast<int32_t>(ToInt64(Find(arguments, "outputHeight"), 1));
  setup.max_output_height = static_cast<int32_t>(
      ToInt64(Find(arguments, "maxOutputHeight"), setup.max_output_height));
  SpatialSetup spatial;
  spatial.layout = static_cast<int32_t>(
      std::clamp<int64_t>(ToInt64(Find(arguments, "layout"), 0), 0, 4));
  spatial.projection = static_cast<int32_t>(
      std::clamp<int64_t>(ToInt64(Find(arguments, "projection"), 0), 0, 1));
  spatial.half_sphere = ToBool(Find(arguments, "halfSphere"), false);
  spatial.quality = static_cast<int32_t>(
      std::clamp<int64_t>(ToInt64(Find(arguments, "quality"), 1), 0, 2));
  spatial.adaptive = ToBool(Find(arguments, "adaptive"), true);
  setup.spatial = spatial;
  return setup;
}

}  // namespace

MediaKitVideoPlugin* MediaKitVideoPlugin::instance_ = nullptr;

void MediaKitVideoPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<MediaKitVideoPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

MediaKitVideoPlugin::MediaKitVideoPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      video_output_manager_(std::make_unique<VideoOutputManager>(registrar)) {
  instance_ = this;
  flutter_window_ =
      ::GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT);
  original_window_proc_ = reinterpret_cast<WNDPROC>(
      ::SetWindowLongPtr(flutter_window_, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(WindowProcDelegate)));

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.alexmercerind/media_kit_video",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([&](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

MediaKitVideoPlugin::~MediaKitVideoPlugin() {
  if (flutter_window_ && original_window_proc_) {
    ::SetWindowLongPtr(flutter_window_, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(original_window_proc_));
  }
  if (instance_ == this) {
    instance_ = nullptr;
  }
}

void MediaKitVideoPlugin::RunOnMainThread(std::function<void()> task) {
  if (!flutter_window_) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(main_thread_tasks_mutex_);
    main_thread_tasks_.push(std::move(task));
  }

  ::PostMessage(flutter_window_, kMainThreadTaskMessage, 0, 0);
}

LRESULT CALLBACK MediaKitVideoPlugin::WindowProcDelegate(HWND hwnd,
                                                         UINT message,
                                                         WPARAM wParam,
                                                         LPARAM lParam) {
  if (message == kMainThreadTaskMessage && instance_) {
    instance_->ProcessMainThreadTasks();
    return 0;
  }

  if (instance_ && instance_->original_window_proc_) {
    return ::CallWindowProc(instance_->original_window_proc_, hwnd, message,
                            wParam, lParam);
  }

  return ::DefWindowProc(hwnd, message, wParam, lParam);
}

void MediaKitVideoPlugin::ProcessMainThreadTasks() {
  std::queue<std::function<void()>> tasks_to_execute;

  {
    std::lock_guard<std::mutex> lock(main_thread_tasks_mutex_);
    tasks_to_execute.swap(main_thread_tasks_);
  }

  while (!tasks_to_execute.empty()) {
    auto task = std::move(tasks_to_execute.front());
    tasks_to_execute.pop();

    try {
      task();
    } catch (...) {
    }
  }
}

void MediaKitVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("VideoOutputManager.Create") == 0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto configuration = std::get<flutter::EncodableMap>(
        arguments[flutter::EncodableValue("configuration")]);

    auto handle_value = std::stoll(handle);
    auto configuration_value = VideoOutputConfiguration{};

    auto configuration_width =
        std::get<std::string>(configuration[flutter::EncodableValue("width")]);
    auto configuration_height =
        std::get<std::string>(configuration[flutter::EncodableValue("height")]);
    auto configuration_enable_hardware_acceleration = std::get<bool>(
        configuration[flutter::EncodableValue("enableHardwareAcceleration")]);
    if (configuration_width.compare("null") != 0) {
      configuration_value.width =
          static_cast<int64_t>(std::stoll(configuration_width.c_str()));
    }
    if (configuration_height.compare("null") != 0) {
      configuration_value.height =
          static_cast<int64_t>(std::stoll(configuration_height.c_str()));
    }
    configuration_value.enable_hardware_acceleration =
        configuration_enable_hardware_acceleration;

    video_output_manager_->Create(
        handle_value, configuration_value,
        [this, handle = handle_value](auto id, auto width, auto height) {
          RunOnMainThread([=]() {
            channel_->InvokeMethod(
                "VideoOutput.Resize",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {
                        flutter::EncodableValue("handle"),
                        flutter::EncodableValue(handle),
                    },
                    {
                        flutter::EncodableValue("id"),
                        flutter::EncodableValue(id),
                    },
                    {
                        flutter::EncodableValue("rect"),
                        flutter::EncodableValue(flutter::EncodableMap{
                            {
                                flutter::EncodableValue("left"),
                                flutter::EncodableValue(0),
                            },
                            {
                                flutter::EncodableValue("top"),
                                flutter::EncodableValue(0),
                            },
                            {
                                flutter::EncodableValue("width"),
                                flutter::EncodableValue(width),
                            },
                            {
                                flutter::EncodableValue("height"),
                                flutter::EncodableValue(height),
                            },
                        }),
                    },
                }),
                nullptr);
          });
        });
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("VideoOutputManager.Dispose") ==
             0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto handle_value = static_cast<int64_t>(std::stoll(handle.c_str()));
    video_output_manager_->Dispose(handle_value);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("VideoOutputManager.SetSize") ==
             0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto width =
        std::get<std::string>(arguments[flutter::EncodableValue("width")]);
    auto height =
        std::get<std::string>(arguments[flutter::EncodableValue("height")]);
    auto handle_value = static_cast<int64_t>(std::stoll(handle.c_str()));
    auto width_value = std::optional<int64_t>{};
    auto height_value = std::optional<int64_t>{};
    if (width.compare("null") != 0) {
      width_value = static_cast<int64_t>(std::stoll(width.c_str()));
    }
    if (height.compare("null") != 0) {
      height_value = static_cast<int64_t>(std::stoll(height.c_str()));
    }
    video_output_manager_->SetSize(handle_value, width_value, height_value);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetProjection") == 0) {
    // Immuch360: renderer C on or off (IMMUCH360-NOTE.md, patch 6). The
    // answer comes once the thread pool made the change, on the platform
    // thread as Flutter wants it.
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = ToInt64(Find(arguments, "handle"), 0);
    std::optional<ProjectionSetup> setup;
    if (ToBool(Find(arguments, "enabled"), false)) {
      setup = ToProjectionSetup(arguments);
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply =
        std::move(result);
    video_output_manager_->SetProjection(
        handle, setup, [this, reply](flutter::EncodableMap answer) {
          RunOnMainThread([reply, answer]() {
            reply->Success(flutter::EncodableValue(answer));
          });
        });
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetPartner") == 0) {
    // Immuch360: the second stream of a raw file from another player
    // (IMMUCH360-NOTE.md, patch 7), answered once the thread pool paired them
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply =
        std::move(result);
    video_output_manager_->SetPartner(
        ToInt64(Find(arguments, "handle"), 0),
        ToInt64(Find(arguments, "partner"), 0),
        [this, reply](flutter::EncodableMap answer) {
          RunOnMainThread([reply, answer]() {
            reply->Success(flutter::EncodableValue(answer));
          });
        });
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetView") == 0) {
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    ProjectionView view;
    view.yaw = static_cast<float>(ToDouble(Find(arguments, "yaw"), 0.0));
    view.pitch = static_cast<float>(ToDouble(Find(arguments, "pitch"), 0.0));
    view.fov = static_cast<float>(ToDouble(Find(arguments, "fov"), 90.0));
    view.sharp = ToBool(Find(arguments, "sharp"), true);
    const auto known = video_output_manager_->SetView(
        ToInt64(Find(arguments, "handle"), 0), view);
    result->Success(flutter::EncodableValue(known));
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.ProjectionStats") == 0) {
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto stats = video_output_manager_->ProjectionStats(
        ToInt64(Find(arguments, "handle"), 0),
        ToBool(Find(arguments, "probe"), false));
    if (stats.has_value()) {
      result->Success(flutter::EncodableValue(stats.value()));
    } else {
      result->Success(flutter::EncodableValue(std::monostate{}));
    }
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetSpatial") == 0) {
    // Immuch360: the Spatial passes on or off (IMMUCH360-NOTE.md, patch 11),
    // through the projection of renderer C; answered as SetProjection
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = ToInt64(Find(arguments, "handle"), 0);
    std::optional<ProjectionSetup> setup;
    if (ToBool(Find(arguments, "enabled"), false)) {
      setup = ToSpatialSetup(arguments);
      if (const auto viewpoint = Find(arguments, "viewpoint")) {
        video_output_manager_->SetViewpoint(
            handle, static_cast<float>(ToDouble(viewpoint, 0.5)));
      }
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply =
        std::move(result);
    video_output_manager_->SetProjection(
        handle, setup, [this, reply](flutter::EncodableMap answer) {
          RunOnMainThread([reply, answer]() {
            reply->Success(flutter::EncodableValue(answer));
          });
        });
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetViewpoint") == 0) {
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto known = video_output_manager_->SetViewpoint(
        ToInt64(Find(arguments, "handle"), 0),
        static_cast<float>(ToDouble(Find(arguments, "viewpoint"), 0.5)));
    result->Success(flutter::EncodableValue(known));
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SetSpatialDebug") == 0) {
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto known = video_output_manager_->SetSpatialDebug(
        ToInt64(Find(arguments, "handle"), 0),
        ToBool(Find(arguments, "disparityMap"), false));
    result->Success(flutter::EncodableValue(known));
  } else if (method_call.method_name().compare(
                 "VideoOutputManager.SpatialStats") == 0) {
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto stats = video_output_manager_->SpatialStats(
        ToInt64(Find(arguments, "handle"), 0),
        ToBool(Find(arguments, "probe"), false));
    if (stats.has_value()) {
      result->Success(flutter::EncodableValue(stats.value()));
    } else {
      result->Success(flutter::EncodableValue(std::monostate{}));
    }
  } else if (method_call.method_name().compare("Utils.EnterNativeFullscreen") ==
             0) {
    auto window =
        ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    Utils::EnterNativeFullscreen(window);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("Utils.ExitNativeFullscreen") ==
             0) {
    auto window =
        ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    Utils::ExitNativeFullscreen(window);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else {
    result->NotImplemented();
  }
}

}  // namespace media_kit_video
