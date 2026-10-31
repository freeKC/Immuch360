package app.alextran.immich.immersive.splat

import java.io.File

/**
 * What the splat module of the Meta Spatial SDK 0.14.0 reads, as measured on a Quest 3 on 31 October 2026 (bench of
 * store/m2/quest-splats-device-2026-10-31 of the research notes): a file it cannot read does not come back as a failed
 * load event, it aborts the whole process (SIGABRT in its loading thread), which no code of the app can catch. So the
 * viewer hands it nothing but what it was seen to read:
 *
 * - SPZ of version 2 only, one gzip stream. Version 3 ("version not supported: 3") and version 4 (its ZSTD streams)
 *   abort; version 1 loads, but its points are not where they should be. The viewer rewrites versions 1 and 3 as
 *   version 2 ([needsRewrite], SplatReducer.write) and refuses version 4, whose ZSTD this build does not read.
 * - PLY of 3D Gaussian Splatting: the module reads it by the names of its properties, in any order, float or double,
 *   SH 0 to 3, with normals or other properties; it aborts without x y z, opacity or scale_*. The probe of the viewer
 *   asks for more ([SplatHeader.REQUIRED_PLY], binary little endian), so every PLY it takes is read.
 *
 * [check] reads the head of the file the module is about to get, once more: the last guard before the entity, after
 * the preparation wrote, renamed or copied it. Pure JVM, tested by SplatModuleFormatTest.
 */
internal object SplatModuleFormat {
  /** The one SPZ version the module reads */
  const val SPZ_VERSION = 2

  /** Whether the module reads a file whose head is [probe] without aborting */
  fun reads(probe: SplatProbe): Boolean =
    when (probe) {
      is SplatProbe.Spz -> probe.version == SPZ_VERSION && !probe.isZstd
      is SplatProbe.Ply -> true
      is SplatProbe.Refused -> false
    }

  /** Whether a splat of [head] must be rewritten before the module reads it: an SPZ of version 1 or 3 */
  fun needsRewrite(head: SplatHead): Boolean = head is SplatProbe.Spz && !head.isZstd && head.version != SPZ_VERSION

  /**
   * Why [file] must not reach the module, null when it may: it is gone, its head is not one the module reads, its
   * extension is not that of its format in lower case, or it holds another count than the [gaussians] expected
   */
  fun check(file: File, gaussians: Long): String? {
    if (!file.isFile) return "no file"
    val probe =
      try {
        SplatHeader.read(file)
      } catch (e: Exception) {
        return "unreadable: ${e.message}"
      }
    if (!reads(probe)) {
      return when (probe) {
        is SplatProbe.Refused -> "refused by the probe: ${probe.detail}"
        is SplatProbe.Spz -> "SPZ version ${probe.version}"
        is SplatProbe.Ply -> "PLY"
      }
    }
    probe as SplatHead
    if (!file.name.endsWith(".${probe.format.json}")) return "named ${file.name} for a ${probe.format.json} file"
    if (probe.gaussians != gaussians) return "${probe.gaussians} gaussians, ${gaussians} expected"
    return null
  }
}
