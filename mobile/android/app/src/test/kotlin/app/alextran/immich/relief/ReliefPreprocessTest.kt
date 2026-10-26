package app.alextran.immich.relief

import app.alextran.immich.relief.ReliefPreprocess.INPUT_HEIGHT
import app.alextran.immich.relief.ReliefPreprocess.INPUT_WIDTH
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The input of the depth model made from a photo (design 2.3, point 5, and 3.4, point 4): 686 x 518, stretched when the
 * photo is 1.0 to 1.9 times as wide as high, otherwise fitted and centred on its mean colour; area average, then the
 * ImageNet normalisation, NCHW in float32. And the depth map of the model cut back to the photo.
 */
class ReliefPreprocessTest {
  private val plane = INPUT_WIDTH * INPUT_HEIGHT

  @Test
  fun `the input is the fixed one of the model`() {
    assertEquals(686, INPUT_WIDTH)
    assertEquals(518, INPUT_HEIGHT)
    assertEquals(3 * 686 * 518, ReliefPreprocess.TENSOR_SIZE)
  }

  @Test
  fun `a photo 1 to 19 tenths as wide as high is stretched to the whole input`() {
    for ((w, h) in listOf(1372 to 1036, 1000 to 1000, 1900 to 1000, 4000 to 3000, 4032 to 2268, 343 to 259)) {
      val frame = ReliefPreprocess.frameFor(w, h)
      assertEquals("$w x $h", ReliefFrame(0, 0, INPUT_WIDTH, INPUT_HEIGHT), frame)
      assertTrue(frame.stretched)
    }
  }

  @Test
  fun `the bounds of the stretch are decided in integers`() {
    assertTrue(ReliefPreprocess.frameFor(19_000, 10_000).stretched)
    assertFalse(ReliefPreprocess.frameFor(19_001, 10_000).stretched)
    assertTrue(ReliefPreprocess.frameFor(10_000, 10_000).stretched)
    assertFalse(ReliefPreprocess.frameFor(9_999, 10_000).stretched)
  }

  @Test
  fun `the background is the mean of the photo itself`() {
    // 3 x 7, one bright pixel: the frame averages it with its neighbours, the background is 255 / 21 exactly as the
    // computers compute it (sum over the photo divided by its pixel count, in double)
    val photo = IntArray(3 * 7) { if (it == 10) argb(255, 255, 255) else argb(0, 0, 0) }
    val input = ReliefPreprocess.prepare(photo, 3, 7)
    assertFalse(input.frame.stretched)
    val expected = ((255.0 * input.frame.width / (input.frame.width * 21.0)) / 255.0 - 0.485) / 0.229
    assertEquals(expected.toFloat(), input.tensor[0], 0f)
  }

  @Test
  fun `a portrait or a flat panorama keeps its proportions, centred`() {
    assertEquals(ReliefFrame(148, 0, 389, 518), ReliefPreprocess.frameFor(3000, 4000))
    assertEquals(ReliefFrame(213, 0, 259, 518), ReliefPreprocess.frameFor(300, 600))
    assertEquals(ReliefFrame(0, 144, 686, 229), ReliefPreprocess.frameFor(1800, 600))
    assertEquals(ReliefFrame(0, 78, 686, 361), ReliefPreprocess.frameFor(1901, 1000))
    assertEquals(ReliefFrame(342, 0, 1, 518), ReliefPreprocess.frameFor(1, 1000))
    assertEquals(ReliefFrame(0, 258, 686, 1), ReliefPreprocess.frameFor(1000, 1))
    assertFalse(ReliefPreprocess.frameFor(3000, 4000).stretched)
  }

  @Test
  fun `each value is the ImageNet normalisation of its channel, plane after plane`() {
    val red = ReliefPreprocess.prepare(IntArray(800 * 600) { argb(255, 0, 0) }, 800, 600).tensor
    assertEquals(ReliefPreprocess.TENSOR_SIZE, red.size)
    assertEquals(((1.0 - 0.485) / 0.229).toFloat(), red[0], 1e-6f)
    assertEquals(((0.0 - 0.456) / 0.224).toFloat(), red[plane], 1e-6f)
    assertEquals(((0.0 - 0.406) / 0.225).toFloat(), red[2 * plane], 1e-6f)
    val colour = ReliefPreprocess.prepare(IntArray(800 * 600) { argb(10, 128, 240) }, 800, 600).tensor
    val expected = floatArrayOf(normalized(10.0, 0), normalized(128.0, 1), normalized(240.0, 2))
    for (i in colour.indices) assertEquals("value $i", expected[i / plane], colour[i], 0f)
  }

  @Test
  fun `the reduction is an average over the area of each pixel`() {
    val stripes = IntArray(1372 * 1036) { i -> if (i % 2 == 0) argb(0, 0, 0) else argb(255, 255, 255) }
    val tensor = ReliefPreprocess.prepare(stripes, 1372, 1036).tensor
    for (c in 0..2) {
      val value = normalized(127.5, c)
      for (i in 0 until plane) assertEquals(value, tensor[c * plane + i], 0f)
    }
    val halves = IntArray(1372 * 1036) { i -> if (i % 1372 < 686) argb(255, 0, 0) else argb(0, 0, 255) }
    val split = ReliefPreprocess.prepare(halves, 1372, 1036).tensor
    for (y in listOf(0, 200, INPUT_HEIGHT - 1)) {
      assertEquals(normalized(255.0, 0), split[y * INPUT_WIDTH + 342], 0f)
      assertEquals(normalized(0.0, 0), split[y * INPUT_WIDTH + 343], 0f)
      assertEquals(normalized(255.0, 2), split[2 * plane + y * INPUT_WIDTH + 343], 0f)
    }
  }

  @Test
  fun `a small photo is enlarged pixel by pixel`() {
    val checker = IntArray(343 * 259) { i -> if ((i % 343 + i / 343) % 2 == 0) argb(255, 255, 255) else argb(0, 0, 0) }
    val tensor = ReliefPreprocess.prepare(checker, 343, 259).tensor
    for (y in 0 until INPUT_HEIGHT step 37) {
      for (x in 0 until INPUT_WIDTH step 7) {
        val white = (x / 2 + y / 2) % 2 == 0
        assertEquals("$x, $y", normalized(if (white) 255.0 else 0.0, 1), tensor[plane + y * INPUT_WIDTH + x], 0f)
      }
    }
  }

  @Test
  fun `a fitted photo lies in its frame, on its mean colour`() {
    // 300 x 600, white above and black below: 259 x 518 in the middle, the border at the mean grey
    val photo = IntArray(300 * 600) { i -> if (i / 300 < 300) argb(255, 255, 255) else argb(0, 0, 0) }
    val input = ReliefPreprocess.prepare(photo, 300, 600)
    assertEquals(ReliefFrame(213, 0, 259, 518), input.frame)
    val tensor = input.tensor
    val grey = normalized(127.5, 0)
    assertEquals(grey, tensor[0], 0f)
    assertEquals(grey, tensor[212], 0f)
    assertEquals(grey, tensor[472], 0f)
    assertEquals(grey, tensor[(INPUT_HEIGHT - 1) * INPUT_WIDTH + 685], 0f)
    assertEquals(normalized(255.0, 0), tensor[213], 0f)
    assertEquals(normalized(255.0, 0), tensor[258 * INPUT_WIDTH + 471], 0f)
    assertEquals(normalized(0.0, 0), tensor[259 * INPUT_WIDTH + 213], 0f)
    // A flat panorama in the same colour all over: the band above and below takes that colour
    val panorama = ReliefPreprocess.prepare(IntArray(1800 * 600) { argb(30, 60, 90) }, 1800, 600)
    assertEquals(ReliefFrame(0, 144, 686, 229), panorama.frame)
    assertEquals(normalized(30.0, 0), panorama.tensor[0], 0f)
    assertEquals(normalized(90.0, 2), panorama.tensor[2 * plane + 517 * INPUT_WIDTH], 0f)
  }

  @Test
  fun `rows read one by one give the same input as the array, each row read once`() {
    val width = 900
    val height = 1300
    val photo = IntArray(width * height) { i -> argb((i * 7) % 256, (i / width) % 256, (i % width) % 256) }
    val whole = ReliefPreprocess.prepare(photo, width, height)
    val reads = IntArray(height)
    val streamed =
      ReliefPreprocess.prepare(width, height, { y, row ->
        reads[y]++
        photo.copyInto(row, 0, y * width, (y + 1) * width)
      })
    assertEquals(whole.frame, streamed.frame)
    assertArrayEquals(whole.tensor, streamed.tensor, 0f)
    assertTrue(reads.all { it == 1 })
  }

  @Test
  fun `the given buffer is filled and returned`() {
    val buffer = FloatArray(ReliefPreprocess.TENSOR_SIZE)
    val input = ReliefPreprocess.prepare(IntArray(4 * 3) { argb(1, 2, 3) }, 4, 3, buffer)
    assertTrue(input.tensor === buffer)
  }

  @Test(expected = IllegalArgumentException::class)
  fun `a buffer of another size is refused`() {
    ReliefPreprocess.prepare(IntArray(4 * 3), 4, 3, FloatArray(10))
  }

  @Test(expected = IllegalArgumentException::class)
  fun `an empty photo is refused`() {
    ReliefPreprocess.prepare(IntArray(0), 0, 3)
  }

  @Test
  fun `the depth map of the model is cut back to the photo`() {
    val output = FloatArray(INPUT_WIDTH * INPUT_HEIGHT) { i -> (i / INPUT_WIDTH * 1000 + i % INPUT_WIDTH).toFloat() }
    val frame = ReliefFrame(213, 0, 259, 518)
    val map = ReliefPreprocess.cropDepth(output, frame)
    assertEquals(259 * 518, map.size)
    assertEquals(213f, map[0])
    assertEquals(471f, map[258])
    assertEquals(1213f, map[259])
    assertEquals(517_471f, map[map.size - 1])
    val band = ReliefPreprocess.cropDepth(output, ReliefFrame(0, 144, 686, 229))
    assertEquals(144_000f, band[0])
    assertEquals(372_685f, band[band.size - 1])
    val whole = ReliefPreprocess.cropDepth(output, ReliefFrame(0, 0, INPUT_WIDTH, INPUT_HEIGHT))
    assertArrayEquals(output, whole, 0f)
    assertFalse("a copy, never the buffer of the model", whole === output)
  }

  private fun normalized(value: Double, channel: Int): Float {
    val mean = doubleArrayOf(0.485, 0.456, 0.406)[channel]
    val std = doubleArrayOf(0.229, 0.224, 0.225)[channel]
    return ((value / 255.0 - mean) / std).toFloat()
  }

  private fun argb(r: Int, g: Int, b: Int) = GoldenCase.argb(r, g, b)
}
