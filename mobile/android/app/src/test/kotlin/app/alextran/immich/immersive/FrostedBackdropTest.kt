package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The frosted background behind the photo of a flat screen (issue 19, experimental). */
class FrostedBackdropTest {
  @Test
  fun `the blur of a single white pixel spreads and keeps its energy`() {
    val width = 32
    val height = 32
    val values = FloatArray(width * height)
    values[16 * width + 16] = 255f
    FrostedBackdrop.blur(values, width, height)
    assertEquals(255f, values.sum(), 1e-2f)
    val spread = values.count { it > 0f }
    // Three passes of a box of 5: a square of 13 x 13 around the pixel
    assertEquals(13 * 13, spread)
    assertTrue(values[16 * width + 16] < 255f / 10)
  }

  @Test
  fun `the veil halves a grey, and a flat colour keeps its hue at 0_8 of its saturation`() {
    val grey = 0xFF808080.toInt()
    val frosted = FrostedBackdrop.frost(IntArray(4 * 4) { grey }, 4, 4)
    for (pixel in frosted) {
      assertEquals(0xFF, (pixel ushr 24) and 0xFF)
      assertEquals(64, (pixel shr 16) and 0xFF)
      assertEquals(64, (pixel shr 8) and 0xFF)
      assertEquals(64, pixel and 0xFF)
    }
    val (r, g, b) = FrostedBackdrop.saturate(200f, 100f, 0f)
    val level = 0.299f * 200f + 0.587f * 100f
    assertEquals(level + (200f - level) * 0.8f, r, 1e-3f)
    assertEquals(level + (100f - level) * 0.8f, g, 1e-3f)
    assertEquals(level * 0.2f, b, 1e-3f)
  }

  @Test
  fun `the backdrop is the box plus 6 percent a side, the small copy 64 pixels wide`() {
    val (width, height) = FrostedBackdrop.size(2f, 1f)
    assertEquals(2.24f, width, 1e-5f)
    assertEquals(1.12f, height, 1e-5f)
    assertEquals(64 to 43, FrostedBackdrop.smallSize(3000, 2000))
    assertEquals(64 to 96, FrostedBackdrop.smallSize(2000, 3000))
    assertEquals(64 to 1, FrostedBackdrop.smallSize(10000, 10))
  }
}
