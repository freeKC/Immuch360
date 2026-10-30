package app.alextran.immich.immersive.splat

import java.io.File

/** What the reading of a splat file gave, off the main thread */
internal sealed interface SplatPreparation {
  /**
   * The splat may show: [file] is what the splat module reads (the file itself, or a copy of the cache, reduced or
   * named after its format), [owned] when it is a file of the viewer that goes with the splat; [bounds] null without
   * positions read (a version 4 SPZ)
   */
  class Ready(
    val file: File,
    val owned: Boolean,
    val head: SplatHead,
    val verdict: SplatVerdict.Open,
    val bounds: SplatBounds?,
  ) : SplatPreparation

  /** Not shown, for [verdict]; [head] when the file was read */
  class Stopped(val verdict: SplatVerdict.Refused, val head: SplatHead?) : SplatPreparation
}

/**
 * The reading of a splat file before the splat module gets it (lot S5): its head (which wins over the request), the
 * gate of this headset, the first reading (scores and positions), the reduction when the gate asks for one, and the
 * bounds of the gaussians kept. The file the module reads ends with the extension of its format, whatever the source
 * was named: a copy of the cache is made when it does not. Pure JVM, tested by SplatPreparerTest on the fixtures.
 */
internal object SplatPreparer {
  /**
   * Prepares [source] (a file of the viewer when [sourceOwned], which it may rename) for a request of at most [cap]
   * gaussians, on the headset [device] with the splat module when [engine]; copies go to [cacheDir] under [prefix]
   */
  fun prepare(
    source: File,
    sourceOwned: Boolean,
    cap: Int,
    engine: Boolean,
    device: String?,
    availableMemory: () -> Long?,
    thermalStatus: () -> Int?,
    cacheDir: File,
    prefix: String,
    cancelled: () -> Boolean = { false },
  ): SplatPreparation {
    val probe = SplatHeader.read(source)
    val head = probe as? SplatHead
    val verdict = SplatGate.check(engine, device, probe, source.length(), cap, availableMemory(), thermalStatus())
    if (verdict is SplatVerdict.Refused) return SplatPreparation.Stopped(verdict, head)
    verdict as SplatVerdict.Open
    head!!
    val zstd = head is SplatProbe.Spz && head.isZstd
    val scan = if (zstd) null else SplatReducer.scan(source.inputStream(), head, cancelled = cancelled)
    val keep = verdict.keep
    val extension = ".${head.format.json}"
    if (keep != null && scan != null) {
      val kept = SplatReducer.select(scan.scores, keep)
      val reduced = File(cacheDir, "$prefix${System.nanoTime()}$extension")
      try {
        reduced.outputStream().use { SplatReducer.write(source.inputStream(), head, kept, it, cancelled) }
      } catch (e: Throwable) {
        reduced.delete()
        throw e
      }
      if (sourceOwned) source.delete()
      return SplatPreparation.Ready(reduced, owned = true, head, verdict, SplatPlacement.boundsOf(scan, kept))
    }
    val bounds = scan?.let { SplatPlacement.boundsOf(it, null) }
    if (source.name.endsWith(extension, ignoreCase = true)) {
      return SplatPreparation.Ready(source, sourceOwned, head, verdict, bounds)
    }
    val named = File(cacheDir, "$prefix${System.nanoTime()}$extension")
    if (sourceOwned && source.renameTo(named)) return SplatPreparation.Ready(named, owned = true, head, verdict, bounds)
    source.copyTo(named, overwrite = true)
    if (sourceOwned) source.delete()
    return SplatPreparation.Ready(named, owned = true, head, verdict, bounds)
  }
}
