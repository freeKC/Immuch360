package app.alextran.immich.core

import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecInfo.VideoCapabilities
import android.media.MediaCodecInfo.VideoCapabilities.PerformancePoint
import android.media.MediaCodecList
import android.os.Build
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.CodecSpecificDataUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import app.alextran.immich.immersive.ImmersiveMedia
import app.alextran.immich.immersive.isHorizonOsDevice
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.floor

/**
 * What the video decoders of the device take. Asked before a video plays (by Flutter through VideoDecoderApi, to
 * choose between the original and the server's transcoded stream) and once the tracks of a video are known (by the
 * native players, to switch to the transcoded stream). The answer comes from the system's decoder list, hardware
 * decoders first, corrected by what was measured on the Meta Quest 3: H.264 above 4096x2304 plays there at about
 * 17 fps with block artifacts, whatever the list says (see [ImmersiveMedia.MAX_AVC_LONG_SIDE]).
 *
 * The list does not change while the app runs, so each answer is cached per question. The players ask on the main
 * thread: by then Media3 has read the list on its playback thread, and the system keeps it for the whole process, so
 * the question costs little there.
 */
object VideoDecoders {
  private const val TAG = "VideoDecoders"

  const val MIME_AVC = "video/avc"
  const val MIME_HEVC = "video/hevc"
  const val MIME_AV1 = "video/av01"
  const val MIME_VP9 = "video/x-vnd.on2.vp9"
  const val MIME_VP8 = "video/x-vnd.on2.vp8"
  const val MIME_MP4V = "video/mp4v-es"
  const val MIME_DOLBY_VISION = "video/dolby-vision"

  /**
   * Key, in the labels Flutter sends the 360° and Spatial 2.5D players, of the message shown when the player switches
   * to the transcoded stream because the device cannot decode the original: the same key as on iOS. "{codec}",
   * "{width}" and "{height}", when the text has them, are filled in by the player, see [decoderLabel].
   */
  const val LABEL_SWITCHED = "sourceSwitched"

  /**
   * MIME type of each sample entry four character code, and of the codec names of ffprobe (what the Immich server
   * reports), so that Flutter can ask with whichever it knows. Dolby Vision gets its own type: a device without a Dolby
   * Vision decoder may still play its HEVC, H.264 or AV1 base layer, see [answer].
   */
  private val mimeByCodec =
    mapOf(
      "avc1" to MIME_AVC,
      "avc3" to MIME_AVC,
      "h264" to MIME_AVC,
      "hvc1" to MIME_HEVC,
      "hev1" to MIME_HEVC,
      "hevc" to MIME_HEVC,
      "h265" to MIME_HEVC,
      "av01" to MIME_AV1,
      "av1" to MIME_AV1,
      "vp09" to MIME_VP9,
      "vp9" to MIME_VP9,
      "vp08" to MIME_VP8,
      "vp8" to MIME_VP8,
      "mp4v" to MIME_MP4V,
      "mpeg4" to MIME_MP4V,
      "dvh1" to MIME_DOLBY_VISION,
      "dvhe" to MIME_DOLBY_VISION,
      "dva1" to MIME_DOLBY_VISION,
      "dvav" to MIME_DOLBY_VISION,
      "dav1" to MIME_DOLBY_VISION,
    )

  /**
   * Codecs whose profile is checked against the profiles a decoder lists: there the profile is mostly the bit depth
   * (HEVC Main 10, AV1 10 bit, VP9 profile 2), which a decoder either has or not. H.264 is left out: decoders list
   * their profiles unevenly (constrained baseline without baseline, for one) and every one of them takes the 8 bit
   * profiles that cameras and phones write.
   */
  private val profileCheckedMimes = setOf(MIME_HEVC, MIME_AV1, MIME_VP9)

  /** The answer for a video: see the VideoDecoderApi pigeon, whose DecodeVerdict carries the same fields. */
  data class Verdict(
    val supported: Boolean,
    val hardware: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val reason: String,
  )

  /** One video decoder of the device for one MIME type it decodes, with its largest frame and its rate there. */
  data class Decoder(
    val name: String,
    val mime: String,
    val hardware: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxFrameRate: Double,
  )

  private data class Question(
    val mime: String,
    val codecs: String?,
    val width: Int,
    val height: Int,
    val frameRate: Double,
  )

  private val answers = ConcurrentHashMap<Question, Verdict>()

  /**
   * The video decoders of the device: hardware ones first, otherwise in the order of the system, which is its order of
   * preference. Encoders, aliases (the same decoder under another name, Android 10 and later) and the secure variants
   * (only for DRM protected content, which the app never plays) are left out. Empty when the system cannot list them.
   */
  private val videoDecoders: List<MediaCodecInfo> by lazy {
    try {
      MediaCodecList(MediaCodecList.REGULAR_CODECS)
        .codecInfos
        .filter { info ->
          !info.isEncoder &&
            !isAlias(info) &&
            !info.name.endsWith(".secure", ignoreCase = true) &&
            info.supportedTypes.any { it.startsWith("video/", ignoreCase = true) }
        }
        .sortedBy { if (isHardware(it)) 0 else 1 }
    } catch (e: Exception) {
      Log.e(TAG, "cannot list the decoders of the device", e)
      emptyList()
    }
  }

  /**
   * Some devices list performance points that do not even cover 720p at 60 fps for H.264, which every hardware decoder
   * reaches: their list is incomplete and would wrongly refuse ordinary videos. Media3 makes the same check before
   * trusting them. Read once, from the first H.264 decoder that lists points.
   */
  private val performancePointsTrusted: Boolean by lazy {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@lazy false
    val points =
      decodersFor(MIME_AVC)
        .firstNotNullOfOrNull { info ->
          capabilitiesOf(info, MIME_AVC)?.videoCapabilities?.supportedPerformancePoints?.takeIf { it.isNotEmpty() }
        }
        ?: return@lazy false
    val trusted = points.any { it.covers(PerformancePoint(1280, 720, 60)) }
    if (!trusted) Log.i(TAG, "performance points ignored: the H.264 decoder does not list 720p at 60 fps")
    trusted
  }

  /**
   * MIME type of [codec]: a MIME type as it is ("video/hevc"), or a four character code or a codec name, alone or
   * leading an RFC 6381 string ("hvc1.2.4.L153.B0" gives "video/hevc"). Null for a blank or unknown one.
   */
  fun mimeFor(codec: String): String? {
    val value = codec.trim().lowercase()
    if (value.isEmpty()) return null
    if (value.contains('/')) return value
    return mimeByCodec[value.substringBefore('.')]
  }

  /** Name of the codec of [mime] for the user: "H.264", "HEVC", "AV1", "VP9", or the MIME type itself. */
  fun codecName(mime: String?): String =
    when (mime?.lowercase()) {
      MIME_AVC -> "H.264"
      MIME_HEVC -> "HEVC"
      MIME_AV1 -> "AV1"
      MIME_VP9 -> "VP9"
      MIME_VP8 -> "VP8"
      MIME_DOLBY_VISION -> "Dolby Vision"
      null -> "?"
      else -> mime
    }

  /**
   * True when [width] x [height] of [mime] is above what was measured on a Meta Quest ([horizonOs]), whatever its
   * decoder list says: H.264 above 4096x2304, see [ImmersiveMedia.exceedsAvcDecoder]. Other devices and codecs follow
   * their list.
   */
  fun exceedsMeasuredLimit(mime: String?, width: Int, height: Int, horizonOs: Boolean): Boolean =
    horizonOs && ImmersiveMedia.exceedsAvcDecoder(mime, width, height)

  /**
   * The largest frame to report for a decoder of [mime] whose list says [width] x [height]: on a Meta Quest
   * ([horizonOs]), H.264 stops at the measured 4096x2304, so that the decoders page agrees with the verdicts.
   */
  fun reportedMaxSize(mime: String, width: Int, height: Int, horizonOs: Boolean): Pair<Int, Int> =
    if (horizonOs && mime.equals(MIME_AVC, ignoreCase = true)) {
      minOf(width, ImmersiveMedia.MAX_AVC_LONG_SIDE) to minOf(height, ImmersiveMedia.MAX_AVC_SHORT_SIDE)
    } else {
      width to height
    }

  /**
   * Whether the decoder [name] runs in software, for Android 9 and earlier, which do not tell: the decoders of
   * Android itself (OMX.google, c2.android, c2.google), FFmpeg ones, Samsung's ".sw." ones, and any name outside the
   * OMX and Codec2 conventions. The same rule Media3 uses.
   */
  fun isSoftwareName(name: String): Boolean {
    val lower = name.lowercase()
    if (lower.startsWith("arc.")) return false
    return lower.startsWith("omx.google.") ||
      lower.startsWith("omx.ffmpeg.") ||
      (lower.startsWith("omx.sec.") && lower.contains(".sw.")) ||
      lower == "omx.qcom.video.decoder.hevcswvdec" ||
      lower.startsWith("c2.android.") ||
      lower.startsWith("c2.google.") ||
      (!lower.startsWith("omx.") && !lower.startsWith("c2."))
  }

  /**
   * The size a decoder is asked about: [size] rounded up to a multiple of its [alignment] (1, or less, for none). The
   * system refuses a size off the alignment, an odd height for a decoder that works by pairs of lines, though the
   * decoder pads the frame and plays it: Media3 checks the padded size for that reason (ExoPlayer issue 6551), and so
   * does [sizeFits].
   */
  fun alignedSize(size: Int, alignment: Int): Int =
    if (alignment <= 1) size else (size + alignment - 1) / alignment * alignment

  /**
   * The frame rate a decoder is asked about for a video of [frameRate] frames per second, null to ask about the size
   * alone, as Media3 does. The rate is rounded down: the mean rate of a file is often a little above its nominal one
   * (30.02 for a 30 fps video) and would fail a range that ends at the nominal rate. Below 1 fps, or unknown, only the
   * size is asked: some Android versions refuse any rate below 1.
   */
  fun checkedFrameRate(frameRate: Double): Double? = if (frameRate >= 1) floor(frameRate) else null

  /**
   * The translated message of [key] from [labels], with "{codec}", "{width}" and "{height}" filled in, or null when
   * Flutter did not send it: the players then only log.
   */
  fun decoderLabel(labels: Map<String, String>, key: String, codec: String, width: Int, height: Int): String? =
    labels[key]
      ?.takeIf { it.isNotBlank() }
      ?.replace("{codec}", codec)
      ?.replace("{width}", width.toString())
      ?.replace("{height}", height.toString())

  /**
   * Whether the device decodes a video of [codec] (MIME type, four character code or codec name, see [mimeFor]) with
   * the RFC 6381 [codecs] when known, of [width] x [height] (0 or less when unknown: the codec alone is checked) at
   * [frameRate] frames per second (0 or less when unknown). An unknown codec is not checked and counts as supported:
   * the player still falls back on the transcoded stream if the original fails.
   */
  fun canDecode(codec: String, codecs: String?, width: Int, height: Int, frameRate: Double): Verdict {
    val mime = mimeFor(codec) ?: codecs?.let(::mimeFor)
    if (mime == null) {
      return Verdict(supported = true, hardware = false, maxWidth = 0, maxHeight = 0, reason = "unknown codec '$codec'")
    }
    val question =
      Question(
        mime = mime,
        codecs = codecs?.trim()?.takeIf { it.isNotEmpty() },
        width = width.coerceAtLeast(0),
        height = height.coerceAtLeast(0),
        frameRate = if (frameRate > 0) frameRate else 0.0,
      )
    answers[question]?.let { return it }
    val verdict =
      try {
        answer(question)
      } catch (e: Exception) {
        // A broken decoder list must not stop the original from playing: the players fall back if it fails
        Log.e(TAG, "cannot check $question", e)
        Verdict(supported = true, hardware = false, maxWidth = 0, maxHeight = 0, reason = "check failed: $e")
      }
    Log.i(TAG, "${codecName(mime)} ${question.width}x${question.height} at ${question.frameRate} fps: $verdict")
    answers[question] = verdict
    return verdict
  }

  /** [canDecode] for the video track [format] the player selected. */
  fun canDecode(format: Format): Verdict =
    canDecode(
      format.sampleMimeType ?: format.codecs.orEmpty(),
      format.codecs,
      format.width,
      format.height,
      format.frameRate.toDouble(),
    )

  /**
   * Every video decoder of the device, once per MIME type it decodes, with its largest frame (the widest it takes,
   * then the tallest at that width) and the frame rate the system gives at that size (0 when it does not tell).
   * Sorted by MIME type, hardware first.
   */
  fun listDecoders(): List<Decoder> {
    val horizonOs = isHorizonOsDevice()
    val decoders = mutableListOf<Decoder>()
    for (info in videoDecoders) {
      val hardware = isHardware(info)
      for (type in info.supportedTypes) {
        if (!type.startsWith("video/", ignoreCase = true)) continue
        val video = capabilitiesOf(info, type)?.videoCapabilities ?: continue
        val (width, height) = largestSize(video, type, horizonOs)
        val rate = runCatching { video.getSupportedFrameRatesFor(width, height).upper }.getOrDefault(0.0)
        decoders += Decoder(info.name, type.lowercase(), hardware, width, height, rate)
      }
    }
    return decoders.sortedWith(compareBy({ it.mime }, { if (it.hardware) 0 else 1 }))
  }

  private fun answer(question: Question): Verdict {
    val mime = question.mime
    val candidates = decodersFor(mime)
    val horizonOs = isHorizonOsDevice()
    val sized = question.width > 0 && question.height > 0
    val size = "${question.width}x${question.height}"
    if (sized && exceedsMeasuredLimit(mime, question.width, question.height, horizonOs)) {
      return Verdict(
        supported = false,
        hardware = false,
        maxWidth = ImmersiveMedia.MAX_AVC_LONG_SIDE,
        maxHeight = ImmersiveMedia.MAX_AVC_SHORT_SIDE,
        reason = "H.264 $size is above the 4096x2304 measured on the Meta Quest 3",
      )
    }
    val profile = profileOf(mime, question.codecs)
    val refusals = mutableListOf<String>()
    for (info in candidates) {
      val capabilities = capabilitiesOf(info, mime) ?: continue
      val video = capabilities.videoCapabilities ?: continue
      val refusal = refusalOf(capabilities, video, question, profile)
      if (refusal != null) {
        refusals += "${info.name} $refusal"
        continue
      }
      val hardware = isHardware(info)
      val (maxWidth, maxHeight) = largestSize(video, mime, horizonOs)
      return Verdict(
        supported = true,
        hardware = hardware,
        maxWidth = maxWidth,
        maxHeight = maxHeight,
        reason = "${info.name} (${if (hardware) "hardware" else "software"})",
      )
    }
    alternativeFor(question)?.let { alternative ->
      val verdict = answer(alternative)
      return verdict.copy(reason = "base layer ${alternative.mime}: ${verdict.reason}")
    }
    if (candidates.isEmpty()) {
      return Verdict(supported = false, hardware = false, maxWidth = 0, maxHeight = 0, reason = "no decoder for $mime")
    }
    val best = candidates.first()
    val (maxWidth, maxHeight) =
      capabilitiesOf(best, mime)?.videoCapabilities?.let { largestSize(it, mime, horizonOs) } ?: (0 to 0)
    return Verdict(
      supported = false,
      hardware = false,
      maxWidth = maxWidth,
      maxHeight = maxHeight,
      reason = refusals.joinToString("; ").ifEmpty { "no decoder for $mime" },
    )
  }

  /** Why [video] cannot take [question], or null when it can. */
  private fun refusalOf(
    capabilities: CodecCapabilities,
    video: VideoCapabilities,
    question: Question,
    profile: Int?,
  ): String? {
    val levels = capabilities.profileLevels
    if (profile != null && levels.isNotEmpty() && levels.none { it.profile == profile }) {
      return "lacks profile $profile"
    }
    if (question.width <= 0 || question.height <= 0) return null
    val width = question.width
    val height = question.height
    val rate = question.frameRate
    val fits = sizeFits(video, width, height, rate) || (width < height && sizeFits(video, height, width, rate))
    if (!fits) {
      return "does not take ${width}x$height" + if (rate > 0) " at $rate fps" else ""
    }
    if (rate > 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !performanceCovers(video, width, height, rate)) {
      return "has no performance point for ${width}x$height at $rate fps"
    }
    return null
  }

  /**
   * Whether the size (and the rate, when known) is within the ranges of [video], asked the way Media3 asks before it
   * plays a track (see [alignedSize] and [checkedFrameRate]): otherwise a video Media3 plays could be refused here and
   * switched to the transcoded stream for nothing. The ranges come from the codec level, the most the decoder accepts,
   * not what it sustains: the performance points tell that, see [performanceCovers].
   */
  private fun sizeFits(video: VideoCapabilities, width: Int, height: Int, rate: Double): Boolean {
    val alignedWidth = alignedSize(width, video.widthAlignment)
    val alignedHeight = alignedSize(height, video.heightAlignment)
    val checkedRate = checkedFrameRate(rate) ?: return video.isSizeSupported(alignedWidth, alignedHeight)
    return video.areSizeAndRateSupported(alignedWidth, alignedHeight, checkedRate)
  }

  /**
   * Whether the performance points of [video], the rates the vendor measured, cover the video. A decoder without
   * points, or a device whose points are not trusted (see [performancePointsTrusted]), says yes: the ranges decide.
   */
  @RequiresApi(Build.VERSION_CODES.Q)
  private fun performanceCovers(video: VideoCapabilities, width: Int, height: Int, rate: Double): Boolean {
    val points = video.supportedPerformancePoints
    if (points.isNullOrEmpty()) return true
    val wanted = PerformancePoint(width, height, rate.toInt().coerceAtLeast(1))
    if (points.any { it.covers(wanted) }) return true
    return !performancePointsTrusted
  }

  /**
   * The widest frame [video] takes and the tallest at that width, reported as [reportedMaxSize] says. The two upper
   * bounds alone could be no size the decoder takes (8192 wide and 8192 tall, above its pixel count).
   */
  private fun largestSize(video: VideoCapabilities, mime: String, horizonOs: Boolean): Pair<Int, Int> {
    val width = video.supportedWidths.upper
    val height = runCatching { video.getSupportedHeightsFor(width).upper }.getOrDefault(video.supportedHeights.upper)
    return reportedMaxSize(mime, width, height, horizonOs)
  }

  /** The decoders of [mime], hardware first. */
  private fun decodersFor(mime: String): List<MediaCodecInfo> =
    videoDecoders.filter { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }

  /** The capabilities of [info] for [mime], null when the decoder fails to give them. */
  private fun capabilitiesOf(info: MediaCodecInfo, mime: String): CodecCapabilities? {
    val type = info.supportedTypes.firstOrNull { it.equals(mime, ignoreCase = true) } ?: return null
    return try {
      info.getCapabilitiesForType(type)
    } catch (e: Exception) {
      Log.w(TAG, "no capabilities from ${info.name} for $type", e)
      null
    }
  }

  private fun isHardware(info: MediaCodecInfo): Boolean =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isHardwareAccelerated else !isSoftwareName(info.name)

  private fun isAlias(info: MediaCodecInfo): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isAlias

  /** The profile the RFC 6381 [codecs] name, as MediaCodecInfo.CodecProfileLevel counts them, for checked codecs. */
  @OptIn(UnstableApi::class)
  private fun profileOf(mime: String, codecs: String?): Int? {
    if (codecs == null || mime !in profileCheckedMimes) return null
    val videoCodecs = Util.getCodecsOfType(codecs, C.TRACK_TYPE_VIDEO) ?: return null
    val format = Format.Builder().setSampleMimeType(mime).setCodecs(videoCodecs).build()
    return runCatching { CodecSpecificDataUtil.getCodecProfileAndLevel(format)?.first }.getOrNull()
  }

  /**
   * For Dolby Vision, the question about its base layer (HEVC for profile 8, H.264 for 9, AV1 for 10), which Media3
   * plays on a device without a Dolby Vision decoder: an iPhone HDR video plays as HEVC there. Null otherwise.
   */
  @OptIn(UnstableApi::class)
  private fun alternativeFor(question: Question): Question? {
    if (question.mime != MIME_DOLBY_VISION) return null
    val codecs = question.codecs?.let { Util.getCodecsOfType(it, C.TRACK_TYPE_VIDEO) } ?: return null
    val format = Format.Builder().setSampleMimeType(MIME_DOLBY_VISION).setCodecs(codecs).build()
    val mime = runCatching { MediaCodecUtil.getAlternativeCodecMimeType(format) }.getOrNull() ?: return null
    return question.copy(mime = mime, codecs = null)
  }
}
