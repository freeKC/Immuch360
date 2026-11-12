// Immuch360: copied unchanged from media_kit_video (MIT, https://github.com/media-kit/media-kit, commit
// c533e446755f51cf53c7e57aea873f2aa5355f81, media_kit_video/android), for the quest flavour only: see
// licenses/libmpv-android/README.md
/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.util.Log;

import java.util.HashMap;
import java.util.Locale;
import java.util.Objects;

import io.flutter.view.TextureRegistry;

public class VideoOutputManager {
    private static final String TAG = "VideoOutputManager";

    private final HashMap<Long, VideoOutput> videoOutputs = new HashMap<>();
    private final TextureRegistry textureRegistryReference;
    private final Object lock = new Object();

    VideoOutputManager(TextureRegistry textureRegistryReference) {
        this.textureRegistryReference = textureRegistryReference;
    }

    public void create(long handle, TextureUpdateCallback textureUpdateCallback) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.create: %d", handle));
            if (!videoOutputs.containsKey(handle)) {
                final VideoOutput videoOutput = new VideoOutput(textureRegistryReference, textureUpdateCallback);
                videoOutputs.put(handle, videoOutput);
            }
        }
    }

    public void dispose(long handle) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.dispose: %d", handle));
            if (videoOutputs.containsKey(handle)) {
                Objects.requireNonNull(videoOutputs.get(handle)).dispose();
                videoOutputs.remove(handle);
            }
        }
    }

    public void setSurfaceSize(long handle, int width, int height) {
        synchronized (lock) {
            Log.i(TAG, String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.setSurfaceSize: %d %d %d", handle, width, height));
            if (videoOutputs.containsKey(handle)) {
                Objects.requireNonNull(videoOutputs.get(handle)).setSurfaceSize(width, height);
            }
        }
    }
}
