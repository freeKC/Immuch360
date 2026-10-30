package app.alextran.immich.immersive.splat

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
  TOO_WARM,
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
 * 6. The memory: the free memory (ActivityManager.MemoryInfo.availMem) holds [MEMORY_FACTOR] times the file.
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
  const val MEMORY_FACTOR = 3

  /** PowerManager.THERMAL_STATUS_SEVERE: from this status on no splat opens */
  const val THERMAL_STATUS_SEVERE = 3

  /** Build.DEVICE of the Quest 2 and the Quest Pro */
  val OLDER_DEVICES = setOf("hollywood", "seacliff")

  /**
   * The verdict for [probe], a file of [fileBytes], on the headset [device] with the splat module when [engine], at
   * most [cap] gaussians (the maxGaussians of the request); [availableMemory] and [thermalStatus] null when unknown
   */
  fun check(
    engine: Boolean,
    device: String?,
    probe: SplatProbe,
    fileBytes: Long,
    cap: Int,
    availableMemory: Long?,
    thermalStatus: Int?,
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
    if (availableMemory != null && availableMemory < MEMORY_FACTOR * fileBytes) {
      return SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY)
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
