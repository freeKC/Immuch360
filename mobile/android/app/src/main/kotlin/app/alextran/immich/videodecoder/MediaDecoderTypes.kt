package app.alextran.immich.videodecoder

import android.media.MediaCodecList
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The MIME types of every decoder of the device, audio and video (MediaCodecList, the regular codecs), for the choice
 * of a film's player (film_player_choice.dart of the Dart side, release 46): the device's own player when it decodes
 * every stream of the film, libmpv otherwise. Read off the main thread, answered on it; the Dart side keeps the list
 * for the run of the app (device_decoder_types.dart).
 */
object MediaDecoderTypes {
  const val CHANNEL = "immuch360/media_decoders"
  private const val TAG = "MediaDecoderTypes"

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
      if (call.method != "mimeTypes") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val main = Handler(Looper.getMainLooper())
      Thread {
        val types =
          try {
            list()
          } catch (e: Exception) {
            Log.w(TAG, "The decoders of the device could not be listed", e)
            null
          }
        main.post {
          if (types == null) result.error("DECODERS_FAILED", "The decoders could not be listed", null)
          else result.success(types)
        }
      }.start()
    }
  }

  /** The MIME types the decoders of the device take, lower case, each once */
  fun list(): List<String> =
    MediaCodecList(MediaCodecList.REGULAR_CODECS)
      .codecInfos
      .filter { !it.isEncoder }
      .flatMap { info -> info.supportedTypes.map { it.lowercase() } }
      .distinct()
      .sorted()
}
