package app.alextran.immich.immersive.splat

import kotlin.math.ceil

/** Why a splat is not shown in this headset */
internal enum class SplatRefusal {
  /** The APK of the phone flavour, without the splat module: "Not in this version of the app" */
  NOT_IN_THIS_VERSION,

  /** A Quest 2 or a Quest Pro: "Gaussian splats need a Meta Quest 3 or 3S" */
  OLDER_HEADSET,
  NOT_A_SPLAT,
  COMPRESSED_PLY,
  UNSUPPORTED_PLY,
  NEWER_SPZ,
  DAMAGED,

  /** More gaussians than the reduction takes, or a version 4 SPZ beyond the count: "Too large for this headset" */
  TOO_LARGE,
  NOT_ENOUGH_MEMORY,

  /** The cache of the headset cannot hold the download, the reduced copy or the copy named after the format */
  NOT_ENOUGH_SPACE,
  TOO_WARM,

  /**
   * The quest flavour on a Quest 3 or 3S, but the module was not registered with this viewer: Gaussian splats was off
   * when the viewer opened, or the registration failed. Said at once, rather than after a load event that never comes
   */
  MODULE_NOT_RUNNING,
}

/** What the gate says of a splat */
internal sealed interface SplatVerdict {
  /**
   * Shown: whole when [keep] is null, else reduced to its [keep] strongest gaussians; [large] when it shows more than
   * [SplatGate.SAFE_GAUSSIANS], which a passing text says may stutter
   */
  data class Open(val gaussians: Long, val keep: Int?, val large: Boolean) : SplatVerdict

  /** Not shown, for [refusal]; [gaussians] for a splat too large, which the sentence gives */
  data class Refused(val refusal: SplatRefusal, val gaussians: Long? = null) : SplatVerdict
}

/**
 * The gate of the splats in the headset (lot S5, decision D7 of design-final 2026-10-27). The splat module of the Meta
 * Spatial SDK runs on the Quest 3 and 3S only ("Only available on Meta Quest 3 and Quest 3S", and "avoid using
 * Gaussian splats with a splat count greater than 150k", https://developers.meta.com/horizon/documentation/spatial-sdk/
 * spatial-sdk-splats/): nothing in its API refuses another headset, so the viewer does.
 *
 * 1. The flavour: the module is in the APK of the quest flavour only ([SplatEngine.available]).
 * 2. The headset: the Quest 2 (hollywood) and the Quest Pro (seacliff) refused, any other taken (the Quest 3 eureka,
 *    the Quest 3S panther, and a headset this build does not know, as the scenes take it).
 * 3. The file: what the probe refused keeps its reason ([SplatHeader]).
 * 4. The heat: THERMAL_STATUS_SEVERE or worse refused, as for the scenes.
 * 5. The count: at most the count of the request ([SAFE_GAUSSIANS] until a measure in the headset, [LARGE_GAUSSIANS]
 *    with Large splats, never more). Beyond it the splat is reduced to that count ([SplatReducer]), up to
 *    [MAX_REDUCIBLE_GAUSSIANS] gaussians and [MAX_REDUCIBLE_BYTES]; a version 4 SPZ (ZSTD, which this build does not
 *    decompress) is shown whole within the count only.
 * 6. The memory: the free memory (ActivityManager.MemoryInfo.availMem) holds what the module loads, [MEMORY_FACTOR]
 *    times the larger of the file it reads and its gaussians decoded, plus what the reducer holds while it reads the
 *    whole file ([memoryNeeded]): a large capture reduced to 150 000 gaussians weighs what it shows, not its source.
 * 7. The cache: its free space holds what the preparation writes there, the reduced copy or a copy named after the
 *    format ([cacheBytesWritten]), with [CACHE_RESERVE_BYTES] left over; a download is weighed before it starts
 *    ([roomForDownload]).
 *
 * The module itself runs only when [registers] said so as the viewer opened: on the Quest 3 and 3S, in the quest
 * flavour, with Gaussian splats on. A splat that comes to a viewer without it is refused at once ([viewerRefusal]).
 *
 * Pure JVM, tested by SplatGateTest. The Dart side greys the button for the reasons it can know first (splat_gate.dart).
 */
internal object SplatGate {
  /** The count until a measure in the headset says more (design-final 2026-10-27, decision D7) */
  const val SAFE_GAUSSIANS = 50_000

  /** The advice of the SDK, the most Large splats shows */
  const val LARGE_GAUSSIANS = 150_000

  const val MAX_REDUCIBLE_GAUSSIANS = 4_000_000L
  const val MAX_REDUCIBLE_BYTES = 1L shl 30

  /** What the module holds for what it loads: the file it reads, its decoded gaussians, their copy for the GPU */
  const val MEMORY_FACTOR = 3

  /**
   * What the reducer holds for each gaussian of the source while it reads it: its score (4 bytes), the sorted copy of
   * the scores (4 bytes), the opacity of an SPZ (1 byte), and a bit of the set kept (SplatReducer)
   */
  const val REDUCER_BYTES_PER_GAUSSIAN = 9L

  /** The buffers and the sample of the positions of the reducer, whatever the file */
  const val REDUCER_OVERHEAD_BYTES = 8L shl 20

  /** The free space the cache keeps once a splat file is written there */
  const val CACHE_RESERVE_BYTES = 64L shl 20

  /** A header written again with a reduced copy, and the slack of its compression */
  const val REDUCED_SLACK_BYTES = 64L shl 10

  /** PowerManager.THERMAL_STATUS_SEVERE: from this status on no splat opens */
  const val THERMAL_STATUS_SEVERE = 3

  /** Build.DEVICE of the Quest 2 and the Quest Pro */
  val OLDER_DEVICES = setOf("hollywood", "seacliff")

  /**
   * Whether the viewer registers the feature of the splat module as it opens: the module is in this APK ([engine]),
   * the headset [device] runs it, and the opening asked for it ([wanted], the Gaussian splats setting). Off, the
   * module never runs, whatever the viewer shows
   */
  fun registers(engine: Boolean, device: String?, wanted: Boolean): Boolean =
    engine && wanted && device !in OLDER_DEVICES

  /**
   * Why a viewer refuses a splat before reading anything, null when it may go on: no module in this APK, an older
   * headset, or a module that is not [running] in this viewer
   */
  fun viewerRefusal(engine: Boolean, device: String?, running: Boolean): SplatVerdict.Refused? =
    when {
      !engine -> SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION)
      device in OLDER_DEVICES -> SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET)
      !running -> SplatVerdict.Refused(SplatRefusal.MODULE_NOT_RUNNING)
      else -> null
    }

  /**
   * The bytes one gaussian of degree [shDegree] takes decoded in 32 bit floats: its position, scales, rotation,
   * opacity, colour and the coefficients past the first
   */
  fun decodedBytesPerGaussian(shDegree: Int): Long =
    4L * (14 + 3 * SplatHeader.shCoefficients(shDegree.coerceIn(0, 4)))

  /** The size of the file the module reads: [fileBytes] whole, or its share of the [keep] gaussians kept of [count] */
  fun loadedFileBytes(fileBytes: Long, count: Long, keep: Int?): Long =
    if (keep == null || count <= 0) fileBytes
    else ceil(fileBytes.toDouble() * keep / count).toLong() + REDUCED_SLACK_BYTES

  /**
   * The free memory a splat of [head] needs, a file of [fileBytes] shown whole or reduced to [keep]: [MEMORY_FACTOR]
   * times the larger of the file the module reads and the gaussians it shows decoded, plus what the reducer holds
   * while it reads every gaussian of the source
   */
  fun memoryNeeded(head: SplatHead, fileBytes: Long, keep: Int?): Long {
    val shown = keep?.toLong() ?: head.gaussians
    val loaded = maxOf(loadedFileBytes(fileBytes, head.gaussians, keep), shown * decodedBytesPerGaussian(head.shDegree))
    val reducer = if (keep == null) 0L else REDUCER_BYTES_PER_GAUSSIAN * head.gaussians + REDUCER_OVERHEAD_BYTES
    return MEMORY_FACTOR * loaded + reducer
  }

  /**
   * The bytes the preparation writes into the cache: the reduced copy, else the whole file when it is copied under the
   * name of its format ([copiesWhole]), else nothing
   */
  fun cacheBytesWritten(fileBytes: Long, count: Long, keep: Int?, copiesWhole: Boolean): Long =
    when {
      keep != null -> loadedFileBytes(fileBytes, count, keep)
      copiesWhole -> fileBytes
      else -> 0L
    }

  /** Whether [freeCache] bytes hold a download of [fileBytes] (1 or less when its size is not known: let through) */
  fun roomForDownload(fileBytes: Long, freeCache: Long?): Boolean =
    freeCache == null || fileBytes <= 1 || freeCache >= fileBytes + CACHE_RESERVE_BYTES

  /**
   * The verdict for [probe], a file of [fileBytes], on the headset [device] with the splat module when [engine], at
   * most [cap] gaussians (the maxGaussians of the request); [availableMemory], [thermalStatus] and [freeCache] (the
   * free space of the cache) null when unknown; [copiesWhole] when the file is copied whole under the name of its
   * format before the module reads it
   */
  fun check(
    engine: Boolean,
    device: String?,
    probe: SplatProbe,
    fileBytes: Long,
    cap: Int,
    availableMemory: Long?,
    thermalStatus: Int?,
    freeCache: Long? = null,
    copiesWhole: Boolean = false,
  ): SplatVerdict {
    if (!engine) return SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION)
    if (device in OLDER_DEVICES) return SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET)
    val head =
      when (probe) {
        is SplatProbe.Refused -> return SplatVerdict.Refused(refusalOf(probe.problem))
        is SplatHead -> probe
      }
    if (thermalStatus != null && thermalStatus >= THERMAL_STATUS_SEVERE) {
      return SplatVerdict.Refused(SplatRefusal.TOO_WARM)
    }
    val most = cap.coerceIn(1, LARGE_GAUSSIANS)
    val count = head.gaussians
    val keep =
      if (count <= most) {
        null
      } else {
        val zstd = head is SplatProbe.Spz && head.isZstd
        if (zstd || count > MAX_REDUCIBLE_GAUSSIANS || fileBytes > MAX_REDUCIBLE_BYTES) {
          return SplatVerdict.Refused(SplatRefusal.TOO_LARGE, count)
        }
        most
      }
    if (availableMemory != null && availableMemory < memoryNeeded(head, fileBytes, keep)) {
      return SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY)
    }
    val written = cacheBytesWritten(fileBytes, count, keep, copiesWhole)
    if (freeCache != null && written > 0 && freeCache < written + CACHE_RESERVE_BYTES) {
      return SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE)
    }
    return SplatVerdict.Open(count, keep, large = (keep?.toLong() ?: count) > SAFE_GAUSSIANS)
  }

  fun refusalOf(problem: SplatFileProblem): SplatRefusal =
    when (problem) {
      SplatFileProblem.NOT_A_SPLAT -> SplatRefusal.NOT_A_SPLAT
      SplatFileProblem.COMPRESSED_PLY -> SplatRefusal.COMPRESSED_PLY
      SplatFileProblem.UNSUPPORTED_PLY -> SplatRefusal.UNSUPPORTED_PLY
      SplatFileProblem.NEWER_SPZ -> SplatRefusal.NEWER_SPZ
      SplatFileProblem.DAMAGED -> SplatRefusal.DAMAGED
    }
}
