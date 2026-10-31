package app.alextran.immich.images

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class EncodedImageReadsTest {
  private val megabyte = 1L shl 20

  @Test
  fun `the limit is a sixteenth of the memory, between 64 and 512 MB`() {
    assertEquals(128 * megabyte, EncodedImageReads.limitFor(2048 * megabyte))
    assertEquals(256 * megabyte, EncodedImageReads.limitFor(4096 * megabyte))
    assertEquals(512 * megabyte, EncodedImageReads.limitFor(8192 * megabyte))
    assertEquals(512 * megabyte, EncodedImageReads.limitFor(16384 * megabyte))
    assertEquals(64 * megabyte, EncodedImageReads.limitFor(512 * megabyte))
  }

  @Test
  fun `a file larger than the limit is refused before it is read`() {
    EncodedImageReads.checkLength(100, 100)
    assertThrows(EncodedImageTooLargeException::class.java) { EncodedImageReads.checkLength(101, 100) }
  }

  @Test
  fun `reads the whole stream into the buffer, in as many reads as it takes`() {
    val bytes = ByteArray(10_000) { (it * 7).toByte() }
    // A stream that gives at most 1000 bytes per read, as a provider may
    val slow = object : InputStream() {
      private val source = ByteArrayInputStream(bytes)
      override fun read(): Int = source.read()
      override fun read(b: ByteArray, off: Int, len: Int): Int = source.read(b, off, minOf(len, 1000))
    }
    val buffer = ByteBuffer.allocateDirect(bytes.size)
    var checks = 0
    assertEquals(bytes.size, EncodedImageReads.readFully(slow, buffer) { checks++ })
    val read = ByteArray(bytes.size)
    buffer.flip()
    buffer.get(read)
    assertArrayEquals(bytes, read)
    assertEquals(true, checks >= 10)
  }

  @Test
  fun `a stream shorter than the buffer gives what it has`() {
    val buffer = ByteBuffer.allocateDirect(100)
    assertEquals(40, EncodedImageReads.readFully(ByteArrayInputStream(ByteArray(40)), buffer) {})
  }

  @Test
  fun `a cancel stops the reading`() {
    val buffer = ByteBuffer.allocateDirect(100)
    assertThrows(IllegalStateException::class.java) {
      EncodedImageReads.readFully(ByteArrayInputStream(ByteArray(100)), buffer) { throw IllegalStateException("cancelled") }
    }
  }
}
