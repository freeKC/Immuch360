package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StreamRetryTest {
  @Test
  fun `a link that sends nothing is tried again after 1, 2 and 4 s, then every 5 s, never given up within 10 min`() {
    assertEquals(1_000L, StreamRetry.delayMs(1, 8_000L, fatal = false))
    assertEquals(2_000L, StreamRetry.delayMs(2, 17_000L, fatal = false))
    assertEquals(4_000L, StreamRetry.delayMs(3, 27_000L, fatal = false))
    // Media3 stopped the video here (R8 of 31 October: a fatal source error 35 s after the last byte)
    assertEquals(5_000L, StreamRetry.delayMs(4, 35_000L, fatal = false))
    assertEquals(5_000L, StreamRetry.delayMs(60, 9L * 60_000L, fatal = false))
  }

  @Test
  fun `ten minutes without a byte, or an error Media3 never tries again, stop the tries`() {
    assertNull(StreamRetry.delayMs(70, StreamRetry.GIVE_UP_MS, fatal = false))
    assertNull(StreamRetry.delayMs(1, 0L, fatal = true))
  }

  @Test
  fun `a server that answers with an error is believed, a refusal at once, other errors after three tries`() {
    assertNull(StreamRetry.delayMs(1, 0L, fatal = false, httpStatus = 404))
    assertNull(StreamRetry.delayMs(1, 0L, fatal = false, httpStatus = 401))
    assertEquals(1_000L, StreamRetry.delayMs(1, 0L, fatal = false, httpStatus = 503))
    assertEquals(4_000L, StreamRetry.delayMs(3, 0L, fatal = false, httpStatus = 500))
    assertNull(StreamRetry.delayMs(4, 0L, fatal = false, httpStatus = 500))
    assertEquals(1_000L, StreamRetry.delayMs(1, 0L, fatal = false, httpStatus = 429))
  }
}
