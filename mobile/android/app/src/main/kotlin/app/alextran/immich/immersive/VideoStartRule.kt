package app.alextran.immich.immersive

/**
 * How the immersive viewer starts the video Flutter chose (lot fix-decoder-limit, 30 October 2026). Flutter picks the
 * file decodability first (chooseVideoSource in Dart: the original or the server's copy, each checked against the
 * decoders of the headset) and sends the copy as the fallback only when the headset decodes it. The viewer then
 * decides how that file reaches the decoder, and what to do with a file beyond it, in that order:
 *
 * - [start]: a refusal Flutter sent is said at once; a server original that cannot stream (no Range, the MP4 index at
 *   the end, the rule of 30 September) goes to the copy when there is one to go to, else it is downloaded to the cache
 *   with a progress line, rather than streamed from the start to the end before its first frame.
 * - [overLimit]: at the first tracks, a video beyond the decoder switches to the copy once; a server video with nothing
 *   left stops at once with what to change in Immich; a file of the headset or of a share warns and plays, watched by
 *   the rule of PlaybackRecovery.onOverLimit (no frame for 3 s stops it).
 *
 * Pure, so that every rule is unit tested.
 */
internal object VideoStartRule {
  enum class Start {
    /** Play the url as it is. */
    URL,

    /** Play the server's copy instead: the original cannot stream and the copy decodes. */
    FALLBACK,

    /** Download the original to the cache with a progress line, then play the file. */
    DOWNLOAD,

    /** Say the refusal Flutter sent, play nothing. */
    REFUSE,
  }

  enum class OverLimit {
    /** Play the server's copy instead, once. */
    SWITCH,

    /** Stop at once and say what to change in Immich. */
    REFUSE,

    /** Warn and play, the decoder watched. */
    WARN,
  }

  /**
   * Whether the viewer reads the head of the url to learn whether it streams: only a server original ([original], a
   * [streamed] url that is not a file of a share, [fileMedia]) of a plain plan ([plain], not the lens player) that
   * Flutter did not refuse ([refused]).
   */
  fun probes(refused: Boolean, plain: Boolean, original: Boolean, streamed: Boolean, fileMedia: Boolean): Boolean =
    !refused && plain && original && streamed && !fileMedia

  /**
   * How a video starts: [refused], Flutter sent a refusal; [plain], [original], [streamed] and [fileMedia] as for
   * [probes]; [hasFallback], Flutter sent a copy the headset decodes; [streamable], what the probe of the head found
   * (true when it was not probed).
   */
  fun start(
    refused: Boolean,
    plain: Boolean,
    original: Boolean,
    streamed: Boolean,
    fileMedia: Boolean,
    hasFallback: Boolean,
    streamable: Boolean,
  ): Start =
    when {
      refused -> Start.REFUSE
      !probes(false, plain, original, streamed, fileMedia) || streamable -> Start.URL
      hasFallback -> Start.FALLBACK
      else -> Start.DOWNLOAD
    }

  /**
   * What a video beyond the decoder does at its first tracks: [fallbackLeft], a copy the headset decodes was not tried
   * yet; [fromServer], the media is a server video (not a file of the headset or of a share), whose server can make a
   * copy that plays.
   */
  fun overLimit(fallbackLeft: Boolean, fromServer: Boolean): OverLimit =
    when {
      fallbackLeft -> OverLimit.SWITCH
      fromServer -> OverLimit.REFUSE
      else -> OverLimit.WARN
    }

  /** The percent of a download of [doneBytes] of [totalBytes] (null when the size is unknown), 100 only at the end. */
  fun percent(doneBytes: Long, totalBytes: Long): Int? {
    if (totalBytes <= 0L) return null
    if (doneBytes >= totalBytes) return 100
    return (doneBytes * 100 / totalBytes).toInt().coerceIn(0, 99)
  }

  /** Room left in the cache beyond the file of a download: [MARGIN_BYTES] and a tenth of the file. */
  const val MARGIN_BYTES = 256L * 1024 * 1024

  /** Whether a download of [sizeBytes] (0 or less when the server tells none) fits in [freeBytes]. */
  fun fits(sizeBytes: Long, freeBytes: Long): Boolean =
    sizeBytes > 0L && freeBytes - sizeBytes >= MARGIN_BYTES + sizeBytes / 10
}
