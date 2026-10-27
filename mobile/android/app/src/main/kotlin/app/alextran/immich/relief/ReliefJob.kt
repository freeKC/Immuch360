package app.alextran.immich.relief

import java.io.File
import java.util.concurrent.CancellationException

// The relief of one flat photo in the immersive view of the Meta Quest (design-final 2026-10-26, sections 3.1, 3.4,
// 3.6 and 3.7). The viewer shows the photo flat at once and hands it here: the depth map comes from the relief cache,
// or from the model (GpuParityCheck picks the GPU or the CPU) and goes to the cache, then relief-v1 makes the right eye
// and the viewer puts both eyes on the stereo quad. All of it runs on one thread of its own at background priority (a
// HandlerThread the viewer gives, immersive/ReliefHost.kt), so that the scene keeps its frames. "Stop relief", a
// headset that gets too warm, a new photo or the end of the viewer drop the relief: the photo stays flat, a pass of
// the model cannot be cut and goes to its end, its map thrown away. The model stays open from one photo to the next
// and is closed 60 s after the last relief, to give its memory back (about 375 MB on the CPU path, q0-measures 2).
// The headset checks again what the panel checked before asking (design 3.5): an engine in this version, the memory,
// the heat. Plain JVM code, without Android: the thread, the photo, the eye, the heat and the memory come from the
// viewer, so that the unit tests run it with fakes.

/** A relief the viewer asks for, from the depthRelief JSON of the photo */
class ReliefRequest(
  /** The model file on the headset, installed by the AI components */
  val model: File,
  /** Its size in the catalogue: a file of another size is not loaded */
  val modelSize: Long,
  /** "depth-anything-v2-small@651415f1", which the GPU decision of the headset is kept for */
  val modelId: String,
  /** The key of the depth map in the relief cache, made by Flutter (reliefCacheKey) */
  val cacheKey: String,
  val parallax: Double = ReliefV1.PARALLAX,
  val convergence: Double = ReliefV1.CONVERGENCE,
)

/**
 * The photo of a relief, upright (its EXIF orientation and the user's quarter turns applied) and opaque, as rows of
 * ARGB pixels. The relief reads each row twice, for the input of the model and for the right eye. [release] frees it
 * once the relief no longer needs it; a photo handed back with [ReliefResult] is the viewer's to free.
 */
interface ReliefPhoto : PixelRowReader {
  val width: Int
  val height: Int

  fun release()
}

/** The right eye of a relief, written row by row; [release] drops it when it is not shown */
interface ReliefEye : PixelRowWriter {
  fun release()
}

/** The thread of the relief: one task at a time, in the order they are posted */
interface ReliefWorker {
  fun post(task: Runnable)

  fun postDelayed(task: Runnable, delayMs: Long)

  /** Drops [task] if it was posted and has not run yet */
  fun cancel(task: Runnable)

  /** Ends the thread once the tasks due now have run; a delayed task not due yet is dropped */
  fun quit()
}

/** What the relief is doing, for the status line of the viewer */
enum class ReliefStage {
  /** Reading the photo and its map in the cache, making the input of the model */
  PREPARING,

  /** A pass of the model */
  ESTIMATING,

  /** relief-v1 makes the right eye */
  BUILDING,
}

/** Why the photo stays flat */
enum class ReliefStop {
  /** "Stop relief": the user asked */
  STOPPED,

  /** The headset reached THERMAL_STATUS_SEVERE, before or during the relief */
  TOO_WARM,

  /** This version of the app has no depth engine (the phone flavour on a headset) */
  NOT_IN_THIS_VERSION,

  /** Under 5 GiB of memory seen by Android (about 6 GB in the device), or out of memory during the relief */
  NOT_ENOUGH_MEMORY,

  /** The model is not installed */
  MODEL_MISSING,

  /** The model file has another size than the catalogue says, or is not the model this version runs */
  MODEL_DAMAGED,

  /** The model failed on the CPU too, or the right eye could not be made */
  FAILED,
}

/**
 * A relief made: [photo] and its right [eye], the viewer's to show and to free; [fromCache] when the map came from the
 * cache, [path] the path of the model otherwise; the [flags] of relief-v1 (the headset does not show them, they go to
 * the log)
 */
class ReliefResult<P : ReliefPhoto, E : ReliefEye>(
  val photo: P,
  val eye: E,
  val fromCache: Boolean,
  val path: DepthPath?,
  val flags: List<ReliefFlag>,
)

/** What the viewer is told, always on its main thread, and never for a relief it dropped */
interface ReliefListener<P : ReliefPhoto, E : ReliefEye> {
  fun onStage(stage: ReliefStage)

  fun onDone(result: ReliefResult<P, E>)

  /** The photo stays flat for [reason]; [detail] says more for [ReliefStop.FAILED], the message of the failure */
  fun onFlat(reason: ReliefStop, detail: String)
}

/** One relief asked by the viewer. Main thread, but [stopped], which the thread of the relief reads. */
class ReliefRun internal constructor() {
  /** Why it was stopped or dropped, null while it may still end well */
  @Volatile internal var stoppedFor: ReliefStop? = null

  /** The viewer was told how it ended, or it was dropped: nothing more is said */
  internal var finished = false

  internal var onStopped: (ReliefStop) -> Unit = {}

  internal val stopped: Boolean
    get() = stoppedFor != null

  /** Neither done, nor flat, nor dropped: the 3D button of the quad is "Stop relief" meanwhile */
  val running: Boolean
    get() = !finished
}

/**
 * The reliefs of one immersive viewer: one at a time, the depth model of [engine] kept open between them on the path
 * [memory] remembers (see [GpuParityCheck]), the maps in [cache]. [start], [stop], [cancel], [onThermalStatus] and
 * [close] are called on the main thread, which [main] posts the answers to; everything else runs on [worker].
 */
class ReliefJob(
  private val engine: DepthEngine,
  memory: DepthPathMemory,
  private val cache: ReliefCache,
  private val worker: ReliefWorker,
  private val main: (Runnable) -> Unit,
  /** PowerManager.getCurrentThermalStatus, read before a relief starts */
  private val thermalStatus: () -> Int,
  /** The memory Android sees (ActivityManager.MemoryInfo.totalMem) */
  private val totalMemoryBytes: Long,
  private val log: (String) -> Unit = {},
  private val nanoTime: () -> Long = System::nanoTime,
  private val idleCloseMs: Long = IDLE_CLOSE_MS,
  preferred: DepthPath = GpuParityCheck.PREFERRED_PATH,
) {
  companion object {
    /** The model is closed this long after the last relief */
    const val IDLE_CLOSE_MS = 60_000L

    /** PowerManager.THERMAL_STATUS_SEVERE: from this status on no relief starts and a running one stops */
    const val THERMAL_STATUS_SEVERE = 3

    /** 5 GiB seen by Android, about 6 GB in the device (design 3.5): the Quest 3 and 3S have 8 GB */
    const val MIN_TOTAL_MEMORY_BYTES = 5L * 1024 * 1024 * 1024

    /** The message of a failure is cut to this many characters on the status line */
    const val DETAIL_MAX_CHARS = 120
  }

  // The thread of the relief only: the OpenGL context of the GPU path belongs to it
  private val parity = GpuParityCheck(engine, memory, preferred, log, nanoTime)
  private var tensor: FloatArray? = null

  // The main thread only
  private var current: ReliefRun? = null
  @Volatile private var closed = false

  private val idleClose = Runnable {
    if (parity.openPath != null) {
      parity.close()
      log("relief: depth model closed, no relief for ${idleCloseMs / 1000} s")
    }
  }

  /**
   * Starts the relief of [photo], which the job owns from now on, and drops the relief of the photo before. The right
   * eye is written in what [newEye] makes, on the thread of the relief. A refusal of the headset (no engine, not
   * enough memory, too warm) comes as [ReliefListener.onFlat] without the thread.
   */
  fun <P : ReliefPhoto, E : ReliefEye> start(
    request: ReliefRequest,
    photo: P,
    newEye: (width: Int, height: Int) -> E,
    listener: ReliefListener<P, E>,
  ): ReliefRun {
    current?.let(::drop)
    val run = ReliefRun()
    run.onStopped = { reason -> listener.onFlat(reason, "") }
    current = run
    val refusal =
      when {
        closed -> ReliefStop.STOPPED
        !engine.available -> ReliefStop.NOT_IN_THIS_VERSION
        totalMemoryBytes < MIN_TOTAL_MEMORY_BYTES -> ReliefStop.NOT_ENOUGH_MEMORY
        thermalStatus() >= THERMAL_STATUS_SEVERE -> ReliefStop.TOO_WARM
        else -> null
      }
    if (refusal != null) {
      log("relief refused: $refusal (engine ${engine.engine}, ${totalMemoryBytes / 1048576} MB seen)")
      photo.release()
      flat(run, listener, refusal, "")
      return run
    }
    worker.post { work(run, request, photo, newEye, listener) }
    return run
  }

  /**
   * Stops [run] for [reason]: the photo stays flat, the viewer is told at once ([ReliefListener.onFlat]), a pass of
   * the model under way goes to its end and its map is thrown away. Nothing for a relief that ended already.
   */
  fun stop(run: ReliefRun, reason: ReliefStop = ReliefStop.STOPPED) {
    if (run.finished) return
    end(run, reason)
    log("relief stopped: $reason")
    run.onStopped(reason)
  }

  /** The viewer moves to a photo without relief: the running relief is dropped without a word */
  fun cancel() {
    current?.let(::drop)
  }

  /** A new thermal status of the headset (PowerManager's listener): from severe on, the running relief stops */
  fun onThermalStatus(status: Int) {
    if (status < THERMAL_STATUS_SEVERE) return
    current?.let { stop(it, ReliefStop.TOO_WARM) }
  }

  /** The end of the viewer: the relief is dropped, the model closed, the thread ended. No relief starts after. */
  fun close() {
    closed = true
    current?.let(::drop)
    worker.cancel(idleClose)
    worker.post { parity.close() }
    worker.quit()
  }

  /** Ends [run] without a word: a new photo, or the end of the viewer */
  private fun drop(run: ReliefRun) {
    if (!run.finished) end(run, ReliefStop.STOPPED)
  }

  /** [run] is over: told, stopped for [stoppedFor] or dropped; nothing more is said of it */
  private fun end(run: ReliefRun, stoppedFor: ReliefStop?) {
    if (stoppedFor != null) run.stoppedFor = stoppedFor
    run.finished = true
    if (current === run) current = null
  }

  // The thread of the relief

  private fun <P : ReliefPhoto, E : ReliefEye> work(
    run: ReliefRun,
    request: ReliefRequest,
    photo: P,
    newEye: (Int, Int) -> E,
    listener: ReliefListener<P, E>,
  ) {
    worker.cancel(idleClose)
    // Freed here unless it goes to the viewer with its right eye
    var photoHeld = true
    try {
      if (run.stopped) return
      val started = nanoTime()
      stage(run, listener, ReliefStage.PREPARING)
      val cached = cache.read(request.cacheKey)
      val map: ReliefMap
      val lowRelief: Boolean
      val path: DepthPath?
      if (cached != null) {
        log("relief: depth map ${cached.width}x${cached.height} from the cache")
        map = cached
        lowRelief = false
        path = null
      } else {
        checkModel(request)
        val input = ReliefPreprocess.prepare(photo.width, photo.height, photo, tensorBuffer())
        log("relief: input of the model from ${photo.width}x${photo.height} in ${elapsedMs(started)} ms")
        if (run.stopped) return
        stage(run, listener, ReliefStage.ESTIMATING)
        val pass = parity.estimate(request.model, request.modelId, input)
        if (run.stopped) {
          log("relief: stopped during the pass on ${pass.path}, its map thrown away")
          return
        }
        val frame = input.frame
        val normalized =
          ReliefSynthesizer.normalize(ReliefPreprocess.cropDepth(pass.depth, frame), frame.width, frame.height)
        // The eye is made from the map as the cache keeps it: the same eye now and when the photo comes back
        map = ReliefMap.quantize(frame.width, frame.height, normalized.values)
        cache.write(request.cacheKey, map)
        lowRelief = normalized.lowRelief
        path = pass.path
      }
      if (run.stopped) return
      stage(run, listener, ReliefStage.BUILDING)
      val eyeStarted = nanoTime()
      val eye = newEye(photo.width, photo.height)
      val right =
        try {
          ReliefSynthesizer.rightEye(
            photo.width,
            photo.height,
            map.toNormalized(),
            map.width,
            map.height,
            read = photo,
            write = eye,
            parallax = request.parallax,
            convergence = request.convergence,
            lowRelief = lowRelief,
            cancelled = { run.stopped },
          )
        } catch (e: Throwable) {
          eye.release()
          if (e is CancellationException) {
            log("relief: stopped while the right eye was made")
            return
          }
          throw e
        }
      log(
        "relief: right eye ${photo.width}x${photo.height} in ${elapsedMs(eyeStarted)} ms, " +
          "${right.filledPixels} pixels filled, flags ${right.flags.joinToString { it.xmp }.ifEmpty { "none" }}; " +
          "whole relief in ${elapsedMs(started)} ms"
      )
      photoHeld = false
      done(run, listener, ReliefResult(photo, eye, cached != null, path, right.flags))
    } catch (e: ReliefRefused) {
      log("relief: ${e.message}")
      flat(run, listener, e.reason, "")
    } catch (e: DepthEstimatorException) {
      log("relief: the depth model failed: ${e.message}")
      flat(run, listener, reasonOf(e.failure), e.message.orEmpty())
    } catch (e: OutOfMemoryError) {
      log("relief: out of memory: $e")
      flat(run, listener, ReliefStop.NOT_ENOUGH_MEMORY, "")
    } catch (e: Exception) {
      log("relief failed: $e")
      flat(run, listener, ReliefStop.FAILED, e.message ?: e.javaClass.simpleName)
    } finally {
      if (photoHeld) photo.release()
      if (!closed && parity.openPath != null) worker.postDelayed(idleClose, idleCloseMs)
    }
  }

  /** The model is the file the catalogue describes, or the relief says why not, before the engine opens it */
  private fun checkModel(request: ReliefRequest) {
    if (!request.model.isFile) {
      throw ReliefRefused(ReliefStop.MODEL_MISSING, "no model at ${request.model.path}")
    }
    val size = request.model.length()
    if (size != request.modelSize) {
      throw ReliefRefused(ReliefStop.MODEL_DAMAGED, "the model has $size bytes, not ${request.modelSize}")
    }
  }

  private fun tensorBuffer(): FloatArray = tensor ?: FloatArray(ReliefPreprocess.TENSOR_SIZE).also { tensor = it }

  private fun elapsedMs(since: Long): Long = (nanoTime() - since) / 1_000_000

  private fun reasonOf(failure: DepthFailure): ReliefStop =
    when (failure) {
      DepthFailure.NOT_IN_THIS_VERSION -> ReliefStop.NOT_IN_THIS_VERSION
      DepthFailure.MODEL_MISSING -> ReliefStop.MODEL_MISSING
      DepthFailure.WRONG_MODEL -> ReliefStop.MODEL_DAMAGED
      DepthFailure.OPEN_FAILED,
      DepthFailure.RUN_FAILED -> ReliefStop.FAILED
    }

  // Answers to the main thread, for a relief the viewer still waits for

  private fun <P : ReliefPhoto, E : ReliefEye> stage(
    run: ReliefRun,
    listener: ReliefListener<P, E>,
    stage: ReliefStage,
  ) {
    main(Runnable { if (!run.finished) listener.onStage(stage) })
  }

  private fun <P : ReliefPhoto, E : ReliefEye> done(
    run: ReliefRun,
    listener: ReliefListener<P, E>,
    result: ReliefResult<P, E>,
  ) {
    main(
      Runnable {
        if (run.finished) {
          // Dropped or stopped once the eye was made: nobody shows it
          result.photo.release()
          result.eye.release()
        } else {
          end(run, null)
          listener.onDone(result)
        }
      }
    )
  }

  private fun <P : ReliefPhoto, E : ReliefEye> flat(
    run: ReliefRun,
    listener: ReliefListener<P, E>,
    reason: ReliefStop,
    detail: String,
  ) {
    main(
      Runnable {
        if (!run.finished) {
          end(run, reason)
          listener.onFlat(reason, detail.take(DETAIL_MAX_CHARS))
        }
      }
    )
  }
}

/** A relief refused before the engine is asked: the model is missing or is not the file of the catalogue */
private class ReliefRefused(val reason: ReliefStop, message: String) : Exception(message)
