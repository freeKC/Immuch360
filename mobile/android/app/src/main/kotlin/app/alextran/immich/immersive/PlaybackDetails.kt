package app.alextran.immich.immersive

import app.alextran.immich.core.PlaybackErrors
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.roundToLong

/**
 * What the immersive viewer says about the video it plays (lot quest-playback-resilience, 30 October 2026): the line
 * of the info panel with the codec, the size, the frame rate and the bit rate, as the details of the app show them;
 * the notices of a restart and of a picture missing (see [PlaybackRecovery]), translated by the app (the labels of
 * the opening, keys of immersive_playback_labels.dart) or else in English; and the report written to the Logs page of
 * the app, in English like the other reports there, with what a report from a headset we do not have needs: the
 * video, the decoder, the frames, the video surface and the headset. Pure, so that it is tested.
 */
internal object PlaybackDetails {
  /** Keys of the labels of the opening, the same as playback*LabelKey of immersive_playback_labels.dart. */
  const val LABEL_RESTARTED = "playbackRestarted"
  const val LABEL_RESTARTED_LATER = "playbackRestartedLater"
  const val LABEL_NO_PICTURE = "playbackNoPicture"
  const val LABEL_NO_PICTURE_SWITCH = "playbackNoPictureSwitch"
  const val LABEL_MBPS = "playbackMbps"
  const val LABEL_KBPS = "playbackKbps"

  /**
   * Keys of the texts of a video beyond the decoder (lot fix-decoder-limit): the refusal with the limit and what to
   * change in Immich, and the line of an original downloaded because it cannot stream.
   */
  const val LABEL_UNDECODABLE = "playbackUndecodable"
  const val LABEL_DOWNLOADING = "playbackDownloading"

  /** The English texts, for a key the app did not send. */
  private val englishLabels =
    mapOf(
      LABEL_RESTARTED to "The video stopped at {position}, it plays again from there",
      LABEL_RESTARTED_LATER to
        "The video stopped at {position}, it plays again from {resume}, past the part that failed",
      LABEL_NO_PICTURE to
        "No picture for 3 seconds while the sound plays ({video}). What the headset saw is in the Logs of the app",
      LABEL_NO_PICTURE_SWITCH to "No picture for 3 seconds from {video}, trying the server playback stream",
      LABEL_MBPS to "{value} Mbit/s",
      LABEL_KBPS to "{value} kbit/s",
      LABEL_UNDECODABLE to
        "This device cannot decode this video ({codec} {width} x {height}, above {maxWidth} x {maxHeight}): in " +
          "Immich, set the video transcoding to HEVC or lower the resolution",
      LABEL_DOWNLOADING to "Downloading the original to play it: {percent} %",
      // The texts of the errors of the players, see videoSourceLabels in the app
      PlaybackErrors.LABEL_DECODER to "This device cannot decode this video ({codec} {width} x {height})",
      PlaybackErrors.LABEL_NO_FRAME to
        "This video does not play: the decoder of this device gives no picture for it ({codec} {width} x {height})",
      PlaybackErrors.LABEL_STALLED to "This video is not loading: the network or the server sends it too slowly",
    )

  private const val SEPARATOR = " • "

  /**
   * "HEVC (hvc1.2.4.L153) • 7680 x 3840 • 29.97 fps • 120 Mbit/s": the [codec] name with its [codecs] string, the
   * [width] and [height], the [frameRate] and the bit rate ([bitsPerSecond], units from [labels], numbers in
   * [locale]), each left out when the player does not know it (0 or less).
   */
  fun line(
    codec: String,
    codecs: String?,
    width: Int,
    height: Int,
    frameRate: Float,
    bitsPerSecond: Int,
    labels: Map<String, String>,
    locale: Locale,
  ): String {
    val parts = ArrayList<String>()
    parts += if (codecs.isNullOrBlank() || codecs == codec) codec else "$codec (${codecs.trim()})"
    if (width > 0 && height > 0) parts += "$width x $height"
    if (frameRate > 0f) parts += "${frameRate(frameRate)} fps"
    if (bitsPerSecond > 0) parts += bitRate(bitsPerSecond, labels, locale)
    return parts.joinToString(SEPARATOR)
  }

  /** "30", "29.97": two decimals at most, none when they are zero (formatFrameRate of the app). */
  fun frameRate(frameRate: Float): String {
    val hundredths = (frameRate.toDouble() * 100).roundToLong()
    return if (hundredths % 100 == 0L) "${hundredths / 100}" else "${hundredths / 100.0}"
  }

  /** "120 Mbit/s", "4.5 Mbit/s", "850 kbit/s" (formatBitRate of the app): one decimal below 10 Mbit/s only. */
  fun bitRate(bitsPerSecond: Int, labels: Map<String, String>, locale: Locale): String {
    val format = NumberFormat.getNumberInstance(locale)
    if (bitsPerSecond < 1_000_000) {
      format.maximumFractionDigits = 0
      return text(labels, LABEL_KBPS, "value" to format.format((bitsPerSecond / 1000.0).roundToLong()))
    }
    val mbps = bitsPerSecond / 1_000_000.0
    format.maximumFractionDigits = if (mbps < 10) 1 else 0
    return text(labels, LABEL_MBPS, "value" to format.format(mbps))
  }

  /** The label [key] of [labels], else its English text, with each "{name}" of [values] filled in. */
  fun text(labels: Map<String, String>, key: String, vararg values: Pair<String, String>): String {
    var text = labels[key]?.takeIf { it.isNotBlank() } ?: englishLabels[key] ?: key
    for ((name, value) in values) text = text.replace("{$name}", value)
    return text
  }

  /**
   * The notice of a restart: the video stopped at [position] and plays again from [resume], past the part that failed
   * (a decoder failure, see PlaybackRecovery.resumeAt), or from there when both read the same.
   */
  fun restartNotice(labels: Map<String, String>, position: String, resume: String): String =
    if (resume == position) {
      text(labels, LABEL_RESTARTED, "position" to position)
    } else {
      text(labels, LABEL_RESTARTED_LATER, "position" to position, "resume" to resume)
    }

  /**
   * The video of [codec] [width] x [height] is beyond the decoder of the headset, at most [maxWidth] x [maxHeight] for
   * that codec, and the server has nothing better: what to change in Immich.
   */
  fun undecodableText(
    labels: Map<String, String>,
    codec: String,
    width: Int,
    height: Int,
    maxWidth: Int,
    maxHeight: Int,
  ): String =
    text(
      labels,
      LABEL_UNDECODABLE,
      "codec" to codec,
      "width" to "$width",
      "height" to "$height",
      "maxWidth" to "$maxWidth",
      "maxHeight" to "$maxHeight",
    )

  /** The line of the original being downloaded, [percent] of it there. */
  fun downloadingText(labels: Map<String, String>, percent: Int): String =
    text(labels, LABEL_DOWNLOADING, "percent" to "$percent")

  /**
   * An error of the player of [kind] (see PlaybackErrors) on a video of [codec] [width] x [height], in our words; null
   * when they need a size that is unknown, and for a video that stopped otherwise: the viewer then says its own
   * message, with the name of the error, never the text of Media3.
   */
  fun errorText(labels: Map<String, String>, kind: PlaybackErrors.Kind, codec: String, width: Int, height: Int): String? {
    val key = kind.label ?: return null
    if (kind == PlaybackErrors.Kind.STALLED) return text(labels, key)
    if (width <= 0 || height <= 0) return null
    return text(labels, key, "codec" to codec, "width" to "$width", "height" to "$height")
  }

  /**
   * A video refused before it played: of [codec] [width] x [height] beyond the decoder, at most [maxWidth] x
   * [maxHeight], or refused by the app ([codec] null), for the report.
   */
  fun refusedEvent(codec: String?, width: Int, height: Int, maxWidth: Int, maxHeight: Int): String =
    if (codec == null) {
      "not played: refused by the app before it loaded"
    } else {
      "not played: $codec $width x $height is beyond the decoder (at most $maxWidth x $maxHeight)"
    }

  /** Where [url] comes from, in words for a report; [isFallback] for the transcoded stream Flutter sent. */
  fun sourceOf(url: String, isFallback: Boolean): String =
    when {
      isFallback || url.contains("/video/playback") -> "the server transcoded stream"
      url.startsWith("http://127.0.0.1") || url.startsWith("http://localhost") ->
        "a network share, through the media bridge"
      url.contains("/original") -> "the server original"
      url.startsWith("http://") || url.startsWith("https://") -> "a network URL"
      else -> "a file on the headset"
    }

  /**
   * The video stopped at [position] after [error] (the name of the error and its cause), and a new player started it
   * again from [resume] after a wait of [delayMs].
   */
  fun restartEvent(error: String, position: String, resume: String, delayMs: Long): String {
    val wait =
      when {
        delayMs <= 0L -> "at once"
        delayMs % 1000 == 0L -> "after ${delayMs / 1000} s"
        else -> "after ${delayMs / 1000.0} s"
      }
    return "stopped at $position after ${withoutUrls(error)}, restarted at $resume on a new player $wait"
  }

  /** A restart at [position] after a picture that stopped while the sound played. */
  fun stoppedEvent(position: String): String =
    "restarted at $position, no new picture for ${PlaybackRecovery.NO_PICTURE_MS / 1000} s while the sound played"

  /** No picture at [position] while the sound plays; [framesBefore]: frames had shown before. */
  fun noPictureEvent(position: String, framesBefore: Boolean): String =
    "no picture at $position while the sound plays, " +
      if (framesBefore) "the picture stopped" else "none since the start"

  /** Frames that came again at [position] after a picture said missing. */
  fun pictureBackEvent(position: String): String = "the picture came back at $position"

  /** The error the viewer shows, with nothing left to try. */
  fun errorEvent(error: String): String = "cannot be played: ${withoutUrls(error)}"

  /**
   * One paragraph for the Logs page: the [event] for the video [title] (null: "a video") played from [source], the
   * [video] line (null without a video track), the [decoder] Media3 started (null: none), the frames
   * [renderedFrames] and [droppedFrames], whether the headset gave the video surface ([surfaceReady]), and the
   * [device].
   */
  fun report(
    event: String,
    title: String?,
    source: String,
    video: String?,
    decoder: String?,
    renderedFrames: Int,
    droppedFrames: Int,
    surfaceReady: Boolean,
    device: String,
  ): String =
    "Immersive viewer, ${title ?: "a video"} from $source: $event. " +
      "Video: ${video ?: "no video track selected"}. Decoder: ${decoder ?: "none started"}. " +
      "Frames rendered: $renderedFrames, dropped: $droppedFrames. " +
      "Video surface: ${if (surfaceReady) "ready" else "not given by the headset yet"}. Device: $device."

  /** [text] with each URL in it replaced: the URLs of the media bridge hold its token. */
  private fun withoutUrls(text: String): String = URL.replace(text, "(a URL)")

  private val URL = Regex("""[a-zA-Z][a-zA-Z0-9+.-]*://[^\s)]+""")
}
