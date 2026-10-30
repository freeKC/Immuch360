package app.alextran.immich.immersive

import androidx.media3.common.PlaybackException

/**
 * What the immersive viewer does when the video of a 360° media stops in the middle (lot quest-playback-resilience,
 * 30 October 2026). The need comes from the exhibition builds of ppawelstachh-sys/Immuch360 (branch immuch360), on a
 * Meta Quest Pro: sound without picture for a local 360° MP4, then a decoder crash ("error 100", the media server
 * died) at a fixed point of the same film, which their v10 to v12 got around with one retry where it stopped, the
 * last frame kept on screen. Rewritten here for every video of the viewer; the viewer reports what happens, this class
 * says what to do and calls nothing itself, so that every rule is unit tested.
 *
 * - A failure of the decoder or of the media server ([Cause.DECODER], [Cause.MEDIA_SERVER]) once the url showed a
 *   frame gets one [Action.Restart]: a new player, the same url, from where it stopped. One per media: a second
 *   failure, or a failure of the restarted player before its first frame, is left to the viewer ([Action.PassOn]),
 *   which tries the server's transcoded stream and then shows the error, so the retries never loop. A failure before
 *   the first frame is a video that does not start, left to the viewer as well.
 * - A video that plays (its position moves on, so the sound plays) and renders no frame for [NO_PICTURE_MS] of its
 *   time: after frames were shown, the picture stopped and the same retry restarts it ([Cause.PICTURE_STOPPED]);
 *   from the start, or once the retry is spent, [Action.NoPicture], said once per url: the viewer switches to the
 *   transcoded stream when it has one, otherwise says so with the codec, the size, the frame rate and the bit rate.
 *   A pause, a wait for data and a seek never count: the position stands still, or the count starts again.
 *
 * Each media (and each visitor of a kiosk, whose film starts over on a new player) gets its retry: [onMedia].
 */
internal class PlaybackRecovery {
  enum class Cause {
    /** The video or audio decoder failed, or the headset took it back while the viewer was in front. */
    DECODER,

    /** The audio output failed: the media server or the audio server went away. */
    MEDIA_SERVER,

    /** The picture stopped while the position moved on. */
    PICTURE_STOPPED,
  }

  sealed interface Action {
    /** Nothing to do. */
    data object None : Action

    /** A new player for the same url, from [positionMs], the last frame left on screen meanwhile. */
    data class Restart(val positionMs: Long, val cause: Cause) : Action

    /** The viewer's own fallbacks: the transcoded stream once, then the error. */
    data object PassOn : Action

    /**
     * No picture for [NO_PICTURE_MS] at [positionMs]: the transcoded stream if there is one, else the notice with the
     * details of the video. [framesBefore]: the url showed frames before (the picture stopped), or none at all.
     */
    data class NoPicture(val positionMs: Long, val framesBefore: Boolean) : Action
  }

  /** The current url showed a frame: its first frame callback, or a count of rendered frames that went up. */
  var framesSeen = false
    private set

  private var retryLeft = true
  private var noPictureSaid = false

  /** The rendered frames read last, -1 before the first read of the url. */
  private var lastFrames = -1

  /** The position when the count of frames last moved (or the first read, or after a seek); null until then. */
  private var anchorMs: Long? = null

  /** The last position read, for a failure that reports none. */
  private var lastPositionMs = 0L

  /** A new media, or the next visitor of a kiosk: one retry again, nothing seen. */
  fun onMedia() {
    retryLeft = true
    lastPositionMs = 0L
    onPlay()
  }

  /**
   * A url starts on a player: the first one of the media, the transcoded stream, a restart. The frames count from
   * here; the retry stays spent.
   */
  fun onPlay() {
    framesSeen = false
    noPictureSaid = false
    lastFrames = -1
    anchorMs = null
  }

  /** The current url rendered a frame (onRenderedFirstFrame, or the first frame of the lens compositor). */
  fun onFrame() {
    framesSeen = true
  }

  /** The position jumped (a seek): the frames after it take a moment, the count starts again from the next read. */
  fun onSeek() {
    anchorMs = null
  }

  /**
   * A read of the player every so often: whether it [playing] (ready and asked to play), its [positionMs], and the
   * frames its video renderer [renderedFrames] (0 without a video renderer).
   */
  fun onTick(playing: Boolean, positionMs: Long, renderedFrames: Int): Action {
    lastPositionMs = positionMs.coerceAtLeast(0L)
    if (renderedFrames != lastFrames) {
      // A count that went up between two reads is a frame on screen. A count that changes otherwise is a renderer
      // enabled again (the counters of the previous url, then new ones from 0): it only starts the wait again
      if (lastFrames >= 0 && renderedFrames > lastFrames) framesSeen = true
      lastFrames = renderedFrames
      anchorMs = positionMs
      return Action.None
    }
    if (!playing) return Action.None
    val anchor = anchorMs
    // A loop or a seek back the viewer did not report: the wait starts again there
    if (anchor == null || positionMs < anchor) {
      anchorMs = positionMs
      return Action.None
    }
    if (noPictureSaid || positionMs - anchor < NO_PICTURE_MS) return Action.None
    noPictureSaid = true
    if (framesSeen && retryLeft) {
      retryLeft = false
      return Action.Restart(positionMs, Cause.PICTURE_STOPPED)
    }
    return Action.NoPicture(positionMs, framesSeen)
  }

  /** The player failed with [errorCode] (PlaybackException) at [positionMs] (0 or less when it reports none). */
  fun onFailure(errorCode: Int, positionMs: Long): Action {
    val cause = causeOf(errorCode) ?: return Action.PassOn
    if (!framesSeen || !retryLeft) return Action.PassOn
    retryLeft = false
    return Action.Restart(if (positionMs > 0) positionMs else lastPositionMs, cause)
  }

  companion object {
    /** Media time a playing video may go without a new frame before it counts as a picture missing. */
    const val NO_PICTURE_MS = 3_000L

    /** How often the viewer reads the player while a video plays. */
    const val TICK_MS = 500L

    /** Frames per second below which a video is not watched for a missing picture, see [watches]. */
    const val MIN_WATCHED_FRAME_RATE = 1f

    /**
     * Whether a video of [frameRate] frames per second (0 or less when unknown) is watched for a missing picture: not
     * a slide show made into a video, whose frames come seconds apart while its music plays.
     */
    fun watches(frameRate: Float): Boolean = frameRate <= 0f || frameRate >= MIN_WATCHED_FRAME_RATE

    /**
     * The failures a new player may get around: the decoder that failed or was taken back, the audio output that
     * went away with the media server. Not a format the headset cannot decode, nor a source that cannot be read:
     * a new player would meet them again.
     */
    fun causeOf(errorCode: Int): Cause? =
      when (errorCode) {
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED -> Cause.DECODER
        PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
        PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED -> Cause.MEDIA_SERVER
        else -> null
      }
  }
}
