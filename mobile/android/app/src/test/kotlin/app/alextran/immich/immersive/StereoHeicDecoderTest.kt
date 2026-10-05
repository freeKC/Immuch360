package app.alextran.immich.immersive

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

/** The pitm patch that makes the platform decode the right eye (section 5.7 of the design). */
class StereoHeicDecoderTest {
  private fun spec(primary: Int, offset: Int, bytes: Int, left: Int = primary, right: Int = 74) =
    StereoPairSpec(
      primaryItemId = primary,
      leftItemId = left,
      rightItemId = right,
      pitmIdOffset = offset,
      pitmIdBytes = bytes,
      width = 3072,
      height = 3072,
      rotation = 0,
      disparityAdjustment = 0,
      horizontalFovDeg = null,
    )

  /** 200 bytes of a pretend file, the item id [primary] in [bytes] bytes at [offset] */
  private fun file(primary: Int, offset: Int, bytes: Int): ByteArray {
    val data = ByteArray(200) { (it * 7).toByte() }
    for (i in 0 until bytes) data[offset + i] = (primary ushr (8 * (bytes - 1 - i))).toByte()
    return data
  }

  @Test
  fun `patches the 2 byte item id of a pitm of version 0`() {
    val original = file(37, 129, 2)
    val patched = StereoHeicDecoder.withPrimary(original, spec(37, 129, 2), 74)

    assertEquals(0, patched[129].toInt())
    assertEquals(74, patched[130].toInt())
    // Nothing else changes, and the file itself stays as it was
    val expected = original.copyOf().also { it[130] = 74 }
    assertArrayEquals(expected, patched)
    assertEquals(37, original[130].toInt())
  }

  @Test
  fun `patches the 4 byte item id of a pitm of version 1`() {
    val original = file(0x10025, 60, 4)
    val patched = StereoHeicDecoder.withPrimary(original, spec(0x10025, 60, 4), 0x20031)

    assertEquals(listOf(0, 2, 0, 0x31), (60 until 64).map { patched[it].toInt() and 0xFF })
    assertEquals(original.size, patched.size)
  }

  @Test
  fun `gives the file itself for the primary item`() {
    val original = file(37, 129, 2)

    assertSame(original, StereoHeicDecoder.withPrimary(original, spec(37, 129, 2), 37))
  }

  @Test
  fun `refuses a file whose pitm does not hold the primary item`() {
    val other = file(12, 129, 2)

    assertThrows(IllegalArgumentException::class.java) {
      StereoHeicDecoder.withPrimary(other, spec(37, 129, 2), 74)
    }
    // Even for the primary item itself: it is not the file Flutter read
    assertThrows(IllegalArgumentException::class.java) {
      StereoHeicDecoder.withPrimary(other, spec(37, 129, 2), 37)
    }
  }

  @Test
  fun `refuses an offset past the file and an item that does not fit`() {
    assertThrows(IllegalArgumentException::class.java) {
      StereoHeicDecoder.withPrimary(file(37, 129, 2), spec(37, 199, 2), 74)
    }
    assertThrows(IllegalArgumentException::class.java) {
      StereoHeicDecoder.withPrimary(file(37, 129, 2), spec(37, 129, 2), 0x10000)
    }
  }
}
