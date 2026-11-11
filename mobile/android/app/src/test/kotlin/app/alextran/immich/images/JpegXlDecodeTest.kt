package app.alextran.immich.images

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The parts of JpegXlDecode that need no native library: which bytes go to the Rust core (the signatures the Dart
 * probe of encoded_image_probe.dart reads too), and the long side the core is given for a decode within a box
 * (NativeImageDecodeApi, the Quest viewers), never above MAX_PIXEL_SIZE.
 */
class JpegXlDecodeTest {
  private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

  private val container =
    bytes(0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A, 0x00, 0x00, 0x00, 0x14)

  @Test
  fun `a bare codestream and the container are JPEG XL`() {
    assertTrue(JpegXlDecode.isJpegXl(bytes(0xFF, 0x0A, 0xFA, 0x7F)))
    assertTrue(JpegXlDecode.isJpegXl(container))
  }

  @Test
  fun `other images and short heads are not`() {
    assertFalse(JpegXlDecode.isJpegXl(bytes(0xFF, 0xD8, 0xFF, 0xE0)))
    assertFalse(JpegXlDecode.isJpegXl(bytes(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)))
    assertFalse(JpegXlDecode.isJpegXl(bytes(0xFF)))
    assertFalse(JpegXlDecode.isJpegXl(ByteArray(0)))
    // The container cut before its last byte, and a head shorter than the bytes it holds
    assertFalse(JpegXlDecode.isJpegXl(container.copyOf(11)))
    assertFalse(JpegXlDecode.isJpegXl(container, 8))
  }

  @Test
  fun `the long side is the larger bound, at most MAX_PIXEL_SIZE`() {
    assertEquals(360, JpegXlDecode.longSide(360, 360))
    assertEquals(2400, JpegXlDecode.longSide(1080, 2400))
    assertEquals(MAX_PIXEL_SIZE, JpegXlDecode.longSide(0, 0))
    assertEquals(MAX_PIXEL_SIZE, JpegXlDecode.longSide(-1, 0))
    assertEquals(MAX_PIXEL_SIZE, JpegXlDecode.longSide(40000, 20000))
    assertEquals(8192, JpegXlDecode.longSide(0, 8192))
  }

  @Test
  fun `the retry gives half the long side, never 0`() {
    assertEquals(4096, JpegXlDecode.longSide(8192, 4096, 0.5))
    assertEquals(MAX_PIXEL_SIZE / 2, JpegXlDecode.longSide(0, 0, 0.5))
    assertEquals(1, JpegXlDecode.longSide(1, 1, 0.5))
  }

  @Test
  fun `a picture fits a box on both sides, a side without a bound always`() {
    assertTrue(JpegXlDecode.fitsWithin(720, 480, 1000, 1000))
    assertTrue(JpegXlDecode.fitsWithin(360, 240, 360, 360))
    assertFalse(JpegXlDecode.fitsWithin(2400, 1800, 1080, 2400))
    assertTrue(JpegXlDecode.fitsWithin(20000, 10, 0, 16))
    assertFalse(JpegXlDecode.fitsWithin(20, 10, 0, 8))
  }
}
