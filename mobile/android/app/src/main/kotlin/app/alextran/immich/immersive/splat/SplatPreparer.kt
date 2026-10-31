package app.alextran.immich.immersive.splat

import java.io.File
import java.util.BitSet

/** What the reading of a splat file gave, off the main thread */
internal sealed interface SplatPreparation {
  /**
   * The splat may show: [file] is what the splat module reads (the file itself, or a copy of the cache, reduced or
   * named after its format, or rewritten as version 2), [owned] when it is a file of the viewer that goes with the
   * splat; [bounds] null without positions read; [sourceBytes] the size of the source as the viewer read it, which names the
   * file in the memory of its orientation (the size of a request may be unknown)
   */
  class Ready(
    val file: File,
    val owned: Boolean,
    val head: SplatHead,
    val verdict: SplatVerdict.Open,
    val bounds: SplatBounds?,
    val sourceBytes: Long = file.length(),
  ) : SplatPreparation

  /** Not shown, for [verdict]; [head] when the file was read; [detail] for the log */
  class Stopped(val verdict: SplatVerdict.Refused, val head: SplatHead?, val detail: String? = null) : SplatPreparation
}

/**
 * The reading of a splat file before the splat module gets it (lot S5): its head (which wins over the request), the
 * gate of this headset, the first reading (scores and positions), the reduction when the gate asks for one, and the
 * bounds of the gaussians kept. The file the module reads ends with the extension of its format in lower case
 * (".spz", ".ply"), whatever the source was named ("SCENE.SPZ" too): a download of the viewer is renamed, a copy of the
 * cache is made of any other file.
 *
 * The module reads SPZ version 2 only and aborts the process on any other (SplatModuleFormat): an SPZ of version 1 or
 * 3 is always written again as version 2, reduced or whole, never handed over as it is. Whatever the preparation
 * gives the module, the source read where it is, a copy, a reduction or a rewrite, its head is read once more and must
 * be one the module reads, with the count expected ([SplatModuleFormat.check]): otherwise the splat stops with
 * [SplatRefusal.MODULE_CANNOT_READ] and the copy goes. Pure JVM, tested by SplatPreparerTest on the fixtures.
 */
internal object SplatPreparer {
  /**
   * Prepares [source] (a file of the viewer when [sourceOwned], which it may rename) for a request of at most [cap]
   * gaussians, on the headset [device] with the splat module when [engine]; copies go to [cacheDir] under [prefix],
   * whose free space [freeCache] gives (null when unknown)
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
    freeCache: () -> Long? = { null },
  ): SplatPreparation {
    val probe = SplatHeader.read(source)
    val head = probe as? SplatHead
    val sourceBytes = source.length()
    // The extension the module reads, in lower case: a source named otherwise is copied whole, unless it is a file of
    // the viewer, which is renamed
    val extension = head?.let { ".${it.format.json}" }
    val copiesWhole = extension != null && !source.name.endsWith(extension) && !sourceOwned
    val verdict =
      SplatGate.check(
        engine,
        device,
        probe,
        sourceBytes,
        cap,
        availableMemory(),
        thermalStatus(),
        freeCache(),
        copiesWhole,
      )
    if (verdict is SplatVerdict.Refused) return SplatPreparation.Stopped(verdict, head)
    verdict as SplatVerdict.Open
    head!!
    extension!!
    val scan = SplatReducer.scan(source.inputStream(), head, cancelled = cancelled)
    val keep = verdict.keep
    val shown = keep?.toLong() ?: head.gaussians
    if (keep != null || SplatModuleFormat.needsRewrite(head)) {
      // Reduced, or an SPZ of version 1 or 3 rewritten whole as version 2
      val kept =
        if (keep != null) SplatReducer.select(scan.scores, keep)
        else BitSet(head.gaussians.toInt()).apply { set(0, head.gaussians.toInt()) }
      val written = File(cacheDir, "$prefix${System.nanoTime()}$extension")
      try {
        written.outputStream().use { SplatReducer.write(source.inputStream(), head, kept, it, cancelled) }
      } catch (e: Throwable) {
        written.delete()
        throw e
      }
      if (sourceOwned) source.delete()
      val ready =
        SplatPreparation.Ready(
          written,
          owned = true,
          head,
          verdict,
          SplatPlacement.boundsOf(scan, if (keep != null) kept else null),
          sourceBytes,
        )
      return guarded(ready, shown)
    }
    val bounds = SplatPlacement.boundsOf(scan, null)
    if (source.name.endsWith(extension)) {
      return guarded(SplatPreparation.Ready(source, sourceOwned, head, verdict, bounds, sourceBytes), shown)
    }
    val named = File(cacheDir, "$prefix${System.nanoTime()}$extension")
    if (sourceOwned && source.renameTo(named)) {
      return guarded(SplatPreparation.Ready(named, owned = true, head, verdict, bounds, sourceBytes), shown)
    }
    try {
      source.copyTo(named, overwrite = true)
    } catch (e: Throwable) {
      named.delete()
      throw e
    }
    if (sourceOwned) source.delete()
    return guarded(SplatPreparation.Ready(named, owned = true, head, verdict, bounds, sourceBytes), shown)
  }

  /**
   * [ready] when the file it gives the module is one the module reads, with [gaussians] in it; otherwise stopped with
   * [SplatRefusal.MODULE_CANNOT_READ], its copy of the cache deleted (a file of the user stays)
   */
  private fun guarded(ready: SplatPreparation.Ready, gaussians: Long): SplatPreparation {
    val why = SplatModuleFormat.check(ready.file, gaussians) ?: return ready
    if (ready.owned) ready.file.delete()
    return SplatPreparation.Stopped(SplatVerdict.Refused(SplatRefusal.MODULE_CANNOT_READ), ready.head, why)
  }
}

/**
 * The files of the cache one showing of a splat makes (lot S5): the [download], then the file a ready preparation
 * gives (a reduced copy, a download renamed, a copy named after the format). What the stage did not take goes at
 * [release]: after a refusal, a failure, or a cancellation that comes even after the preparation was ready (another
 * media, the end of the viewer). A file of the user ([SplatPreparation.Ready.owned] false) is never deleted. Pure JVM,
 * tested by SplatPreparerTest.
 */
internal class SplatCacheFiles(private val download: File?) {
  private var ready: SplatPreparation.Ready? = null
  private var handedOver = false

  /** What the preparation gave, remembered before anything else can fail */
  fun prepared(preparation: SplatPreparation): SplatPreparation {
    ready = preparation as? SplatPreparation.Ready
    return preparation
  }

  /** The stage takes the ready file: it goes with the splat from now on */
  fun handOver() {
    handedOver = true
  }

  /** Deletes what the stage did not take; nothing once it was handed over */
  fun release() {
    if (handedOver) return
    download?.delete()
    ready?.takeIf { it.owned }?.file?.delete()
    ready = null
  }
}
