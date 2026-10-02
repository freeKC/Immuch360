package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Test

class StreamingLoadControlTest {
  private val mib = 1024L * 1024L

  @Test
  fun `takes half of the heap`() {
    assertEquals((256 * mib).toInt(), StreamingLoadControl.targetBufferBytes(512 * mib))
  }

  @Test
  fun `never takes less than the Media3 default`() {
    assertEquals(StreamingLoadControl.MIN_TARGET_BUFFER_BYTES, StreamingLoadControl.targetBufferBytes(192 * mib))
  }

  @Test
  fun `never takes more than the maximum`() {
    assertEquals(StreamingLoadControl.MAX_TARGET_BUFFER_BYTES, StreamingLoadControl.targetBufferBytes(4096 * mib))
  }
}
