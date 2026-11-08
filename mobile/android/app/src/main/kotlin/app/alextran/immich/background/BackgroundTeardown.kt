package app.alextran.immich.background

import java.util.concurrent.atomic.AtomicBoolean

/**
 * The background engine of the process: a worker takes it before it starts an engine and gives it back once that engine
 * is destroyed, so that a new worker does not start a second engine while the Dart of the previous one may still be
 * closing its databases.
 */
class BackgroundEngineSlot {
  private val held = AtomicBoolean(false)

  /** Takes the slot; false while the engine of an earlier run is still alive */
  fun tryAcquire(): Boolean = held.compareAndSet(false, true)

  fun release() {
    held.set(false)
  }

  val isHeld: Boolean
    get() = held.get()
}

/**
 * The end of one background worker run, in order. Two things end apart: the WorkManager work, whose result must come
 * within a few seconds of a stop, and the Flutter engine, which must outlive the Dart cleanup. Destroying the engine
 * shuts its isolate down, whose native finalizers then release the database connections it still holds, possibly
 * under statements still running on them.
 *
 * - [complete]: the run ended by itself, Dart cleaned up before it returned its result: the work is finished and the
 *   engine destroyed at once.
 * - [cancel]: the run must stop. Before the engine exists there is nothing to wait for. After, the caller asks Dart to
 *   cancel, whose answer comes once its cleanup is done; the work is finished on that answer or after [finishDelayMs],
 *   whichever comes first, and the engine is destroyed on that answer ([dartAnswered]), or after [destroyCapMs] when
 *   it never comes.
 *
 * finishWork and destroyEngine each run once, in that order. Every call comes from one thread (the main thread in the
 * app) and [schedule] runs its actions on that thread too. No Android type is used, so that the order is tested on the
 * JVM; [R] is the result of the work.
 */
class BackgroundTeardown<R : Any>(
  private val slot: BackgroundEngineSlot,
  private val schedule: (delayMs: Long, action: () -> Unit) -> Unit,
  private val finishWork: (R) -> Unit,
  private val destroyEngine: () -> Unit,
  private val finishDelayMs: Long = FINISH_DELAY_MS,
  private val destroyCapMs: Long = DESTROY_CAP_MS,
) {
  companion object {
    /** How long WorkManager waits for the result of a stopped work */
    const val FINISH_DELAY_MS = 5_000L

    /** How long the engine waits for the answer of Dart to a cancel */
    const val DESTROY_CAP_MS = 60_000L
  }

  private var holdsSlot = false
  private var engineStarted = false
  private var cancelResult: R? = null

  /** A stop or the end was asked: no engine is created any more and no work is started */
  var isEnding = false
    private set

  var isWorkFinished = false
    private set

  var isEngineDestroyed = false
    private set

  /** Takes the engine slot for this run; false while the engine of an earlier run is still alive */
  fun tryStart(): Boolean {
    check(!holdsSlot) { "This run has already started" }
    holdsSlot = slot.tryAcquire()
    return holdsSlot
  }

  /** The engine exists: from now on its Dart may hold databases, so a stop waits for its answer */
  fun engineStarted() {
    engineStarted = true
  }

  /** The run ended by itself with [result], after the cleanup of Dart */
  fun complete(result: R) {
    isEnding = true
    finish(result)
    destroy()
  }

  /**
   * The run must stop with [result]. True when the caller must now ask Dart to cancel: the first stop of a run whose
   * engine exists. False when there is nothing to ask: a stop already asked, or no engine yet, and then the run has
   * ended at once.
   */
  fun cancel(result: R): Boolean {
    if (isEnding) {
      return false
    }
    isEnding = true
    if (!engineStarted) {
      finish(result)
      destroy()
      return false
    }
    cancelResult = result
    schedule(finishDelayMs) { finish(result) }
    schedule(destroyCapMs) { destroy() }
    return true
  }

  /** Dart answered the cancel: its cleanup is done, or it failed and no better answer will come */
  fun dartAnswered() {
    val result = cancelResult ?: return
    finish(result)
    destroy()
  }

  private fun finish(result: R) {
    if (isWorkFinished) {
      return
    }
    isWorkFinished = true
    finishWork(result)
  }

  private fun destroy() {
    if (isEngineDestroyed) {
      return
    }
    isEngineDestroyed = true
    try {
      destroyEngine()
    } finally {
      if (holdsSlot) {
        holdsSlot = false
        slot.release()
      }
    }
  }
}
