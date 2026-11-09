package app.alextran.immich

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * A native buffer malloc did not give: the address 0 handed to NativeBuffer.wrap aborted the process (a SIGABRT of
 * CheckJNI or of NewDirectByteBuffer), where an OutOfMemoryError lets the decoders retry at half the size
 */
class NativeAllocationTest {
  @Test
  fun `an address is given back as it is and nothing is released`() {
    var released = false
    assertEquals(0x7a00001000L, checkAllocated(0x7a00001000L, 4096) { released = true })
    assertTrue(!released)
  }

  @Test
  fun `no address is an OutOfMemoryError after the release`() {
    var released = false
    try {
      checkAllocated(0L, 1L shl 30) { released = true }
      fail("no OutOfMemoryError")
    } catch (error: OutOfMemoryError) {
      assertEquals("No native memory for a buffer of 1073741824 bytes", error.message)
    }
    assertTrue("the bitmap is recycled before the error", released)
  }
}
