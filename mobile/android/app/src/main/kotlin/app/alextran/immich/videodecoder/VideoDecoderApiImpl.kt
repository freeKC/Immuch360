package app.alextran.immich.videodecoder

import android.util.Log
import app.alextran.immich.core.VideoDecoders
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TAG = "VideoDecoderApi"

/**
 * Host side of the VideoDecoderApi pigeon: whether the device decodes a video, and the list of its video decoders,
 * see [VideoDecoders]. The first question reads the decoder list of the system, which can take a moment on some
 * devices: the work runs off the main thread, and the answer goes back to Flutter on the main thread.
 */
class VideoDecoderApiImpl : VideoDecoderApi {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

  override fun canDecode(
    codec: String,
    codecs: String?,
    width: Long,
    height: Long,
    frameRate: Double,
    callback: (Result<DecodeVerdict>) -> Unit,
  ) {
    answer(callback) {
      val verdict = VideoDecoders.canDecode(codec, codecs, width.toInt(), height.toInt(), frameRate)
      DecodeVerdict(
        supported = verdict.supported,
        hardware = verdict.hardware,
        maxWidth = verdict.maxWidth.toLong(),
        maxHeight = verdict.maxHeight.toLong(),
        reason = verdict.reason,
      )
    }
  }

  override fun listDecoders(callback: (Result<List<DecoderInfo>>) -> Unit) {
    answer(callback) {
      VideoDecoders.listDecoders().map { decoder ->
        DecoderInfo(
          name = decoder.name,
          codec = decoder.mime,
          hardware = decoder.hardware,
          maxWidth = decoder.maxWidth.toLong(),
          maxHeight = decoder.maxHeight.toLong(),
          maxFrameRate = decoder.maxFrameRate,
        )
      }
    }
  }

  /** Runs [work] on a background thread and hands its result, or its failure, to [callback] on the main thread. */
  private fun <T> answer(callback: (Result<T>) -> Unit, work: () -> T) {
    scope.launch {
      val result =
        withContext(Dispatchers.Default) {
          try {
            Result.success(work())
          } catch (e: CancellationException) {
            throw e
          } catch (e: Exception) {
            Log.e(TAG, "cannot answer about the video decoders", e)
            Result.failure(FlutterError("DECODERS_FAILED", e.message ?: e.javaClass.simpleName, null))
          }
        }
      callback(result)
    }
  }
}
