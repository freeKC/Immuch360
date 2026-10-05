package app.alextran.immich.core

import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10
import android.media.MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10
import android.media.MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10Plus
import android.media.MediaCodecInfo.CodecProfileLevel.AV1ProfileMain8
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedBaseline
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedHigh
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileExtended
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileHigh
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileHigh422
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileHigh444
import android.media.MediaCodecInfo.CodecProfileLevel.AVCProfileMain
import android.media.MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
import android.media.MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10
import android.media.MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10
import android.media.MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus
import android.media.MediaCodecInfo.CodecProfileLevel.HEVCProfileMainStill
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile0
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile1
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile2
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile2HDR
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile2HDR10Plus
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile3
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile3HDR
import android.media.MediaCodecInfo.CodecProfileLevel.VP9Profile3HDR10Plus
import android.media.MediaCodecInfo.VideoCapabilities
import android.media.MediaCodecInfo.VideoCapabilities.PerformancePoint
import android.media.MediaCodecList
import android.os.Build
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.RequiresApi
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.util.CodecSpecificDataUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import app.alextran.immich.immersive.ImmersiveMedia
import app.alextran.immich.immersive.isHorizonOsDevice
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.floor
import kotlin.math.max

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
 *
 * A question may be about several streams of the same size decoded at once (the two lenses of a raw 360° video, each
 * in a decoder of its own): the decoder must then allow that many instances, and its level and performance points
 * must take the summed rate.
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
   * (HEVC Main 10, AV1 10 bit, VP9 profile 2) or the HDR transfer (Main 10 HDR10), which a decoder either has or not.
   * H.264 is only checked for its 10 bit, 4:2:2 and 4:4:4 profiles (see [requiredProfile]): decoders list their 8 bit
   * profiles unevenly (constrained baseline without baseline, for one) and every one of them takes the 8 bit profiles
   * that cameras and phones write, while hardly any takes High 10.
   */
  private val profileCheckedMimes = setOf(MIME_HEVC, MIME_AV1, MIME_VP9, MIME_AVC)

  /** Frame rate a question about several streams counts with when the video does not tell its own. */
  private const val DEFAULT_INSTANCES_FRAME_RATE = 30.0

  /** Pixels per stream above which several streams at once are refused to a software decoder: 2048x2048. */
  const val SOFTWARE_INSTANCES_MAX_PIXELS = 2048L * 2048L

  /**
   * Pixels per second the H.264 decoder of the Meta Quest 3 was measured to sustain: 4096x2304 at 30 fps. Two streams
   * decoded at once share it, see [exceedsMeasuredLimit].
   */
  private val maxAvcPixelRate =
    ImmersiveMedia.MAX_AVC_LONG_SIDE.toDouble() * ImmersiveMedia.MAX_AVC_SHORT_SIDE * DEFAULT_INSTANCES_FRAME_RATE

  /**
   * The answer for a video: see the VideoDecoderApi pigeon, whose DecodeVerdict carries the same fields. [profile] is
   * the profile the decoders were checked for, named as on the decoders page; [missingProfile] the same name when no
   * decoder of the device lists it, so that the user learns the refusal comes from it.
   */
  data class Verdict(
    val supported: Boolean,
    val hardware: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val reason: String,
    val profile: String? = null,
    val missingProfile: String? = null,
  )

  /**
   * One video decoder of the device for one MIME type it decodes, with its largest frame and its rate there, and the
   * profiles it lists with their highest level (see [profilesSummary]).
   */
  data class Decoder(
    val name: String,
    val mime: String,
    val hardware: Boolean,
    val maxWidth: Int,
    val maxHeight: Int,
    val maxFrameRate: Double,
    val profiles: List<String> = emptyList(),
  )

  private data class Question(
    val mime: String,
    val codecs: String?,
    val width: Int,
    val height: Int,
    val frameRate: Double,
    // Bits per luma sample, 0 when unknown
    val bitDepth: Int,
    // Media3 C.COLOR_TRANSFER_* value, Format.NO_VALUE when unknown
    val colorTransfer: Int,
    // Streams of this size decoded at once, each by a decoder instance of its own
    val instances: Int,
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
   * Whether [instances] streams of [width]x[height] at once are too much for a software decoder ([hardware] false):
   * the lens renderers of a raw 360° video take a software decoder only when the device has no hardware one (an
   * emulator, a TV box), and a software HEVC decoder at 3840x3840 would give a few frames per second and starve the
   * frame pairing without any error. Up to [SOFTWARE_INSTANCES_MAX_PIXELS] per stream it keeps up (the proxies and
   * the small test files). One stream is never refused here: the plain player plays it as any other video.
   */
  fun softwareTooHeavy(hardware: Boolean, width: Int, height: Int, instances: Int): Boolean =
    !hardware && instances > 1 && width > 0 && height > 0 && width.toLong() * height > SOFTWARE_INSTANCES_MAX_PIXELS

  /**
   * True when [width] x [height] of [mime] is above what was measured on a Meta Quest ([horizonOs]), whatever its
   * decoder list says: H.264 above 4096x2304, see [ImmersiveMedia.exceedsAvcDecoder]. With [instances] streams of that
   * size at once, H.264 also exceeds when their summed pixel rate, at [frameRate] (30 when unknown or lower), is above
   * the 4096x2304 at 30 fps measured there: the two 2880x2880 lenses of an Insta360 X3 recording are refused, two
   * 1080x1080 transcoded ones pass. Other devices and codecs follow their list.
   */
  fun exceedsMeasuredLimit(
    mime: String?,
    width: Int,
    height: Int,
    horizonOs: Boolean,
    instances: Int = 1,
    frameRate: Double = 0.0,
  ): Boolean {
    if (!horizonOs) return false
    if (ImmersiveMedia.exceedsAvcDecoder(mime, width, height)) return true
    if (instances < 2 || !mime.equals(MIME_AVC, ignoreCase = true) || width <= 0 || height <= 0) return false
    val rate = max(frameRate, DEFAULT_INSTANCES_FRAME_RATE)
    return instances.toDouble() * width * height * rate > maxAvcPixelRate
  }

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
   * [frameRate] frames per second (0 or less when unknown), of [bitDepth] bits per luma sample and of the ITU-T H.273
   * [transferCharacteristics] (1 BT.709, 16 PQ, 18 HLG), each 0 when unknown, [instances] streams of that size at once.
   * An unknown codec is not checked and counts as supported: the player still falls back on the transcoded stream if
   * the original fails. For Flutter, see VideoDecoderApi.
   */
  @OptIn(UnstableApi::class)
  fun canDecode(
    codec: String,
    codecs: String?,
    width: Int,
    height: Int,
    frameRate: Double,
    bitDepth: Int = 0,
    transferCharacteristics: Int = 0,
    instances: Int = 1,
  ): Verdict =
    canDecodeTransfer(
      codec,
      codecs,
      width,
      height,
      frameRate,
      bitDepth,
      if (transferCharacteristics > 0) {
        ColorInfo.isoTransferCharacteristicsToColorTransfer(transferCharacteristics)
      } else {
        Format.NO_VALUE
      },
      instances,
    )

  /**
   * [canDecode] for the video track [format] the player selected, with the colour Media3 read from the container or
   * the bitstream, [instances] tracks of that size at once.
   */
  @OptIn(UnstableApi::class)
  fun canDecode(format: Format, instances: Int = 1): Verdict =
    canDecodeTransfer(
      format.sampleMimeType ?: format.codecs.orEmpty(),
      format.codecs,
      format.width,
      format.height,
      format.frameRate.toDouble(),
      (format.colorInfo?.lumaBitdepth ?: Format.NO_VALUE).coerceAtLeast(0),
      format.colorInfo?.colorTransfer ?: Format.NO_VALUE,
      instances,
    )

  /** [canDecode] with the transfer as Media3 counts it ([colorTransfer], a C.COLOR_TRANSFER_* value or NO_VALUE). */
  private fun canDecodeTransfer(
    codec: String,
    codecs: String?,
    width: Int,
    height: Int,
    frameRate: Double,
    bitDepth: Int,
    colorTransfer: Int,
    instances: Int,
  ): Verdict {
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
        bitDepth = bitDepth.coerceAtLeast(0),
        colorTransfer = if (colorTransfer > 0) colorTransfer else Format.NO_VALUE,
        instances = instances.coerceAtLeast(1),
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
    Log.i(
      TAG,
      "${streamsOf(question.instances)}${codecName(mime)} ${question.width}x${question.height} at " +
        "${question.frameRate} fps, " +
        "${if (question.bitDepth > 0) "${question.bitDepth} bit" else "bit depth unknown"}, " +
        "transfer ${transferName(question.colorTransfer)}: $verdict",
    )
    answers[question] = verdict
    return verdict
  }

  /** "2 x " before the size of a question about two streams, nothing for one. */
  private fun streamsOf(instances: Int): String = if (instances > 1) "$instances x " else ""

  /** Name of a Media3 C.COLOR_TRANSFER_* value for the logs. */
  fun transferName(colorTransfer: Int): String =
    when (colorTransfer) {
      C.COLOR_TRANSFER_SDR -> "SDR"
      C.COLOR_TRANSFER_ST2084 -> "PQ"
      C.COLOR_TRANSFER_HLG -> "HLG"
      C.COLOR_TRANSFER_SRGB -> "sRGB"
      C.COLOR_TRANSFER_GAMMA_2_2 -> "gamma 2.2"
      else -> "unknown"
    }

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
        val capabilities = capabilitiesOf(info, type) ?: continue
        val video = capabilities.videoCapabilities ?: continue
        val (width, height) = largestSize(video, type, horizonOs)
        val rate = runCatching { video.getSupportedFrameRatesFor(width, height).upper }.getOrDefault(0.0)
        val profiles =
          profilesSummary(type.lowercase(), capabilities.profileLevels.orEmpty().map { it.profile to it.level })
        decoders += Decoder(info.name, type.lowercase(), hardware, width, height, rate, profiles)
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
    val required =
      requiredProfile(
        mime,
        codecsProfileOf(mime, question.codecs, question.colorTransfer),
        question.bitDepth,
        question.colorTransfer,
      )
    val acceptable = required?.let { acceptableProfiles(mime, it) }
    val profile = required?.let { profileName(mime, it) }
    if (
      sized &&
        exceedsMeasuredLimit(mime, question.width, question.height, horizonOs, question.instances, question.frameRate)
    ) {
      val streams = streamsOf(question.instances)
      val rate = if (question.instances > 1) " at ${max(question.frameRate, DEFAULT_INSTANCES_FRAME_RATE)} fps" else ""
      return Verdict(
        supported = false,
        hardware = false,
        maxWidth = ImmersiveMedia.MAX_AVC_LONG_SIDE,
        maxHeight = ImmersiveMedia.MAX_AVC_SHORT_SIDE,
        reason = "${streams}H.264 $size$rate is above the 4096x2304 at 30 fps measured on the Meta Quest 3",
        profile = profile,
      )
    }
    val refusals = mutableListOf<String>()
    for (info in candidates) {
      val capabilities = capabilitiesOf(info, mime) ?: continue
      val video = capabilities.videoCapabilities ?: continue
      val refusal = refusalOf(capabilities, video, question, acceptable, profile)
      if (refusal != null) {
        refusals += "${info.name} $refusal"
        continue
      }
      val hardware = isHardware(info)
      if (softwareTooHeavy(hardware, question.width, question.height, question.instances)) {
        refusals += "${info.name} runs in software: ${question.instances} x $size is too heavy for it"
        continue
      }
      val (maxWidth, maxHeight) = largestSize(video, mime, horizonOs)
      return Verdict(
        supported = true,
        hardware = hardware,
        maxWidth = maxWidth,
        maxHeight = maxHeight,
        reason = "${info.name} (${if (hardware) "hardware" else "software"})",
        profile = profile,
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
    // The profile is the reason only when every decoder lists its profiles and none lists one that takes the video: a
    // decoder that lists nothing, or the right profile, was refused for something else
    val profileMissing =
      acceptable != null &&
        candidates.none { info ->
          capabilitiesOf(info, mime)?.profileLevels?.let { levels ->
            levels.isEmpty() || levels.any { it.profile in acceptable }
          } ?: false
        }
    return Verdict(
      supported = false,
      hardware = false,
      maxWidth = maxWidth,
      maxHeight = maxHeight,
      reason = refusals.joinToString("; ").ifEmpty { "no decoder for $mime" },
      profile = profile,
      missingProfile = if (profileMissing) profile else null,
    )
  }

  /**
   * Why [video] cannot take [question], or null when it can: a decoder that lists profiles must list one of
   * [acceptable] (named [profile]), then take the size at the rate. For several streams at once, the decoder must also
   * allow that many instances, and its level and its performance points must take their summed rate.
   */
  private fun refusalOf(
    capabilities: CodecCapabilities,
    video: VideoCapabilities,
    question: Question,
    acceptable: Set<Int>?,
    profile: String?,
  ): String? {
    val levels = capabilities.profileLevels
    if (acceptable != null && levels.isNotEmpty() && levels.none { it.profile in acceptable }) {
      return "lacks profile $profile"
    }
    val instances = question.instances
    if (instances > 1 && capabilities.maxSupportedInstances < instances) {
      return "allows ${capabilities.maxSupportedInstances} instances, not $instances"
    }
    if (question.width <= 0 || question.height <= 0) return null
    val width = question.width
    val height = question.height
    val rate = question.frameRate
    if (!sizeFitsEitherWay(video, width, height, rate)) {
      return "does not take ${width}x$height" + if (rate > 0) " at $rate fps" else ""
    }
    if (rate > 0 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !performanceCovers(video, width, height, rate)) {
      return "has no performance point for ${width}x$height at $rate fps"
    }
    if (instances <= 1) return null
    // The streams share the decoder hardware: the level must allow their summed macroblock rate
    val streamRate = if (rate > 0) rate else DEFAULT_INSTANCES_FRAME_RATE
    val summedRate = streamRate * instances
    if (!sizeFitsEitherWay(video, width, height, summedRate)) {
      return "does not take $instances x ${width}x$height at $streamRate fps"
    }
    if (
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
        !performanceCoversInstances(video, width, height, streamRate, instances)
    ) {
      return "has no performance point for $instances x ${width}x$height at $streamRate fps"
    }
    return null
  }

  /** [sizeFits], also turned a quarter for a portrait frame, which a decoder may only take as landscape. */
  private fun sizeFitsEitherWay(video: VideoCapabilities, width: Int, height: Int, rate: Double): Boolean =
    sizeFits(video, width, height, rate) || (width < height && sizeFits(video, height, width, rate))

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
   * Whether the performance points of [video] cover [instances] streams of [width] x [height] at [rate] at once: a
   * point for frames that many times as large at the same rate (an 8K30 point covers two 3840x3840 at 30), or one for
   * the same frames that many times as often. Without points, or untrusted ones, the ranges decide, as in
   * [performanceCovers].
   */
  @RequiresApi(Build.VERSION_CODES.Q)
  private fun performanceCoversInstances(
    video: VideoCapabilities,
    width: Int,
    height: Int,
    rate: Double,
    instances: Int,
  ): Boolean {
    val points = video.supportedPerformancePoints
    if (points.isNullOrEmpty()) return true
    val frameRate = rate.toInt().coerceAtLeast(1)
    val taller = PerformancePoint(width, height * instances, frameRate)
    val faster = PerformancePoint(width, height, (rate * instances).toInt().coerceAtLeast(1))
    if (points.any { it.covers(taller) || it.covers(faster) }) return true
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

  /**
   * The profile the RFC 6381 [codecs] name, as MediaCodecInfo.CodecProfileLevel counts them, for checked codecs: what
   * Media3 derives before it plays the track, with [colorTransfer] set on the format so that a PQ HEVC or AV1 Main 10
   * video gives the HDR10 profile, as Media3 asks the decoder for.
   */
  @OptIn(UnstableApi::class)
  private fun codecsProfileOf(mime: String, codecs: String?, colorTransfer: Int): Int? {
    if (codecs == null || mime !in profileCheckedMimes) return null
    val videoCodecs = Util.getCodecsOfType(codecs, C.TRACK_TYPE_VIDEO) ?: return null
    val builder = Format.Builder().setSampleMimeType(mime).setCodecs(videoCodecs)
    if (colorTransfer != Format.NO_VALUE) {
      builder.setColorInfo(ColorInfo.Builder().setColorTransfer(colorTransfer).build())
    }
    return runCatching { CodecSpecificDataUtil.getCodecProfileAndLevel(builder.build())?.first }.getOrNull()
  }

  /**
   * The profile a decoder must list for the video: the one of its codecs string ([codecsProfile], from Media3), else
   * one its [bitDepth] implies. HEVC and AV1 Main 10 with a PQ transfer need Main 10 HDR10, an HLG one Main 10. H.264
   * is only checked for its 10 bit, 4:2:2 and 4:4:4 profiles. Null when nothing is checked.
   */
  fun requiredProfile(mime: String, codecsProfile: Int?, bitDepth: Int, colorTransfer: Int): Int? {
    val pq = colorTransfer == C.COLOR_TRANSFER_ST2084
    return when (mime) {
      MIME_HEVC ->
        when {
          codecsProfile == HEVCProfileMain10 && pq -> HEVCProfileMain10HDR10
          codecsProfile != null -> codecsProfile
          bitDepth >= 10 -> if (pq) HEVCProfileMain10HDR10 else HEVCProfileMain10
          else -> null
        }
      MIME_AV1 ->
        when {
          codecsProfile == AV1ProfileMain10 && pq -> AV1ProfileMain10HDR10
          codecsProfile != null -> codecsProfile
          bitDepth >= 10 -> if (pq) AV1ProfileMain10HDR10 else AV1ProfileMain10
          else -> null
        }
      MIME_VP9 -> codecsProfile
      MIME_AVC ->
        when {
          codecsProfile == AVCProfileHigh10 || codecsProfile == AVCProfileHigh422 || codecsProfile == AVCProfileHigh444 ->
            codecsProfile
          codecsProfile == null && bitDepth >= 10 -> AVCProfileHigh10
          else -> null
        }
      else -> null
    }
  }

  /**
   * The profiles of which a decoder must list one to take a video of the [required] profile: an HDR profile also plays
   * on its base 10 bit decoder (Media3 plays such a track, past the capabilities it reports), so a PQ video is not sent
   * to the transcoded stream for that alone.
   */
  fun acceptableProfiles(mime: String, required: Int): Set<Int> =
    when {
      mime == MIME_HEVC && (required == HEVCProfileMain10HDR10 || required == HEVCProfileMain10HDR10Plus) ->
        setOf(required, HEVCProfileMain10)
      mime == MIME_AV1 && (required == AV1ProfileMain10HDR10 || required == AV1ProfileMain10HDR10Plus) ->
        setOf(required, AV1ProfileMain10)
      mime == MIME_VP9 && required == VP9Profile2HDR -> setOf(required, VP9Profile2)
      else -> setOf(required)
    }

  private val hevcProfileNames =
    mapOf(
      HEVCProfileMain to "Main",
      HEVCProfileMain10 to "Main 10",
      HEVCProfileMainStill to "Main Still",
      HEVCProfileMain10HDR10 to "Main 10 HDR10",
      HEVCProfileMain10HDR10Plus to "Main 10 HDR10+",
    )

  private val avcProfileNames =
    mapOf(
      AVCProfileBaseline to "Baseline",
      AVCProfileMain to "Main",
      AVCProfileExtended to "Extended",
      AVCProfileHigh to "High",
      AVCProfileHigh10 to "High 10",
      AVCProfileHigh422 to "High 4:2:2",
      AVCProfileHigh444 to "High 4:4:4",
      AVCProfileConstrainedBaseline to "Constrained Baseline",
      AVCProfileConstrainedHigh to "Constrained High",
    )

  private val av1ProfileNames =
    mapOf(
      AV1ProfileMain8 to "Main 8",
      AV1ProfileMain10 to "Main 10",
      AV1ProfileMain10HDR10 to "Main 10 HDR10",
      AV1ProfileMain10HDR10Plus to "Main 10 HDR10+",
    )

  private val vp9ProfileNames =
    mapOf(
      VP9Profile0 to "Profile 0",
      VP9Profile1 to "Profile 1",
      VP9Profile2 to "Profile 2",
      VP9Profile3 to "Profile 3",
      VP9Profile2HDR to "Profile 2 HDR",
      VP9Profile3HDR to "Profile 3 HDR",
      VP9Profile2HDR10Plus to "Profile 2 HDR10+",
      VP9Profile3HDR10Plus to "Profile 3 HDR10+",
    )

  // The Dolby Vision profile constants are powers of two in the order of the profile numbers: dvav.per (profile 0)
  // is 1, dav1.10 (profile 10) is 1024
  private val dolbyVisionProfileNames = (0..10).associate { (1 shl it) to "Profile $it" }

  /**
   * HEVC levels as the codecs strings write them: L for the main tier, H for the high tier. The constants double from
   * Main tier level 1 (1) to High tier level 6.2 (33554432), main before high at each level.
   */
  private val hevcLevelNames =
    listOf("1", "2", "2.1", "3", "3.1", "4", "4.1", "5", "5.1", "5.2", "6", "6.1", "6.2")
      .flatMapIndexed { index, level ->
        listOf((1 shl (2 * index)) to "L$level", (1 shl (2 * index + 1)) to "H$level")
      }
      .toMap()

  private val avcLevelNames =
    listOf("1", "1b", "1.1", "1.2", "1.3", "2", "2.1", "2.2", "3", "3.1")
      .plus(listOf("3.2", "4", "4.1", "4.2", "5", "5.1", "5.2", "6", "6.1", "6.2"))
      .mapIndexed { index, level -> (1 shl index) to level }
      .toMap()

  private val vp9LevelNames =
    listOf("1", "1.1", "2", "2.1", "3", "3.1", "4", "4.1", "5", "5.1", "5.2", "6", "6.1", "6.2")
      .mapIndexed { index, level -> (1 shl index) to level }
      .toMap()

  /** Name of the [profile] constant of [mime] for the decoders page and the verdicts: "Main 10", "High 10". */
  fun profileName(mime: String, profile: Int): String {
    val names =
      when (mime.lowercase()) {
        MIME_HEVC -> hevcProfileNames
        MIME_AVC -> avcProfileNames
        MIME_AV1 -> av1ProfileNames
        MIME_VP9 -> vp9ProfileNames
        MIME_DOLBY_VISION -> dolbyVisionProfileNames
        else -> emptyMap()
      }
    return names[profile] ?: "profile $profile"
  }

  /** Name of the [level] constant of [mime] ("L6.1", "5.1"), null when unknown or not named (Dolby Vision). */
  fun levelName(mime: String, level: Int): String? =
    when (mime.lowercase()) {
      MIME_HEVC -> hevcLevelNames[level]
      MIME_AVC -> avcLevelNames[level]
      MIME_VP9 -> vp9LevelNames[level]
      MIME_AV1 -> av1LevelName(level)
      else -> null
    }

  /** AV1 levels 2.0 to 7.3 are the powers of two from 1, four minor levels to a major one: "6.1", or "5" for 5.0. */
  private fun av1LevelName(level: Int): String? {
    if (level <= 0 || (level and (level - 1)) != 0) return null
    val k = Integer.numberOfTrailingZeros(level)
    if (k > 23) return null
    val minor = k % 4
    return if (minor == 0) "${2 + k / 4}" else "${2 + k / 4}.$minor"
  }

  /**
   * One entry per profile a decoder of [mime] lists in [levels] (profile to level pairs), with its highest level:
   * "Main 10 L6.1". The level constants grow with the level (and, for HEVC, the high tier above the main tier at the
   * same level), so the highest is the largest value. In the order of the profile constants.
   */
  fun profilesSummary(mime: String, levels: List<Pair<Int, Int>>): List<String> =
    levels
      .groupBy({ it.first }, { it.second })
      .toSortedMap()
      .map { (profile, profileLevels) ->
        val name = profileName(mime, profile)
        val level = levelName(mime, profileLevels.max())
        if (level == null) name else "$name $level"
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
