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
 */
object StreamingLoadControl {
  const val MIN_BUFFER_MS = 50_000
  const val MAX_BUFFER_MS = 60_000
  const val BUFFER_FOR_PLAYBACK_MS = 2_500
  const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 5_000

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
      .build()

  /** Gives [builder] the streaming buffers when [url] is read over HTTP, and leaves it as it is otherwise */
  @OptIn(UnstableApi::class)
  fun applyTo(builder: ExoPlayer.Builder, url: String): ExoPlayer.Builder =
    if (isStreamed(url)) builder.setLoadControl(create()) else builder
}
