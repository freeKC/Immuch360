package app.alextran.immich.immersive.splat

import java.io.File

/** What the reading of a splat file gave, off the main thread */
internal sealed interface SplatPreparation {
  /**
   * The splat may show: [file] is what the splat module reads (the file itself, or a copy of the cache, reduced or
   * named after its format), [owned] when it is a file of the viewer that goes with the splat; [bounds] null without
   * positions read (a version 4 SPZ); [sourceBytes] the size of the source as the viewer read it, which names the
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

  /** Not shown, for [verdict]; [head] when the file was read */
  class Stopped(val verdict: SplatVerdict.Refused, val head: SplatHead?) : SplatPreparation
}

/**
 * The reading of a splat file before the splat module gets it (lot S5): its head (which wins over the request), the
 * gate of this headset, the first reading (scores and positions), the reduction when the gate asks for one, and the
 * bounds of the gaussians kept. The file the module reads ends with the extension of its format in lower case
 * (".spz", ".ply"), whatever the source was named ("SCENE.SPZ" too): a download of the viewer is renamed, a copy of the
 * cache is made of any other file. Pure JVM, tested by SplatPreparerTest on the fixtures.
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
    val zstd = head is SplatProbe.Spz && head.isZstd
    val scan = if (zstd) null else SplatReducer.scan(source.inputStream(), head, cancelled = cancelled)
    val keep = verdict.keep
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
      return SplatPreparation.Ready(
        reduced,
        owned = true,
        head,
        verdict,
        SplatPlacement.boundsOf(scan, kept),
        sourceBytes,
      )
    }
    val bounds = scan?.let { SplatPlacement.boundsOf(it, null) }
    if (source.name.endsWith(extension)) {
      return SplatPreparation.Ready(source, sourceOwned, head, verdict, bounds, sourceBytes)
    }
    val named = File(cacheDir, "$prefix${System.nanoTime()}$extension")
    if (sourceOwned && source.renameTo(named)) {
      return SplatPreparation.Ready(named, owned = true, head, verdict, bounds, sourceBytes)
    }
    try {
      source.copyTo(named, overwrite = true)
    } catch (e: Throwable) {
      named.delete()
      throw e
    }
    if (sourceOwned) source.delete()
    return SplatPreparation.Ready(named, owned = true, head, verdict, bounds, sourceBytes)
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
