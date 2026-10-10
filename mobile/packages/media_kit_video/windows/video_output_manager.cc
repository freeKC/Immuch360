// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output_manager.h"

VideoOutputManager::VideoOutputManager(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

void VideoOutputManager::Create(
    int64_t handle,
    VideoOutputConfiguration configuration,
    std::function<void(int64_t, int64_t, int64_t)> texture_update_callback) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) == video_outputs_.end()) {
      auto instance = std::make_unique<VideoOutput>(
          handle, configuration, registrar_, thread_pool_.get());
      instance->SetTextureUpdateCallback(texture_update_callback);
      {
        std::lock_guard<std::mutex> lookup_lock(lookup_mutex_);
        lookup_[handle] = instance.get();
      }
      video_outputs_.insert(std::make_pair(handle, std::move(instance)));
    }
  }).detach();
}

void VideoOutputManager::SetSize(int64_t handle,
                                 std::optional<int64_t> width,
                                 std::optional<int64_t> height) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      video_outputs_[handle]->SetSize(width, height);
    }
  }).detach();
}

void VideoOutputManager::Dispose(int64_t handle) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (video_outputs_.find(handle) != video_outputs_.end()) {
      {
        std::lock_guard<std::mutex> lookup_lock(lookup_mutex_);
        lookup_.erase(handle);
      }
      video_outputs_.erase(handle);
    }
  }).detach();
}

void VideoOutputManager::SetProjection(
    int64_t handle,
    std::optional<ProjectionSetup> setup,
    std::function<void(flutter::EncodableMap)> done) {
  std::thread([=]() {
    std::lock_guard<std::mutex> lock(mutex_);
    auto output = video_outputs_.find(handle);
    if (output == video_outputs_.end()) {
      done(flutter::EncodableMap{
          {flutter::EncodableValue("ok"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("reason"),
           flutter::EncodableValue("no video output")},
      });
      return;
    }
    done(output->second->SetProjection(setup));
  }).detach();
}

bool VideoOutputManager::SetView(int64_t handle, const ProjectionView& view) {
  std::lock_guard<std::mutex> lookup_lock(lookup_mutex_);
  auto output = lookup_.find(handle);
  if (output == lookup_.end()) {
    return false;
  }
  output->second->SetView(view);
  return true;
}

std::optional<flutter::EncodableMap> VideoOutputManager::ProjectionStats(
    int64_t handle,
    bool probe) {
  std::lock_guard<std::mutex> lookup_lock(lookup_mutex_);
  auto output = lookup_.find(handle);
  if (output == lookup_.end()) {
    return std::nullopt;
  }
  return output->second->ProjectionStats(probe);
}

VideoOutputManager::~VideoOutputManager() {
  std::lock_guard<std::mutex> lock(mutex_);
  {
    std::lock_guard<std::mutex> lookup_lock(lookup_mutex_);
    lookup_.clear();
  }
  // |VideoOutput| destructor will do the relevant cleanup.
  video_outputs_.clear();
  // This destructor is only called when the plugin is being destroyed i.e. the
  // application is being closed. So, doesn't really matter on the other hand.
}
