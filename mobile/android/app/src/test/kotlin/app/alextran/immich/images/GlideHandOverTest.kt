package app.alextran.immich.images

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

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

  @Test
  fun `a cancel while Glide decodes clears the request`() {
    val cancel = FakeCancel()
    var clears = 0
    assertThrows(IllegalStateException::class.java) {
      GlideHandOver.take(cancel, clear = { clears++ }) {
        cancel.cancel()
        throw IllegalStateException("cancelled by the clear")
      }
    }
    assertEquals(1, clears)
  }

  @Test
  fun `a cancel after Glide answered never frees the bitmap the caller reads`() {
    val cancel = FakeCancel()
    val pixels = Pixels()
    val taken = GlideHandOver.take(cancel, clear = { pixels.freed = true }) { pixels }
    assertSame(pixels, taken)
    // The request is cancelled while the caller copies the pixels: the clear Glide would answer with a recycle of
    // the bitmap (BitmapPoolAdapter.put) must not run any more
    cancel.cancel()
    assertEquals(false, pixels.freed)
  }

  @Test
  fun `a cancel between the answer and the hand over leaves the bitmap to Glide`() {
    val cancel = FakeCancel()
    val pixels = Pixels()
    val taken = GlideHandOver.take(cancel, clear = { pixels.freed = true }) {
      cancel.cancel()
      pixels
    }
    // Glide cleared the request and frees the bitmap itself: the caller gets nothing to read
    assertNull(taken)
    assertEquals(true, pixels.freed)
    assertNull(cancel.listener)
  }

  @Test
  fun `a request cancelled before it starts never reaches Glide`() {
    val cancel = FakeCancel()
    cancel.cancel()
    var asked = false
    var clears = 0
    val taken = GlideHandOver.take(cancel, clear = { clears++ }) {
      asked = true
      Pixels()
    }
    assertNull(taken)
    assertEquals(false, asked)
    assertEquals(0, clears)
  }
}
