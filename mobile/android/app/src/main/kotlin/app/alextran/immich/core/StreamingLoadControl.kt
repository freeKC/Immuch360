package app.alextran.immich.core

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl

/**
 * The buffering of the native video players for a video read over the network (the media bridge of the app on
 * 127.0.0.1, which streams from a network share, or a server), so that a share that answers in bursts (SMB on a
 * Freebox Server) no longer pauses the video every few seconds. Media3 1.10 keeps loading until 50 s are buffered and
 * starts again as soon as the buffer falls under 50 s; here the loading goes on to 60 s and starts again under 50 s,
 * so that the buffer never runs low while the share stalls. The playback waits for 2.5 s of media before it starts and
 * for 5 s after a stall (1 s and 2 s by default), so that a burst does not end in another stall right away. Local
 * files keep the defaults of Media3.
 *
 * Media3 also stops loading once the buffer holds a number of bytes, about 137 MiB for a video with sound, whatever
 * the durations above: that is less than 9 s of a 360 video at 132 Mbit/s, so a stall of the share longer than that
 * stalled the video. The buffer here may hold half of the Java heap of the app (largeHeap, 512 MiB on recent phones),
 * up to [MAX_TARGET_BUFFER_BYTES] and never less than the Media3 default, see [targetBufferBytes].
 */
object StreamingLoadControl {
  const val MIN_BUFFER_MS = 50_000
  const val MAX_BUFFER_MS = 60_000
  const val BUFFER_FOR_PLAYBACK_MS = 2_500
  const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 5_000

  /** The most bytes the buffer holds, whatever the heap: 24 s of a video at 132 Mbit/s */
  const val MAX_TARGET_BUFFER_BYTES = 384 * 1024 * 1024

  /** The bytes Media3 buffers by default for a streamed video with sound, the least the buffer holds here */
  @OptIn(UnstableApi::class)
  const val MIN_TARGET_BUFFER_BYTES =
    DefaultLoadControl.DEFAULT_VIDEO_BUFFER_SIZE + DefaultLoadControl.DEFAULT_AUDIO_BUFFER_SIZE

  /** Whether [url] is read over HTTP: the loopback media bridge, or any http(s) URL */
  fun isStreamed(url: String): Boolean {
    val scheme = url.substringBefore(':', missingDelimiterValue = "").lowercase()
    return scheme == "http" || scheme == "https"
  }

  @OptIn(UnstableApi::class)
  fun create(): LoadControl =
    DefaultLoadControl.Builder()
      .setBufferDurationsMs(
        MIN_BUFFER_MS,
        MAX_BUFFER_MS,
        BUFFER_FOR_PLAYBACK_MS,
        BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
      )
      .setTargetBufferBytes(targetBufferBytes(Runtime.getRuntime().maxMemory()))
      .build()

  /**
   * The bytes the buffer of a streamed video may hold for a Java heap of [maxHeapBytes]: half of it, from
   * [MIN_TARGET_BUFFER_BYTES] to [MAX_TARGET_BUFFER_BYTES]. The loading stops there even if the buffer holds less
   * than [MIN_BUFFER_MS] of media, so that a video with a high bitrate does not run the app out of memory.
   */
  fun targetBufferBytes(maxHeapBytes: Long): Int =
    (maxHeapBytes / 2).coerceIn(MIN_TARGET_BUFFER_BYTES.toLong(), MAX_TARGET_BUFFER_BYTES.toLong()).toInt()

  /**
   * The media the player waits for, loaded ahead of the position, before it plays: [BUFFER_FOR_PLAYBACK_MS] at first
   * and after a seek, [BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS] after a stall ([rebuffering]). [streamed] is whether the
   * video gets these buffers (see [isStreamed]); a local file waits for the defaults of Media3.
   */
  @OptIn(UnstableApi::class)
  fun playbackBufferMs(streamed: Boolean, rebuffering: Boolean): Int =
    when {
      streamed && rebuffering -> BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS
      streamed -> BUFFER_FOR_PLAYBACK_MS
      rebuffering -> DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS
      else -> DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS
    }

  /** Gives [builder] the streaming buffers when [url] is read over HTTP, and leaves it as it is otherwise */
  @OptIn(UnstableApi::class)
  fun applyTo(builder: ExoPlayer.Builder, url: String): ExoPlayer.Builder =
    if (isStreamed(url)) builder.setLoadControl(create()) else builder
}
