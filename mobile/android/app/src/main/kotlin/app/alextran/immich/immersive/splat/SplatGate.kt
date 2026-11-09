package app.alextran.immich.immersive.splat

import kotlin.math.ceil

/** Why a splat is not shown in this headset */
internal enum class SplatRefusal {
  /**
   * The APK of the phone flavour, without the splat module, or the store build, which never starts it (SplatBuild):
   * "Not in this version of the app"
   */
  NOT_IN_THIS_VERSION,

  /** A Quest 2 or a Quest Pro: "Gaussian splats need a Meta Quest 3 or 3S" */
  OLDER_HEADSET,
  NOT_A_SPLAT,
  COMPRESSED_PLY,
  UNSUPPORTED_PLY,
  NEWER_SPZ,
  DAMAGED,

  /** More gaussians than the reduction takes: "Too large for this headset" */
  TOO_LARGE,

  /**
   * The last guard before the entity (SplatModuleFormat.check): the file prepared for the module is not one it was
   * seen to read. Said rather than handed over, since the module would abort the process
   */
  MODULE_CANNOT_READ,

  /** The splat loaded, but the renderer of the module still says it is not running after the splat was shown */
  NO_RENDERER,
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
 * 4. The version of an SPZ: the module reads version 2 only and aborts the process on any other, so every SPZ is
 *    rewritten as version 2 by the preparation, version 2 included ([SplatModuleFormat], [SplatReducer]); a version 4
 *    (ZSTD) needs the decoder of the quest flavour ([SplatZstd]), without which it is not in this version.
 * 5. The heat: THERMAL_STATUS_SEVERE or worse refused, as for the scenes.
 * 6. The count: at most the count of the request ([SAFE_GAUSSIANS] by default, [LARGE_GAUSSIANS] with Large splats,
 *    never more). Beyond it the splat is reduced to that count ([SplatReducer]), up to [MAX_REDUCIBLE_GAUSSIANS]
 *    gaussians and [MAX_REDUCIBLE_BYTES].
 * 7. The memory: the free memory (ActivityManager.MemoryInfo.availMem) holds what the module loads, [MEMORY_FACTOR]
 *    times the larger of the file it reads and its gaussians decoded, plus what the reducer holds while it reads the
 *    whole file ([memoryNeeded]): a large capture reduced to 150 000 gaussians weighs what it shows, not its source.
 * 8. The cache: its free space holds what the preparation writes there, the reduced copy, the copy rewritten as
 *    version 2 or a copy named after the format ([cacheBytesWritten]), with [CACHE_RESERVE_BYTES] left over; a download
 *    is weighed before it starts ([roomForDownload]).
 *
 * The module itself runs only when [registers] said so as the viewer opened: on the Quest 3 and 3S, in the quest
 * flavour, in a build that offers the splats (not the store build, [SplatBuild]), with Gaussian splats on. A splat that
 * comes to a viewer without it is refused at once ([viewerRefusal]).
 *
 * Pure JVM, tested by SplatGateTest. The Dart side greys the button for the reasons it can know first (splat_gate.dart).
 */
internal object SplatGate {
  /**
   * The count by default: 50 000 until 8 November 2026 (design-final 2026-10-27, decision D7), then 300 000 from the
   * series of store/m2/quest-splat-cap-2026-11-08/series.md. On a Quest 3, a room of Brush cut to its 300 000
   * strongest gaussians and shown whole ran at 91 frames a second on the 90 Hz display (median, 86 at least from 5 s
   * after it was shown), thermal status 0, the largest count measured at the rate of the display (500 000 fell to
   * 83). The GPU headroom is thin: 94 % busy, 9.47 ms of the 11.1 ms of a frame (86 % and 8.62 ms at 150 000). The
   * headset stood still on its stand without tracking, the scene seen from a fixed pose, 45 s a file
   */
  const val SAFE_GAUSSIANS = 300_000

  /**
   * The most Large splats shows, from the same series: 1 000 000 gaussians shown whole ran at 77 frames a second
   * (median, 75 at least), the GPU 93 % busy, the app holding about 1.4 GB (PSS), thermal status 0; 1 274 802, the
   * whole room and the largest file measured, ran at 72. Larger splats are reduced to their 1 000 000 strongest
   */
  const val LARGE_GAUSSIANS = 1_000_000

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

  /**
   * What the decoder of a version 4 SPZ holds while it reads a stream: its window, 8 MiB at the level of compression
   * Niantic's writer takes (12)
   */
  const val ZSTD_DECODER_BYTES = 8L shl 20

  /** PowerManager.THERMAL_STATUS_SEVERE: from this status on no splat opens */
  const val THERMAL_STATUS_SEVERE = 3

  /** Build.DEVICE of the Quest 2 and the Quest Pro */
  val OLDER_DEVICES = setOf("hollywood", "seacliff")

  /**
   * Whether the viewer registers the feature of the splat module as it opens: the module is in this APK ([engine]),
   * this build offers the splats ([inThisBuild], false in the store build, see [SplatBuild]), the headset [device]
   * runs it, and the opening asked for it ([wanted], the Gaussian splats setting). Off, the module never runs,
   * whatever the viewer shows
   */
  fun registers(engine: Boolean, device: String?, wanted: Boolean, inThisBuild: Boolean): Boolean =
    engine && inThisBuild && wanted && device !in OLDER_DEVICES

  /**
   * Why a viewer refuses a splat before reading anything, null when it may go on: no module in this APK or a build
   * that does not offer the splats ([inThisBuild], see [SplatBuild]), an older headset, or a module that is not
   * [running] in this viewer
   */
  fun viewerRefusal(engine: Boolean, device: String?, running: Boolean, inThisBuild: Boolean): SplatVerdict.Refused? =
    when {
      !engine || !inThisBuild -> SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION)
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

  /**
   * The size of the file the module reads: [fileBytes] whole, or its share of the [keep] gaussians kept of [count];
   * with [growth] for a copy rewritten as version 2 ([rewriteGrowth])
   */
  fun loadedFileBytes(fileBytes: Long, count: Long, keep: Int?, growth: Double = 1.0): Long =
    if (keep == null || count <= 0) ceil(fileBytes * growth).toLong()
    else ceil(fileBytes.toDouble() * growth * keep / count).toLong() + REDUCED_SLACK_BYTES

  /**
   * How much larger a copy of [head] rewritten as version 2 may be than its source: the positions of version 1 take
   * 9 bytes instead of 6 (at most 19 bytes instead of 16 a point, compressed alike, taken as 1.5); version 3 loses a
   * byte of each rotation (1); version 2 is the same data again (1); version 4 goes from ZSTD to gzip (from 0.91 to
   * 1.03 times the file on four splats, taken as 1.25); a PLY is not rewritten (1)
   */
  fun rewriteGrowth(head: SplatHead): Double =
    when {
      head !is SplatProbe.Spz -> 1.0
      head.version == 1 -> 1.5
      head.isZstd -> 1.25
      else -> 1.0
    }

  /**
   * The free memory a splat of [head] needs, a file of [fileBytes] shown whole or reduced to [keep]: [MEMORY_FACTOR]
   * times the larger of the file the module reads and the gaussians it shows decoded, plus what the reducer holds
   * while it reads every gaussian of the source
   */
  fun memoryNeeded(head: SplatHead, fileBytes: Long, keep: Int?): Long {
    val shown = keep?.toLong() ?: head.gaussians
    val file = loadedFileBytes(fileBytes, head.gaussians, keep, rewriteGrowth(head))
    val loaded = maxOf(file, shown * decodedBytesPerGaussian(head.shDegree))
    val reducer = if (keep == null) 0L else REDUCER_BYTES_PER_GAUSSIAN * head.gaussians + REDUCER_OVERHEAD_BYTES
    val decoder = if (head is SplatProbe.Spz && head.isZstd) ZSTD_DECODER_BYTES else 0L
    return MEMORY_FACTOR * loaded + reducer + decoder
  }

  /**
   * The bytes the preparation writes into the cache: the reduced copy, else the whole file rewritten as version 2
   * ([rewrites], any SPZ, larger by [growth]), else the whole file when it is copied under the name
   * of its format ([copiesWhole]), else nothing
   */
  fun cacheBytesWritten(
    fileBytes: Long,
    count: Long,
    keep: Int?,
    copiesWhole: Boolean,
    rewrites: Boolean = false,
    growth: Double = 1.0,
  ): Long =
    when {
      keep != null -> loadedFileBytes(fileBytes, count, keep, growth)
      rewrites -> loadedFileBytes(fileBytes, count, null, growth) + REDUCED_SLACK_BYTES
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
   * format before the module reads it; [readsZstd] when this APK has the decoder of a version 4 SPZ (the quest
   * flavour). Every SPZ is written again as version 2, reduced or whole
   * (SplatModuleFormat.needsRewrite), and the cache must hold that copy
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
    readsZstd: Boolean = SplatZstds.available,
  ): SplatVerdict {
    if (!engine) return SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION)
    if (device in OLDER_DEVICES) return SplatVerdict.Refused(SplatRefusal.OLDER_HEADSET)
    val head =
      when (probe) {
        is SplatProbe.Refused -> return SplatVerdict.Refused(refusalOf(probe.problem))
        is SplatHead -> probe
      }
    // The module reads SPZ version 2 only and aborts on any other: every SPZ is rewritten, version 4 through the ZSTD
    // decoder of the quest flavour
    if (head is SplatProbe.Spz && head.isZstd && !readsZstd) {
      return SplatVerdict.Refused(SplatRefusal.NOT_IN_THIS_VERSION)
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
        if (count > MAX_REDUCIBLE_GAUSSIANS || fileBytes > MAX_REDUCIBLE_BYTES) {
          return SplatVerdict.Refused(SplatRefusal.TOO_LARGE, count)
        }
        most
      }
    if (availableMemory != null && availableMemory < memoryNeeded(head, fileBytes, keep)) {
      return SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY)
    }
    val rewrites = SplatModuleFormat.needsRewrite(head)
    val written = cacheBytesWritten(fileBytes, count, keep, copiesWhole, rewrites, rewriteGrowth(head))
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
