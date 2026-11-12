package app.alextran.immich.mpv

import android.content.Context
import android.util.Log
import com.alexmercerind.media_kit_video.MediaKitVideoPlugin
import com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// libmpv in the quest flavour (release 46, the films the headset cannot decode, film_player_choice.dart of the Dart
// side). What the plugins of media_kit_video and media_kit_libs_android_video do on Android, registered here rather
// than by Flutter, so that the phone flavour carries none of it: the texture output of media_kit_video
// (com.alexmercerind.media_kit_video, MIT, the copy of src/quest/java, see licenses/libmpv-android/README.md), and
// libmpv loaded with the application context handed to the helper of media_kit_libs_android_video, which gives the
// Java VM to FFmpeg for the MediaCodec decoders. The libraries (libmpv.so, libmediakitandroidhelper.so) come from
// media-kit's libmpv-android-video-build v1.1.7, downloaded and checked by the quest build (app/build.gradle).
// The channel immuch360/mpv tells the Dart side (android_mpv.dart) whether libmpv loaded.

/** See the top of this file */
internal object MpvPlayers {
  private const val TAG = "MpvPlayers"
  private const val CHANNEL = "immuch360/mpv"

  private val loaded: Boolean by lazy {
    try {
      System.loadLibrary("mpv")
      true
    } catch (e: Throwable) {
      Log.e(TAG, "libmpv did not load", e)
      false
    }
  }

  fun register(engine: FlutterEngine, context: Context) {
    val ready =
      loaded &&
        try {
          MediaKitAndroidHelper.setApplicationContextJava(context.applicationContext)
          true
        } catch (e: Throwable) {
          Log.e(TAG, "The media_kit helper did not start", e)
          false
        }
    if (ready) {
      engine.plugins.add(MediaKitVideoPlugin())
    }
    MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      if (call.method == "available") result.success(ready) else result.notImplemented()
    }
  }
}
