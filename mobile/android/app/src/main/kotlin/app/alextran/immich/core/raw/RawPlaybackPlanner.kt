package app.alextran.immich.core.raw

/** How a raw 360° video plays. */
enum class RawMode {
  /** Not a raw video: the player as for any 360° video. */
  PLAIN,

  /** Both lenses side by side in one track: the Media3 effect stitches them. */
  EFFECT_SIDE_BY_SIDE,

  /** Lenses in two streams (or one of them): the lens player and its compositor. */
  LENSES,

  /** The frame as the camera recorded it, the stitching having failed or being impossible. */
  UNSTITCHED,
}

/** What the user is told about a fallback. */
enum class RawMessage { ONE_LENS_DECODER, ONE_LENS_FILE, UNSTITCHED }

/**
 * How a raw video plays now: [mode], the decoded [streams] (indices of the JSON's tracks) in LENSES mode, the [urls]
 * the player opens (two for both files of a split pair, url first), whether they are the server's transcoded streams
 * ([fromFallback]), the [message] to show, and the [reason] for the logs. [firstFrameMessage] is shown once the first
 * frame of the plan is drawn rather than at once: a lens tried against the decoder list may fail before, and the next
 * step then tells its own message. Two plans with the same [key] can play with the same player: a lens player is
 * built for its streams and its files, any other player only for its mode (the side by side effect also for its
 * projection, which the caller adds).
 */
data class RawPlan(
  val mode: RawMode,
  val streams: List<Int>,
  val urls: List<String>,
  val fromFallback: Boolean,
  val message: RawMessage?,
  val reason: String,
  val firstFrameMessage: RawMessage? = null,
) {
  val key: String
    get() = if (mode == RawMode.LENSES) "$mode $streams ${urls.joinToString(" ")}" else mode.name
}

/** What the decoders of the device say about some streams of a track, see [RawDecoderCheck]. */
sealed interface RawDecoderVerdict {
  /** A decoder takes them. */
  data object Decodable : RawDecoderVerdict

  /**
   * No decoder takes them, for [reason]. A [certain] refusal (no decoder lists the profile of the track, or the device
   * has no decoder at all for its codec) fails even for one stream. Otherwise the size or the rate was refused, where
   * the decoder list may be pessimistic.
   */
  data class Refused(val reason: String, val certain: Boolean) : RawDecoderVerdict

  /** It cannot be told: the JSON lacks the size or the codec. */
  data object Unknown : RawDecoderVerdict

  companion object {
    /**
     * The verdict of the decoder list (the fields of VideoDecoders.Verdict): [supported], its [reason], and the
     * [missingProfile] no decoder lists. A refusal whose reason starts with "no decoder for", as VideoDecoders words a
     * codec the device has no decoder for, is as certain as a missing profile.
     */
    fun of(supported: Boolean, reason: String, missingProfile: String?): RawDecoderVerdict =
      if (supported) {
        Decodable
      } else {
        Refused(reason, certain = missingProfile != null || reason.startsWith("no decoder for"))
      }
  }
}

/** Whether the device decodes [instances] streams like [track] at once. */
typealias RawDecoderCheck = (track: RawTrack, instances: Int) -> RawDecoderVerdict

/**
 * The fallback ladder of raw 360° videos, pure so that every step is unit tested: two lenses stitched, then one lens
 * stitched (half the sphere black, a message), then the server's transcoded streams, then the frame unstitched. A
 * lens the decoders cannot take at all (a profile none of them lists) skips the lens steps. A plan change always means
 * a new player from the current position (the activities post it, never build it inside a player listener).
 */
object RawPlaybackPlanner {
  /**
   * The plan a video starts with. [jsonPresent] says whether Flutter sent a rawProjection, [projection] is that JSON
   * parsed (null when it was refused or the destination cannot take a stitched frame), [url] and [fallbackUrl] the
   * original and the server's transcoded stream, [stitchFailed] whether the stitching of this video failed before
   * (kept across a recreation), [canDecode] the decoder check.
   */
  fun initial(
    jsonPresent: Boolean,
    projection: RawProjection?,
    url: String,
    fallbackUrl: String?,
    stitchFailed: Boolean,
    canDecode: RawDecoderCheck,
  ): RawPlan {
    if (!jsonPresent) return RawPlan(RawMode.PLAIN, emptyList(), listOf(url), false, null, "not a raw video")
    if (projection == null) {
      return RawPlan(RawMode.UNSTITCHED, emptyList(), listOf(url), false, RawMessage.UNSTITCHED, "projection refused")
    }
    if (stitchFailed) {
      return RawPlan(RawMode.UNSTITCHED, emptyList(), listOf(url), false, null, "the stitching failed before")
    }
    if (!projection.isLensLayout) {
      return RawPlan(RawMode.EFFECT_SIDE_BY_SIDE, listOf(0), listOf(url), false, null, "side by side")
    }
    val largest = projection.tracks.maxByOrNull { it.pixels } ?: projection.tracks.first()
    val both = check(largest, 2, canDecode)
    if (both !is RawDecoderVerdict.Refused) {
      return lenses(
        projection,
        listOf(0, 1),
        url,
        null,
        if (both == RawDecoderVerdict.Unknown) {
          "two streams, decoders not checked (size or codec unknown)"
        } else {
          "two streams decodable"
        },
      )
    }
    val primary = projection.primaryStream()
    val one = check(projection.tracks[primary], 1, canDecode)
    if (one !is RawDecoderVerdict.Refused) {
      val checked = if (one == RawDecoderVerdict.Unknown) "not checked" else "decodable"
      return lenses(projection, listOf(primary), url, RawMessage.ONE_LENS_DECODER, "two streams refused, one $checked")
    }
    if (one.certain) {
      // A lens player would fail on the first frame, and the one lens message would promise half a sphere the device
      // cannot show. Without the transcoded streams, the plain player plays the original: its own decoder check and
      // its fallback apply, as for any other video, and the user reads its message rather than a raw one
      val cause = "one stream refused for sure (${one.reason})"
      return transcoded(projection, url, fallbackUrl, cause)
        ?: RawPlan(RawMode.UNSTITCHED, emptyList(), listOf(url), false, null, "$cause, no transcoded streams")
    }
    // Refused for its size or its rate only: the decoder list may be pessimistic, so the lens is tried. The one lens
    // message waits for its first frame, the proof that the device decodes one lens; if the lens fails before, the
    // unstitched step tells the user instead
    return transcoded(projection, url, fallbackUrl, "originals not decodable")
      ?: lenses(
        projection,
        listOf(primary),
        url,
        null,
        "one stream refused and no fallback: trying it anyway (the decoder list may be pessimistic)",
      ).copy(firstFrameMessage = RawMessage.ONE_LENS_DECODER)
  }

  /**
   * After a decoder failure (init failed, format refused, resources reclaimed in front, no decodable track): two
   * lenses become one, one lens becomes the transcoded streams, or without them the original unstitched (the last
   * step: a plain player, whose own decoder check and fallbacks then apply). Null on the transcoded streams already
   * and in any other mode: the error shows.
   */
  fun afterDecoderFailure(plan: RawPlan, projection: RawProjection, url: String, fallbackUrl: String?): RawPlan? {
    if (plan.mode != RawMode.LENSES || plan.fromFallback) return null
    if (plan.streams.size >= 2) {
      return lenses(
        projection,
        listOf(projection.primaryStream()),
        url,
        RawMessage.ONE_LENS_DECODER,
        "two decoders failed, one lens",
      )
    }
    return transcoded(projection, url, fallbackUrl, "originals not decodable")
      ?: RawPlan(
        RawMode.UNSTITCHED,
        emptyList(),
        listOf(url),
        false,
        RawMessage.UNSTITCHED,
        "the decoder of one lens failed, no transcoded streams: unstitched",
      )
  }

  /**
   * After a read error of the two files of a split pair: the file that was opened (url) plays its lens alone; the
   * other file is the likely culprit. Null otherwise: [afterSourceFailure] decides.
   */
  fun afterSourceError(plan: RawPlan, projection: RawProjection, url: String): RawPlan? {
    if (plan.mode != RawMode.LENSES || plan.fromFallback || plan.streams.size < 2) return null
    if (projection.layout != RawLayout.TWO_FILES) return null
    val stream = projection.tracks.indexOfFirst { it.file == 0 }.takeIf { it >= 0 } ?: return null
    return RawPlan(
      RawMode.LENSES,
      listOf(stream),
      listOf(url),
      false,
      RawMessage.ONE_LENS_FILE,
      "the other file failed",
    )
  }

  /**
   * After any other failure of the media of a lens plan on the originals (a read error [afterSourceError] has no step
   * for, a container the extractor refuses, a timeout): the server's transcoded streams, as other videos get them once
   * (see [transcoded]). Null on the transcoded streams already, or without them: the error shows.
   */
  fun afterSourceFailure(plan: RawPlan, projection: RawProjection, url: String, fallbackUrl: String?): RawPlan? {
    if (plan.mode != RawMode.LENSES || plan.fromFallback) return null
    return transcoded(projection, url, fallbackUrl, "originals failed")
  }

  /** After a stitching failure (GL): the first url unstitched, once. */
  fun afterStitchFailure(plan: RawPlan): RawPlan? {
    if (plan.mode != RawMode.LENSES && plan.mode != RawMode.EFFECT_SIDE_BY_SIDE) return null
    return RawPlan(
      RawMode.UNSTITCHED,
      emptyList(),
      listOf(plan.urls.first()),
      plan.fromFallback,
      RawMessage.UNSTITCHED,
      "the stitching failed",
    )
  }

  /**
   * How the lens renderers of [plan] find their tracks: by track_ID in one file with both lens tracks, by source
   * (and track_ID for originals) across two merged files, any video track in a single lens file.
   */
  fun assignmentOf(plan: RawPlan, projection: RawProjection): LensAssignment =
    when {
      plan.urls.size >= 2 ->
        LensAssignment.bySource(
          plan.streams.associateWith { projection.tracks[it].file },
          if (plan.fromFallback) emptyMap() else plan.streams.associateWith { projection.tracks[it].trackId },
        )
      projection.layout == RawLayout.TWO_TRACKS && !plan.fromFallback ->
        LensAssignment.byTrackIds(plan.streams.associateWith { projection.tracks[it].trackId ?: 0 })
      else -> LensAssignment.anyVideo(plan.streams)
    }

  /** The decoder check, skipped (unknown) when the track lacks its size or codec. */
  private fun check(track: RawTrack, instances: Int, canDecode: RawDecoderCheck): RawDecoderVerdict {
    if (track.width <= 0 || track.height <= 0 || (track.codecs ?: track.codec).isNullOrBlank()) {
      return RawDecoderVerdict.Unknown
    }
    return canDecode(track, instances)
  }

  /** The lens plan of [streams] on the originals: one file, both files of a pair, or the file of the one stream. */
  private fun lenses(
    projection: RawProjection,
    streams: List<Int>,
    url: String,
    message: RawMessage?,
    reason: String,
  ): RawPlan {
    val second = projection.secondUrl
    val urls =
      when {
        projection.layout != RawLayout.TWO_FILES -> listOf(url)
        streams.size >= 2 -> listOf(url, second ?: url)
        projection.fileOfStream(streams.first()) == 1 && second != null -> listOf(second)
        else -> listOf(url)
      }
    return RawPlan(RawMode.LENSES, streams, urls, false, message, reason)
  }

  /**
   * When the originals cannot play (even one stream cannot be decoded, or the media failed): the transcoded streams of
   * both files of a pair (stitched like the originals), else the transcoded stream of a two track file unstitched (the
   * server transcodes one track), else null. [cause] starts the reason.
   */
  private fun transcoded(projection: RawProjection, url: String, fallbackUrl: String?, cause: String): RawPlan? {
    val secondFallback = projection.secondFallbackUrl
    if (projection.layout == RawLayout.TWO_FILES && fallbackUrl != null && secondFallback != null) {
      return RawPlan(
        RawMode.LENSES,
        listOf(0, 1),
        listOf(fallbackUrl, secondFallback),
        true,
        null,
        "$cause, the transcoded streams of both files",
      )
    }
    if (projection.layout == RawLayout.TWO_TRACKS && fallbackUrl != null && fallbackUrl != url) {
      return RawPlan(
        RawMode.UNSTITCHED,
        emptyList(),
        listOf(fallbackUrl),
        true,
        RawMessage.UNSTITCHED,
        "$cause, the transcoded stream holds one lens",
      )
    }
    return null
  }
}
