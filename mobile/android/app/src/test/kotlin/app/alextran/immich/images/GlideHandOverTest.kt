package app.alextran.immich.images

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class GlideHandOverTest {
  /** A cancellation signal as Android's behaves: the listener set when the cancel comes is run once, at that time */
  private class FakeCancel : GlideHandOver.Cancel {
    var listener: (() -> Unit)? = null
    override var isCanceled = false
      private set

    override fun onCancel(action: (() -> Unit)?) {
      listener = action
      if (isCanceled) action?.invoke()
    }

    fun cancel() {
      if (isCanceled) return
      isCanceled = true
      listener?.invoke()
    }
  }

  private class Pixels {
    var freed = false
  }

  /**
   * The future Glide's submit gives, as RequestFutureTarget of Glide 4.16 behaves: get() waits with no time limit until
   * the answer, a failure or cancel() wakes it (a clear of its request through Glide.with(ctx).clear never does: its
   * onLoadCleared is empty). cancel() after the answer returns false and clears nothing; before it, it wakes get(),
   * which throws CancellationException, and with true it clears the request, which frees the bitmap when there is one.
   */
  private class FakeGlideFuture(private val pixels: Pixels? = null) : Future<Pixels> {
    private var answer: Pixels? = null
    private var cancelled = false
    var requestCleared = 0
      private set
    val waiting = CountDownLatch(1)

    /** Run in get() once the answer is there, before it returns it */
    var onAnswer: (() -> Unit)? = null

    fun answer(value: Pixels) = synchronized(this) {
      answer = value
      (this as Object).notifyAll()
    }

    override fun cancel(mayInterruptIfRunning: Boolean): Boolean {
      synchronized(this) {
        if (isDone) return false
        cancelled = true
        (this as Object).notifyAll()
      }
      if (mayInterruptIfRunning) requestCleared++
      return true
    }

    override fun isCancelled() = synchronized(this) { cancelled }

    override fun isDone() = synchronized(this) { cancelled || answer != null }

    override fun get(): Pixels {
      val value =
        synchronized(this) {
          if (pixels != null && answer == null && !cancelled) answer = pixels
          if (cancelled) throw CancellationException()
          if (answer == null) {
            waiting.countDown()
            (this as Object).wait(0)
          }
          if (cancelled) throw CancellationException()
          answer ?: throw TimeoutException()
        }
      onAnswer?.invoke()
      return value
    }

    override fun get(timeout: Long, unit: TimeUnit) = throw UnsupportedOperationException()
  }

  @Test
  fun `a cancel while Glide decodes wakes the caller and clears the request`() {
    val cancel = FakeCancel()
    val future = FakeGlideFuture()
    val released = mutableListOf<Pixels>()
    var thrown: Throwable? = null
    var taken: Pixels? = null
    val worker = Thread {
      try {
        taken = GlideHandOver.take(cancel, future) { released.add(it) }
      } catch (e: Throwable) {
        thrown = e
      }
    }
    // A daemon: should the cancel leave it waiting, the test still ends
    worker.isDaemon = true
    worker.start()
    assertTrue("the worker never waited on Glide", future.waiting.await(5, TimeUnit.SECONDS))
    cancel.cancel()
    worker.join(5000)
    // A worker of the pool left waiting for good would stop every local image after a few cancels
    assertFalse("the cancel left the worker waiting on Glide", worker.isAlive)
    assertTrue("got $thrown", thrown is CancellationException)
    assertNull(taken)
    assertEquals(1, future.requestCleared)
    assertEquals(emptyList<Pixels>(), released)
  }

  @Test
  fun `a cancel after Glide answered never frees the bitmap the caller reads`() {
    val cancel = FakeCancel()
    val pixels = Pixels()
    val future = FakeGlideFuture(pixels)
    val taken = GlideHandOver.take(cancel, future) { it.freed = true }
    assertSame(pixels, taken)
    // The request is cancelled while the caller copies the pixels: neither the request's clear (a recycle of the
    // bitmap, BitmapPoolAdapter.put) nor the release may run any more
    cancel.cancel()
    assertEquals(false, pixels.freed)
    assertEquals(0, future.requestCleared)
    assertNull(cancel.listener)
  }

  @Test
  fun `a cancel between the answer and the hand over releases the bitmap once, with no clear`() {
    val cancel = FakeCancel()
    val pixels = Pixels()
    val future = FakeGlideFuture(pixels)
    future.onAnswer = { cancel.cancel() }
    var releases = 0
    val taken = GlideHandOver.take(cancel, future) {
      releases++
      it.freed = true
    }
    // Glide answered, so its cancel clears nothing: the caller gets nothing to read and frees the bitmap itself
    assertNull(taken)
    assertEquals(1, releases)
    assertEquals(true, pixels.freed)
    assertEquals(0, future.requestCleared)
    assertNull(cancel.listener)
  }

  @Test
  fun `a request cancelled before the hand over cancels the Glide request and reads nothing`() {
    val cancel = FakeCancel()
    cancel.cancel()
    val future = FakeGlideFuture()
    var released = 0
    val taken = GlideHandOver.take(cancel, future) { released++ }
    assertNull(taken)
    assertTrue(future.isCancelled)
    assertEquals(1, future.requestCleared)
    assertEquals(0, released)
  }

  @Test
  fun `a failed decode reaches the caller as it is`() {
    val cancel = FakeCancel()
    val failing =
      object : Future<Pixels> by FakeGlideFuture() {
        override fun get(): Pixels = throw ExecutionException(IllegalStateException("no decoder"))
      }
    var thrown: Throwable? = null
    try {
      GlideHandOver.take(cancel, failing) {}
    } catch (e: Throwable) {
      thrown = e
    }
    assertTrue("got $thrown", thrown is ExecutionException)
    assertNull(cancel.listener)
  }
}
