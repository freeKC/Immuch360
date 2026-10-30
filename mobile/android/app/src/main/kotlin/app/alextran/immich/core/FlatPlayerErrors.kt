package app.alextran.immich.core

import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlaybackException
import androidx.media3.exoplayer.ExoPlayer

/**
 * What the flat player of the app (native_video_player, the player of the asset viewer on phones, TVs and the Meta
 * Quest) sends Flutter for an error it knows (see [PlaybackErrors]): a token with the kind, the codec and the frame of
 * the video, which Flutter puts in its own words; null for any other error, whose text goes as before. Set as
 * NativeVideoPlayerPlugin.errorToken by MainActivity.
 */
object FlatPlayerErrors {
  @OptIn(UnstableApi::class)
  fun token(error: PlaybackException, player: ExoPlayer): String? {
    val format = videoFormatOf(error, player)
    val gotMedia = player.totalBufferedDuration >= StreamingLoadControl.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS
    val kind = PlaybackErrors.kindOf(error, videoKnown = format != null, decoderGotMedia = gotMedia) ?: return null
    return PlaybackErrors.token(kind, format?.sampleMimeType, format?.width ?: 0, format?.height ?: 0)
  }

  /**
   * The video format behind [error]: the one [player] plays, else the one its video renderer failed on (a decoder that
   * does not start never gives the player a video format).
   */
  @OptIn(UnstableApi::class)
  private fun videoFormatOf(error: PlaybackException, player: ExoPlayer): Format? =
    player.videoFormat
      ?: (error as? ExoPlaybackException)?.takeIf { it.type == ExoPlaybackException.TYPE_RENDERER }?.rendererFormat
        ?.takeIf { MimeTypes.isVideo(it.sampleMimeType) }
}
