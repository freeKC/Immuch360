package app.alextran.immich.immersive

import androidx.media3.common.PlaybackException

/**
 * What the immersive viewer does when the video of a 360° media stops in the middle (lot quest-playback-resilience,
 * 30 October 2026). The need comes from the exhibition builds of ppawelstachh-sys/Immuch360 (branch immuch360), on a
 * Meta Quest Pro: sound without picture for a local 360° MP4, then a decoder crash ("error 100", the media server
 * died) at a fixed point of the same film, around 432519 ms (07:12.5), which their v10 to v12 got around with one
 * retry: 1.2 s then 1.8 s for the media service to settle, then a new player from the sync frame at or after 07:20,
 * the last frame kept on screen meanwhile. Rewritten here for every video of the viewer; the viewer reports what
 * happens, this class says what to do and calls nothing itself, so that every rule is unit tested.
 *
 * - A failure of the decoder or of the media server ([Cause.DECODER], [Cause.MEDIA_SERVER]) once the url showed a
 *   frame gets one [Action.Restart]: after [RESTART_DELAY_MS], a new player for the same url. After the media server,
 *   from where it stopped; after a decoder, from [SKIP_PAST_FAULT_MS] past it, or the next sync frame from there when
 *   the file tells it ([resumeAt]), so that the new decoder does not meet the frames that broke the old one, never
 *   past the end. One per media: a second failure, or a failure of the restarted player before its first frame, is
 *   left to the viewer ([Action.PassOn]), which tries the server's transcoded stream and then shows the error, so the
 *   retries never loop. A failure before the first frame is a video that does not start, left to the viewer as well.
 *   While the restart waits ([restartPending]), what the old player reports belongs to the failure: [Action.None].
 * - A video that plays (its position moves on, so the sound plays) and renders no frame for [NO_PICTURE_MS] of its
 *   time: after frames were shown, the picture stopped and the same retry restarts it ([Cause.PICTURE_STOPPED]);
 *   from the start, or once the retry is spent, [Action.NoPicture], said once per url: the viewer switches to the
 *   transcoded stream when it has one, otherwise says so with the codec, the size, the frame rate and the bit rate.
 *   Frames that move again afterwards take the notice away ([Action.PictureBack]); the surface of the video panel
 *   given late watches the url again ([onSurface]). A pause, a wait for data and a seek never count: the position
 *   stands still, or the count starts again.
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

    /**
     * The video stopped at [positionMs] for [cause]: after [delayMs], a new player for the same url from [resumeMs],
     * the last frame left on screen meanwhile.
     */
    data class Restart(val positionMs: Long, val cause: Cause, val resumeMs: Long, val delayMs: Long) : Action {
      /**
       * After a decoder failure, where the viewer looks for the next sync frame of the file to start from (see
       * [resumeAt]); null for the other causes, which start at [resumeMs].
       */
      val syncFromMs: Long?
        get() = if (cause == Cause.DECODER) positionMs + SKIP_PAST_FAULT_MS else null
    }

    /** The viewer's own fallbacks: the transcoded stream once, then the error. */
    data object PassOn : Action

    /**
     * No picture for [NO_PICTURE_MS] at [positionMs]: the transcoded stream if there is one, else the notice with the
     * details of the video. [framesBefore]: the url showed frames before (the picture stopped), or none at all.
     */
    data class NoPicture(val positionMs: Long, val framesBefore: Boolean) : Action

    /** Frames move again after [NoPicture]: the notice goes, the details of the video come back. */
    data object PictureBack : Action
  }

  /** The current url showed a frame: its first frame callback, or a count of rendered frames that went up. */
  var framesSeen = false
    private set

  /**
   * A restart was asked and the new player has not started the url yet: the errors and the reads of the old player
   * belong to the failure it restarts from.
   */
  var restartPending = false
    private set

  private var retryLeft = true
  private var noPictureSaid = false

  /** [Action.NoPicture] was said and no frame came since. */
  private var pictureMissing = false

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
    restartPending = false
    framesSeen = false
    noPictureSaid = false
    pictureMissing = false
    lastFrames = -1
    anchorMs = null
  }

  /** The restart asked was dropped: the media changed or stopped meanwhile. The retry stays spent. */
  fun cancelRestart() {
    restartPending = false
  }

  /**
   * The video panel gave its surface while the url played: the frames skipped without it are no proof of a decoder
   * problem, the url is watched again from the next read.
   */
  fun onSurface() {
    noPictureSaid = false
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
    if (restartPending) return Action.None
    lastPositionMs = positionMs.coerceAtLeast(0L)
    if (renderedFrames != lastFrames) {
      // A count that went up between two reads is a frame on screen. A count that changes otherwise is a renderer
      // enabled again (the counters of the previous url, then new ones from 0): it only starts the wait again
      val moved = lastFrames >= 0 && renderedFrames > lastFrames
      if (moved) framesSeen = true
      lastFrames = renderedFrames
      anchorMs = positionMs
      if (moved && pictureMissing) {
        pictureMissing = false
        return Action.PictureBack
      }
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
      return restart(positionMs, Cause.PICTURE_STOPPED, durationMs = 0L)
    }
    pictureMissing = true
    return Action.NoPicture(positionMs, framesSeen)
  }

  /**
   * The player failed with [errorCode] (PlaybackException) at [positionMs] (0 or less when it reports none), in a
   * video of [durationMs] (0 or less, C.TIME_UNSET included, when not known).
   */
  fun onFailure(errorCode: Int, positionMs: Long, durationMs: Long = 0L): Action {
    if (restartPending) return Action.None
    val cause = causeOf(errorCode) ?: return Action.PassOn
    if (!framesSeen || !retryLeft) return Action.PassOn
    retryLeft = false
    return restart(if (positionMs > 0) positionMs else lastPositionMs, cause, durationMs)
  }

  private fun restart(positionMs: Long, cause: Cause, durationMs: Long): Action.Restart {
    restartPending = true
    val delayMs = if (cause == Cause.PICTURE_STOPPED) 0L else RESTART_DELAY_MS
    return Action.Restart(positionMs, cause, resumeAt(positionMs, cause, durationMs), delayMs)
  }

  companion object {
    /** Media time a playing video may go without a new frame before it counts as a picture missing. */
    const val NO_PICTURE_MS = 3_000L

    /** How often the viewer reads the player while a video plays. */
    const val TICK_MS = 500L

    /**
     * The wait before the new player of a decoder or media server failure: the codec service, or the audio server,
     * may still be coming back (1.2 s then 1.8 s in the exhibition builds).
     */
    const val RESTART_DELAY_MS = 1_500L

    /**
     * How far past a decoder failure the new player starts: the frames that broke the decoder are at or just after
     * the position the player reported (its decoder reads ahead of the picture).
     */
    const val SKIP_PAST_FAULT_MS = 3_000L

    /** How close to the end a restart may start: a start past the end ends the video (a kiosk shows its card). */
    const val END_MARGIN_MS = 1_000L

    /**
     * Where a new player starts after [cause] at [failureMs] in a video of [durationMs] (0 or less when not known).
     * A decoder failure starts [SKIP_PAST_FAULT_MS] past it, or at [nextSyncMs], the next sync frame of the file from
     * there when the viewer could read it, so that the new decoder starts on a whole picture past the frames that
     * broke the old one; at the latest [END_MARGIN_MS] before the end, and never before [failureMs]. The other causes
     * start where the video stopped.
     */
    fun resumeAt(failureMs: Long, cause: Cause, durationMs: Long, nextSyncMs: Long? = null): Long {
      if (cause != Cause.DECODER) return failureMs
      val target = failureMs + SKIP_PAST_FAULT_MS
      val wanted = nextSyncMs?.takeIf { it >= target } ?: target
      if (durationMs <= 0L) return wanted
      val latest = durationMs - END_MARGIN_MS
      return when {
        wanted <= latest -> wanted
        target <= latest -> target
        else -> maxOf(failureMs, latest)
      }
    }

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
