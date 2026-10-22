package app.alextran.immich.djilink

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * The one thread the liveness probe runs on. The probe is one blocking call on purpose, and its duration is the
 * measurement, so it never runs on the main thread.
 *
 * The thread belongs to one page session: [open] when the page starts, [close] when it stops, and the next session gets
 * a new thread, because the link's owner outlives the page and a closed executor never takes work again. Work handed
 * in while closed is refused with false rather than an exception, since the probe tick on the main thread can fire
 * just after the page closed. And no exception ever leaves the thread: on Android an uncaught one ends the whole
 * application, and [close] interrupts a probe that is still waiting.
 */
class ProbeWorker(private val threadName: String = "DjiLinkProbe") {
  private var executor: ExecutorService? = null

  val isOpen: Boolean
    @Synchronized get() = executor != null

  @Synchronized
  fun open() {
    if (executor == null) {
      executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, threadName).apply { isDaemon = true } }
    }
  }

  @Synchronized
  fun close() {
    executor?.shutdownNow()
    executor = null
  }

  /** Runs [task] on the probe thread; false when the worker is closed */
  @Synchronized
  fun submit(task: () -> Unit): Boolean {
    val current = executor ?: return false
    return try {
      current.execute { runCatching(task) }
      true
    } catch (rejected: RejectedExecutionException) {
      false
    }
  }
}
