package app.alextran.immich.core

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import me.albemala.native_video_player.PlayerSetup

/**
 * The player of the flat player of the app (native_video_player: the asset viewer and the share page on phones, TVs
 * and the Meta Quest window), with its link (see [PlayerLink]): Media3's buffers as before, started from the measured
 * link, a link that sends nothing tried again until it answers, and what Flutter is told of it while the video loads.
 * Set as NativeVideoPlayerPlugin.playerSetup by MainActivity.
 */
@OptIn(UnstableApi::class)
class FlatPlayerSetup(context: Context) : PlayerSetup {
  private val link = PlayerLink(context)

  override val player: ExoPlayer = link.applyTo(ExoPlayer.Builder(context), DefaultLoadControl()).build()

  override val loadErrorPolicy: LoadErrorHandlingPolicy = link.errorPolicy

  override fun onLoad() = link.reset()

  override fun link(): Map<String, Any?> {
    val waiting = player.playbackState == Player.STATE_BUFFERING
    if (!waiting && !player.isLoading) {
      // Nothing to tell while it neither waits nor loads: the same value, sent once
      return mapOf(PlayerLink.KEY_WAITING to false, PlayerLink.KEY_LOADING to false)
    }
    return link.snapshot(player)
  }

  override fun stuckError(): String? {
    if (!link.fedWithoutPicture(player)) return null
    val format = player.videoFormat
    return PlaybackErrors.token(PlaybackErrors.Kind.NO_FRAME, format?.sampleMimeType, format?.width ?: 0, format?.height ?: 0)
  }

  override fun release() = link.reset()
}
