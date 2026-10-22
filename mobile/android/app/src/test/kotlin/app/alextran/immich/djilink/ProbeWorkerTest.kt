package app.alextran.immich.djilink

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The probe thread across page sessions. The link's owner lives as long as the process and the page opens and closes
 * many times; a second visit with the remote plugged in must probe again, and a page closed while a probe waits must
 * not leave an exception on a thread nobody catches, which on Android ends the application.
 */
class ProbeWorkerTest {
  private fun runs(worker: ProbeWorker): Boolean {
    val ran = CountDownLatch(1)
    return worker.submit { ran.countDown() } && ran.await(2, TimeUnit.SECONDS)
  }

  @Test
  fun aSecondSessionProbesAgain() {
    val worker = ProbeWorker()
    worker.open()
    assertTrue(runs(worker))
    worker.close()
    // The page reopened: the same owner, a new thread
    worker.open()
    assertTrue(worker.isOpen)
    assertTrue(runs(worker))
    worker.close()
  }

  @Test
  fun workHandedInWhileClosedIsRefusedWithoutAnException() {
    val worker = ProbeWorker()
    assertFalse(worker.submit {})
    worker.open()
    worker.close()
    assertFalse(worker.isOpen)
    assertFalse(worker.submit {})
  }

  @Test
  fun closingWhileAProbeWaitsLeavesNoUncaughtException() {
    val uncaught = AtomicReference<Throwable?>(null)
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { _, error -> uncaught.set(error) }
    try {
      val worker = ProbeWorker()
      worker.open()
      val waiting = CountDownLatch(1)
      worker.submit {
        waiting.countDown()
        // A probe waiting for its write: interrupted by the close below
        Thread.sleep(10_000)
      }
      assertTrue(waiting.await(2, TimeUnit.SECONDS))
      worker.close()
      Thread.sleep(300)
      assertEquals(null, uncaught.get())
    } finally {
      Thread.setDefaultUncaughtExceptionHandler(previous)
    }
  }

  @Test
  fun anExceptionInsideTheTaskStaysOnTheThread() {
    val worker = ProbeWorker()
    worker.open()
    assertTrue(worker.submit { throw IllegalStateException("a probe that failed") })
    // The same thread still takes work afterwards
    assertTrue(runs(worker))
    worker.close()
  }
}
