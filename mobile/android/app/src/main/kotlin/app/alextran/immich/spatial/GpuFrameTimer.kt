package app.alextran.immich.spatial

/**
 * The GL calls of the GPU timer queries (GL_EXT_disjoint_timer_query), behind an interface so that [GpuFrameTimer]
 * runs in JVM tests. GlesTimerGl is the implementation of the app, and the only file of the app that calls the query
 * functions. Every call runs on the GL thread, with the renderer's context current.
 */
interface TimerGl {
  fun genQueries(ids: IntArray)

  fun deleteQueries(ids: IntArray)

  /** glBeginQuery of GL_TIME_ELAPSED_EXT */
  fun beginQuery(id: Int)

  /** glEndQuery of GL_TIME_ELAPSED_EXT */
  fun endQuery()

  /** GL_QUERY_RESULT_AVAILABLE of the query [id] */
  fun resultAvailable(id: Int): Boolean

  /** GL_QUERY_RESULT of the query [id]: the GPU time, in nanoseconds */
  fun result(id: Int): Long

  /** GL_GPU_DISJOINT_EXT, which the read resets */
  fun disjoint(): Boolean

  fun finish()

  /** glGetError: 0 for GL_NO_ERROR */
  fun error(): Int
}

/**
 * Times the frames of the Spatial 2.5D renderer on the GPU when [GpuTimerPolicy] allows it, decided once per GL
 * context in [start]. Nothing it does reaches the frame: every call is wrapped, and during the first [CHECKED_FRAMES]
 * timed frames glGetError is checked after the query calls. Any failure turns the timer off for the context (the
 * names deleted, one log line), and the renderer times on the CPU instead ([active] false).
 *
 * The [guard] is armed before the first query of an armed period and disarmed when the timers stop ([release],
 * [onPaused]), so that a native crash in the driver turns the timers off on that driver for the next processes.
 *
 * Pending queries are never read across a change that may invalidate what they measured: a new window surface
 * ([voidPending]) or the deletion of render targets inside a frame ([settleBeforeDelete]). The deletion case is
 * defensive: the Mali driver crashed while flushing the framebuffers a result read depends on (Play cluster 7b656f,
 * and the symbolised frames of arcore_flutter_plugin issue 214), but nothing proves that a deleted target was the
 * trigger.
 *
 * Not thread safe: the renderer calls it under its lock, on the GL thread ([onPaused] on the main thread once the GL
 * thread is parked). [timing] may be read from any thread.
 */
class GpuFrameTimer(
  private val gl: TimerGl,
  private val guard: GpuTimerCrashGuard?,
  private val log: (String) -> Unit,
) {
  companion object {
    /** Queries in flight: a result is read three or four frames after its frame */
    const val SLOTS = 4

    /** Timed frames after which glGetError is no longer read after the query calls */
    const val CHECKED_FRAMES = 60

    const val GPU = "GPU"

    private const val NO_ERROR = 0
    private const val MAX_ERRORS_DRAINED = 16
    private const val NANOS_PER_MILLISECOND = 1_000_000f
    private const val NOT_STARTED = "no GL context"

    private fun cpu(reason: String) = "CPU ($reason)"
  }

  private val ids = IntArray(SLOTS)
  private val pending = BooleanArray(SLOTS)
  private val results = LongArray(SLOTS)
  private var hasNames = false
  private var running = false
  private var nextSlot = 0
  private var activeSlot = -1
  private var timedFrames = 0
  private var driverKey = ""
  private var armedKey: String? = null

  /** True while the queries time the frames; the renderer times on the CPU otherwise */
  val active: Boolean
    get() = running

  /** [GPU], or "CPU (why)", for the debug overlay; any thread */
  @Volatile
  var timing: String = cpu(NOT_STARTED)
    private set

  /**
   * A new GL context: forgets every name and state of the previous one first, then generates the queries when
   * [verdict] allows them. [driverKey] is what the guard arms.
   */
  fun start(verdict: GpuTimerVerdict, driverKey: String) {
    forget()
    this.driverKey = driverKey
    if (!verdict.allowed) {
      timing = cpu(verdict.reason)
      return
    }
    try {
      drainErrors()
      hasNames = true
      gl.genQueries(ids)
      val error = gl.error()
      if (error != NO_ERROR || ids.any { it == 0 }) {
        turnOff("glGenQueries ${describe(error)}")
        return
      }
    } catch (e: RuntimeException) {
      turnOff("glGenQueries threw $e")
      return
    }
    running = true
    timing = GPU
  }

  /** Starts the query of this frame, unless the slot it would use still waits for its result */
  fun begin() {
    if (activeSlot >= 0) end()
    if (!running) return
    val slot = nextSlot
    if (pending[slot]) return
    try {
      ensureArmed()
      timedFrames++
      val check = checking()
      if (check) drainErrors()
      gl.beginQuery(ids[slot])
      if (check) {
        val error = gl.error()
        if (error != NO_ERROR) {
          turnOff("glBeginQuery ${describe(error)}")
          return
        }
      }
      activeSlot = slot
    } catch (e: RuntimeException) {
      turnOff("glBeginQuery threw $e")
    }
  }

  /** Ends the query of this frame, if any; its result is read by a later [collect] */
  fun end() {
    val slot = activeSlot
    if (slot < 0) return
    activeSlot = -1
    try {
      val check = checking()
      if (check) drainErrors()
      gl.endQuery()
      if (check) {
        val error = gl.error()
        if (error != NO_ERROR) {
          turnOff("glEndQuery ${describe(error)}")
          return
        }
      }
      pending[slot] = true
      nextSlot = (slot + 1) % SLOTS
    } catch (e: RuntimeException) {
      turnOff("glEndQuery threw $e")
    }
  }

  /**
   * Reads the finished queries and gives each GPU time, in milliseconds, to [sample]. A disjoint event (frequency
   * change, context switch) voids the results read with it and the queries still in flight.
   */
  fun collect(sample: (Float) -> Unit) {
    if (!running || pending.none { it }) return
    var count = 0
    try {
      ensureArmed()
      val check = checking()
      if (check) drainErrors()
      for (slot in 0 until SLOTS) {
        if (!pending[slot]) continue
        if (!gl.resultAvailable(ids[slot])) continue
        results[count++] = gl.result(ids[slot])
        pending[slot] = false
      }
      val disjoint = gl.disjoint()
      if (check) {
        val error = gl.error()
        if (error != NO_ERROR) {
          turnOff("query result ${describe(error)}")
          return
        }
      }
      if (disjoint) {
        count = 0
        pending.fill(false)
      }
    } catch (e: RuntimeException) {
      turnOff("query result threw $e")
      return
    }
    for (index in 0 until count) sample(results[index] / NANOS_PER_MILLISECOND)
  }

  /** Forgets the pending results without reading them: the window surface changed (GL thread) */
  fun voidPending() {
    pending.fill(false)
  }

  /**
   * Before render targets are deleted inside a frame: ends the active query, waits for the GPU (glFinish) and voids
   * the pending results, so that no query read later depends on a deleted framebuffer. Nothing to do when no query
   * is active or pending.
   */
  fun settleBeforeDelete() {
    if (!running) return
    val slot = activeSlot
    if (slot < 0 && pending.none { it }) return
    activeSlot = -1
    try {
      if (slot >= 0) gl.endQuery()
      gl.finish()
    } catch (e: RuntimeException) {
      turnOff("settling the queries threw $e")
      return
    }
    voidPending()
  }

  /** The context is gone with its names: drops them without deleting anything. The guard stays as it is. */
  fun forget() {
    running = false
    hasNames = false
    ids.fill(0)
    pending.fill(false)
    activeSlot = -1
    nextSlot = 0
    timedFrames = 0
    timing = cpu(NOT_STARTED)
  }

  /** Deletes the queries (the context current) and disarms the guard: no timed frame follows */
  fun release() {
    val slot = activeSlot
    try {
      if (slot >= 0) gl.endQuery()
      if (hasNames) gl.deleteQueries(ids)
    } catch (e: RuntimeException) {
      // The names go with the context
    }
    forget()
    onPaused()
  }

  /** The GL thread is parked (activity stopped) or the renderer released: disarms the guard until the next query */
  fun onPaused() {
    if (armedKey == null) return
    armedKey = null
    try {
      guard?.disarm()
    } catch (e: RuntimeException) {
      log("GPU timer guard not disarmed: $e")
    }
  }

  private fun checking(): Boolean = timedFrames <= CHECKED_FRAMES

  private fun ensureArmed() {
    if (armedKey == driverKey) return
    guard?.arm(driverKey)
    armedKey = driverKey
  }

  /** Stops the queries for this context: ends the active one, deletes the names, one log line */
  private fun turnOff(reason: String) {
    val slot = activeSlot
    running = false
    activeSlot = -1
    pending.fill(false)
    timing = cpu("GPU timer failed")
    try {
      if (slot >= 0) gl.endQuery()
      if (hasNames) gl.deleteQueries(ids)
      // The renderer's own error checks must not see the errors of the queries
      drainErrors()
    } catch (e: RuntimeException) {
      // The names go with the context
    }
    hasNames = false
    ids.fill(0)
    log("GPU timer queries off for this GL context, timing on the CPU: $reason")
  }

  /** Discards the pending GL errors, so that the next check only sees those of the query calls */
  private fun drainErrors() {
    repeat(MAX_ERRORS_DRAINED) {
      if (gl.error() == NO_ERROR) return
    }
  }

  private fun describe(error: Int): String =
    if (error == NO_ERROR) "gave a zero name" else "gave GL error 0x${Integer.toHexString(error)}"
}
