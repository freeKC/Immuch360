// Immuch360: copied unchanged from media_kit_video (MIT, https://github.com/media-kit/media-kit, commit
// c533e446755f51cf53c7e57aea873f2aa5355f81, media_kit_video/android), for the quest flavour only: see
// licenses/libmpv-android/README.md
package com.alexmercerind.media_kit_video;

public interface TextureUpdateCallback {
    void onTextureUpdate(long id, long wid, int width, int height);
}
