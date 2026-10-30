package app.alextran.immich.immersive.splat

import app.alextran.immich.immersive.scene.SceneTexts
import java.util.Locale

/**
 * The texts of a splat in the headset (lot S5), translated by Flutter in stereoLabels under these keys
 * (splatViewerLabels of immersive_viewer_labels.dart), each with its English text for a key Flutter did not send. The
 * numbers go where the translations put {count}, {version}, {tool}, {kept}, {total} and {reason}. Reset, the
 * controller hint, the free memory and the heat say what they say for the 3D scenes (SceneTexts).
 */
internal object SplatTexts {
  const val LABEL_PREPARING = "splatPreparing"
  const val LABEL_NOTICE = "splatNotice"
  const val LABEL_DISCLAIMER = "splatDisclaimer"
  const val LABEL_LARGE = "splatLarge"
  const val LABEL_REDUCED = "splatReduced"
  const val LABEL_UPRIGHT = "splatUpright"
  const val LABEL_SPZ = "splatSpz"
  const val LABEL_PLY = "splatPly"
  const val LABEL_PLY_TOOL = "splatPlyTool"
  const val LABEL_OLDER_HEADSET = "splatOlderHeadset"
  const val LABEL_NOT_IN_VERSION = "splatNotInVersion"
  const val LABEL_NOT_A_SPLAT = "splatNotSplat"
  const val LABEL_COMPRESSED_PLY = "splatCompressedPly"
  const val LABEL_UNSUPPORTED_PLY = "splatUnsupportedPly"
  const val LABEL_NEWER_SPZ = "splatNewerSpz"
  const val LABEL_DAMAGED = "splatDamaged"
  const val LABEL_TOO_LARGE = "splatTooLarge"
  const val LABEL_NO_SPACE = "splatNoSpace"
  const val LABEL_NOT_RUNNING = "splatNotRunning"
  const val LABEL_FAILED = "splatFailed"

  const val COUNT = "{count}"
  const val VERSION = "{version}"
  const val TOOL = "{tool}"
  const val KEPT = "{kept}"
  const val TOTAL = "{total}"
  const val REASON = "{reason}"

  /** The English texts of these keys, for a key Flutter did not send */
  val englishLabels: Map<String, String> =
    mapOf(
      LABEL_PREPARING to "Preparing the splat",
      LABEL_NOTICE to "Gaussian splat (experimental)",
      LABEL_DISCLAIMER to
        "Gaussian splats use an experimental API of the Meta Spatial SDK, which Meta neither supports nor warrants: " +
          "any defect is Immuch360's own.",
      LABEL_LARGE to "Large splat: it may stutter",
      LABEL_REDUCED to "Reduced to $KEPT of $TOTAL gaussians",
      LABEL_UPRIGHT to "Turn upright",
      LABEL_SPZ to "$COUNT gaussians, SPZ version $VERSION",
      LABEL_PLY to "$COUNT gaussians, PLY",
      LABEL_PLY_TOOL to "$COUNT gaussians, PLY, made with $TOOL",
      LABEL_OLDER_HEADSET to "Gaussian splats need a Meta Quest 3 or 3S",
      LABEL_NOT_IN_VERSION to "Not in this version of the app",
      LABEL_NOT_A_SPLAT to "Not a Gaussian splat: this .ply holds a mesh or a point cloud",
      LABEL_COMPRESSED_PLY to "Compressed PLY: export it as .spz or as a standard .ply to open it here",
      LABEL_UNSUPPORTED_PLY to "This PLY is not read here: export it as a binary .ply or as .spz",
      LABEL_NEWER_SPZ to "Made with a newer SPZ version than the headset reads",
      LABEL_DAMAGED to "This splat file is damaged or incomplete",
      LABEL_TOO_LARGE to "Too large for this headset ($COUNT gaussians)",
      LABEL_NO_SPACE to "Not enough free space on the headset for this splat",
      LABEL_NOT_RUNNING to "The splat module did not start with this viewer: close it and open the splat again",
      LABEL_FAILED to "The splat could not be shown: $REASON",
    )

  /** The text of [key] from the translated [labels], the English one when it is missing or blank */
  fun label(labels: Map<String, String>, key: String): String =
    labels[key]?.takeIf { it.isNotBlank() } ?: englishLabels[key] ?: SceneTexts.label(labels, key)

  /**
   * What the first splat of a viewer says once it shows: that it is experimental, then that its API is an experimental
   * one of the Meta Spatial SDK, which Meta neither supports nor warrants, any defect being Immuch360's own (FreeKC's
   * decision of 30 October 2026)
   */
  fun noticeText(labels: Map<String, String>): String =
    label(labels, LABEL_NOTICE) + "\n" + label(labels, LABEL_DISCLAIMER)

  /** [count] with the grouping of [locale]: 452,451 in English */
  fun number(count: Long, locale: Locale = Locale.getDefault()): String = String.format(locale, "%,d", count)

  /** "452,451 gaussians, SPZ version 3", "19,469 gaussians, PLY, made with Postshot": what the file is */
  fun fileLine(labels: Map<String, String>, head: SplatHead, locale: Locale = Locale.getDefault()): String {
    val count = number(head.gaussians, locale)
    return when (head) {
      is SplatProbe.Spz ->
        label(labels, LABEL_SPZ).replace(COUNT, count).replace(VERSION, "${head.version}")
      is SplatProbe.Ply ->
        if (head.tool == null) label(labels, LABEL_PLY).replace(COUNT, count)
        else label(labels, LABEL_PLY_TOOL).replace(COUNT, count).replace(TOOL, head.tool)
    }
  }

  /** "Reduced to 50,000 of 452,451 gaussians" */
  fun reducedLine(labels: Map<String, String>, kept: Int, total: Long, locale: Locale = Locale.getDefault()): String =
    label(labels, LABEL_REDUCED).replace(KEPT, number(kept.toLong(), locale)).replace(TOTAL, number(total, locale))

  /** The lines the panel keeps for a splat: what the file is, and its reduction when it was reduced */
  fun detailLines(
    labels: Map<String, String>,
    head: SplatHead,
    verdict: SplatVerdict.Open,
    locale: Locale = Locale.getDefault(),
  ): List<String> {
    val lines = mutableListOf(fileLine(labels, head, locale))
    verdict.keep?.let { lines += reducedLine(labels, it, verdict.gaussians, locale) }
    return lines
  }

  /** Why a splat is not shown */
  fun refusalText(labels: Map<String, String>, verdict: SplatVerdict.Refused, locale: Locale = Locale.getDefault()): String =
    when (verdict.refusal) {
      SplatRefusal.NOT_IN_THIS_VERSION -> label(labels, LABEL_NOT_IN_VERSION)
      SplatRefusal.OLDER_HEADSET -> label(labels, LABEL_OLDER_HEADSET)
      SplatRefusal.NOT_A_SPLAT -> label(labels, LABEL_NOT_A_SPLAT)
      SplatRefusal.COMPRESSED_PLY -> label(labels, LABEL_COMPRESSED_PLY)
      SplatRefusal.UNSUPPORTED_PLY -> label(labels, LABEL_UNSUPPORTED_PLY)
      SplatRefusal.NEWER_SPZ -> label(labels, LABEL_NEWER_SPZ)
      SplatRefusal.DAMAGED -> label(labels, LABEL_DAMAGED)
      SplatRefusal.TOO_LARGE -> label(labels, LABEL_TOO_LARGE).replace(COUNT, number(verdict.gaussians ?: 0, locale))
      SplatRefusal.NOT_ENOUGH_MEMORY -> SceneTexts.label(labels, SceneTexts.LABEL_NO_MEMORY)
      SplatRefusal.NOT_ENOUGH_SPACE -> label(labels, LABEL_NO_SPACE)
      SplatRefusal.TOO_WARM -> SceneTexts.label(labels, SceneTexts.LABEL_TOO_WARM)
      SplatRefusal.MODULE_NOT_RUNNING -> label(labels, LABEL_NOT_RUNNING)
    }

  /** "The splat could not be shown: [reason]" */
  fun failedText(labels: Map<String, String>, reason: String): String = label(labels, LABEL_FAILED).replace(REASON, reason)

  /**
   * What the user reads when the preparation of a splat failed with [error]: a file that turns out damaged or
   * unsupported while it is read says so as the probe would ([refusalText], translated), a lack of memory as the
   * scenes say it; anything else is "The splat could not be shown" with its message
   */
  fun errorText(labels: Map<String, String>, error: Throwable, locale: Locale = Locale.getDefault()): String =
    when (error) {
      is SplatReadException -> refusalText(labels, SplatVerdict.Refused(SplatGate.refusalOf(error.problem)), locale)
      is OutOfMemoryError -> refusalText(labels, SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_MEMORY), locale)
      else -> failedText(labels, error.message ?: error.javaClass.simpleName)
    }
}
