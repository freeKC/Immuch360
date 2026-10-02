package app.alextran.immich.videothumbnail

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Host side of the VideoThumbnailApi pigeon: a frame of a video as a JPEG, for the network share browser.
 *
 * [MediaMetadataRetriever] reads the video over HTTP from the media bridge of the app, by ranges: only the index of
 * the file and the samples around the frame. Off the main thread; the browser asks for two frames at a time at most.
 *
 * A frame not taken within [TIMEOUT_SECONDS] fails then, for the browser to go on with the next video. The retriever
 * cannot be stopped while it reads: it is left to end on its own thread, and the next frame starts on another thread
 * rather than waiting behind it.
 */
class VideoThumbnailApiImpl : VideoThumbnailApi {
  override fun thumbnailForUrl(
    url: String,
    headers: Map<String, String>,
    timeMs: Long,
    maxWidth: Long,
    callback: (Result<ByteArray>) -> Unit,
  ) {
    val replied = AtomicBoolean(false)
    fun reply(result: Result<ByteArray>) {
      if (replied.compareAndSet(false, true)) {
        callback(result)
      }
    }
    val timeout =
      timer.schedule(
        Runnable { reply(Result.failure(FlutterError("TIMEOUT", "No frame after $TIMEOUT_SECONDS s", null))) },
        TIMEOUT_SECONDS,
        TimeUnit.SECONDS,
      )
    executor.execute {
      val result =
        try {
          Result.success(frameOf(url, headers, timeMs, maxWidth.toInt()))
        } catch (e: Exception) {
          Result.failure(FlutterError("THUMBNAIL_FAILED", e.message ?: e.javaClass.simpleName, null))
        } catch (e: OutOfMemoryError) {
          Result.failure(FlutterError("THUMBNAIL_FAILED", "Out of memory", null))
        }
      timeout.cancel(false)
      reply(result)
    }
  }

  private fun frameOf(url: String, headers: Map<String, String>, timeMs: Long, maxWidth: Int): ByteArray {
    val retriever = MediaMetadataRetriever()
    try {
      retriever.setDataSource(url, headers)
      val durationMs =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
      // A video shorter than the time asked for: its middle frame
      val atMs = if (durationMs in 1..timeMs) durationMs / 2 else timeMs
      val frame =
        scaledFrame(retriever, atMs * 1000, maxWidth)
          ?: retriever.frameAtTime
          ?: throw IllegalStateException("No frame in the video")
      val bitmap = scaledDown(frame, maxWidth)
      try {
        val out = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)) {
          throw IllegalStateException("The frame could not be encoded")
        }
        return out.toByteArray()
      } finally {
        if (bitmap !== frame) {
          bitmap.recycle()
        }
        frame.recycle()
      }
    } finally {
      try {
        retriever.release()
      } catch (e: Exception) {
        // Nothing more to free
      }
    }
  }

  /**
   * The frame at [timeUs], the nearest sync frame. Android 8.1 and later decode it straight at the size of the
   * thumbnail: an 8K 360° frame would take more than 100 MB at full size.
   */
  private fun scaledFrame(retriever: MediaMetadataRetriever, timeUs: Long, maxWidth: Int): Bitmap? {
    val option = MediaMetadataRetriever.OPTION_CLOSEST_SYNC
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
      // getScaledFrameAtTime fits the frame in the box keeping its aspect ratio: a box four times as tall as it is
      // wide keeps a portrait video [maxWidth] pixels wide too
      return retriever.getScaledFrameAtTime(timeUs, option, maxWidth, maxWidth * 4)
    }
    return retriever.getFrameAtTime(timeUs, option)
  }

  /** [frame] at most [maxWidth] pixels wide, keeping its aspect ratio */
  private fun scaledDown(frame: Bitmap, maxWidth: Int): Bitmap {
    if (frame.width <= maxWidth) {
      return frame
    }
    val height = max(1, (frame.height.toDouble() * maxWidth / frame.width).roundToInt())
    return Bitmap.createScaledBitmap(frame, maxWidth, height, true)
  }

  private companion object {
    const val JPEG_QUALITY = 80

    /** Longest a frame takes */
    const val TIMEOUT_SECONDS = 45L

    /**
     * Shared by the engines the app starts (the UI, the background workers). A thread for each frame under way, as
     * many as the browser asks for at once (two), and one more for each retriever still reading after its frame
     * timed out; idle threads end after a minute.
     */
    val executor by lazy { Executors.newCachedThreadPool() }

    /** Fails the frames that take too long */
    val timer by lazy { ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true } }
  }
}
