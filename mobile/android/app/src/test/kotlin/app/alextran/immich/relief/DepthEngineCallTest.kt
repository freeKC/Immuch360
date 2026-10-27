package app.alextran.immich.relief

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * What a call into the native engine may throw becomes a DepthEstimatorException, so that the parity check falls back
 * to the CPU and closes what it opened whatever the engine threw (LiteRtException is a checked Exception of LiteRT;
 * its Java layer may also throw a RuntimeException, and a native library may be missing)
 */
class DepthEngineCallTest {
  private fun failureOf(thrown: Throwable, failure: DepthFailure = DepthFailure.OPEN_FAILED): DepthEstimatorException {
    try {
      engineCall(failure, DepthPath.GPU, "LiteRT would not load the model") { throw thrown }
    } catch (e: DepthEstimatorException) {
      return e
    }
    fail("nothing thrown")
    throw AssertionError()
  }

  @Test
  fun `the value of the call is given back`() {
    assertEquals(42, engineCall(DepthFailure.RUN_FAILED, DepthPath.CPU, "the pass") { 42 })
  }

  @Test
  fun `an exception of the engine becomes the failure asked, with the path, the reason and the cause`() {
    val cause = IOException("ERROR: [compiled_model.cc:120] Failed to compile model")
    val e = failureOf(cause)
    assertEquals(DepthFailure.OPEN_FAILED, e.failure)
    assertEquals(DepthPath.GPU, e.path)
    assertSame(cause, e.cause)
    assertTrue(e.message, e.message!!.startsWith("LiteRT would not load the model on GPU: "))
    assertTrue(e.message, e.message!!.contains("Failed to compile model"))
  }

  @Test
  fun `a runtime exception of its Java layer becomes the failure too`() {
    val e = failureOf(IllegalStateException("no current EGL context"), DepthFailure.RUN_FAILED)
    assertEquals(DepthFailure.RUN_FAILED, e.failure)
    assertTrue(e.message, e.message!!.contains("no current EGL context"))
  }

  @Test
  fun `an exception without a message is named by its class`() {
    val e = failureOf(NullPointerException())
    assertTrue(e.message, e.message!!.contains("NullPointerException"))
  }

  @Test
  fun `a native library missing or refused becomes the failure too`() {
    val e = failureOf(UnsatisfiedLinkError("dlopen failed: library \"libLiteRt.so\" not found"))
    assertEquals(DepthFailure.OPEN_FAILED, e.failure)
    assertTrue(e.message, e.message!!.contains("libLiteRt.so"))
  }

  @Test
  fun `a depth failure goes through as it is`() {
    val wrongModel = DepthEstimatorException(DepthFailure.WRONG_MODEL, DepthPath.GPU, "the input is FLOAT [1, 3]")
    assertSame(wrongModel, failureOf(wrongModel))
  }

  @Test
  fun `an error of the virtual machine is not hidden`() {
    try {
      engineCall(DepthFailure.RUN_FAILED, DepthPath.CPU, "the pass") { throw OutOfMemoryError("Java heap space") }
      fail()
    } catch (expected: OutOfMemoryError) {}
  }
}
