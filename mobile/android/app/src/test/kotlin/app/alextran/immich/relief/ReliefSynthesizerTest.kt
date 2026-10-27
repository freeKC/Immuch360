package app.alextran.immich.relief

import java.util.concurrent.CancellationException
import kotlin.math.abs
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * relief-v1 in Kotlin against the golden fixture of .github/desktop/ai/make_relief_golden.py, the same one the Dart of
 * the computers is held to: each channel of the right eye within one unit, the mask of the filled holes exactly.
 */
class ReliefSynthesizerTest {
  private val cases = GoldenCase.all()

  @Test
  fun `the fixture is relief-v1 with the settings of the app`() {
    val fixture = ReliefFixtures.json("relief_golden_v1.json")
    assertEquals(ReliefV1.PIPELINE, fixture.getValue("pipeline").toString().trim('"'))
    assertEquals(ReliefV1.LINK_THRESHOLD.toString(), fixture.getValue("linkThreshold").toString())
    assertEquals(ReliefV1.DILATION_WINDOW.toString(), fixture.getValue("dilationWindow").toString())
    assertEquals(
      "[${ReliefV1.LOW_PERCENTILE},${ReliefV1.HIGH_PERCENTILE}]",
      fixture.getValue("percentiles").toString(),
    )
    assertEquals(ReliefV1.LOW_RELIEF_RATIO.toString(), fixture.getValue("lowReliefRatio").toString())
    assertEquals(ReliefV1.HIDDEN_AREAS_RATIO.toString(), fixture.getValue("hiddenAreasRatio").toString())
    assertEquals(ReliefV1.DARK_LUMA.toString(), fixture.getValue("darkLuma").toString())
    assertTrue("four cases at least", cases.size >= 4)
    assertTrue(cases.any { it.name == "production" && it.parallax == ReliefV1.PARALLAX })
    assertTrue(cases.any { it.name == "production" && it.convergence == ReliefV1.CONVERGENCE })
  }

  @Test
  fun `the percentiles, the normalised map, the dilation and the depth of the eye are those of the fixture`() {
    for (case in cases) {
      val normalized = ReliefSynthesizer.normalize(case.depth, case.mapWidth, case.mapHeight)
      assertEquals(case.name, case.p2, normalized.p2, 0.0)
      assertEquals(case.name, case.p98, normalized.p98, 0.0)
      assertEquals(case.name, "lowRelief" in case.flags, normalized.lowRelief)
      assertClose(case.name + " normalized", case.normalized, normalized.values, 1e-12)
      val dilated = ReliefSynthesizer.dilate(normalized.values, case.mapWidth, case.mapHeight)
      assertClose(case.name + " dilated", case.dilated, dilated, 0.0)
      val eye = ReliefSynthesizer.EyeDepth(dilated, case.mapWidth, case.mapHeight, case.eyeWidth, case.eyeHeight)
      val row = DoubleArray(case.eyeWidth)
      for (y in 0 until case.eyeHeight) {
        eye.row(y, row)
        val expected = case.eyeDepth.copyOfRange(y * case.eyeWidth, (y + 1) * case.eyeWidth)
        assertClose("${case.name} eye depth row $y", expected, row, 1e-12)
      }
    }
  }

  @Test
  fun `the right eye is within one unit per channel and the holes are those of the fixture`() {
    for (case in cases) {
      val normalized = ReliefSynthesizer.normalize(case.depth, case.mapWidth, case.mapHeight)
      val out = IntArray(case.eyeWidth * case.eyeHeight)
      val holes = arrayOfNulls<String>(case.eyeHeight)
      val result =
        ReliefSynthesizer.rightEye(
          case.image,
          case.eyeWidth,
          case.eyeHeight,
          normalized.values,
          case.mapWidth,
          case.mapHeight,
          out,
          parallax = case.parallax,
          convergence = case.convergence,
          lowRelief = normalized.lowRelief,
          holes = { y, row -> holes[y] = row.joinToString("") { if (it) "1" else "0" } },
        )
      for (y in 0 until case.eyeHeight) {
        val expected = case.rightEye[y]
        for (x in 0 until case.eyeWidth) {
          val pixel = out[y * case.eyeWidth + x]
          assertEquals("${case.name} alpha at $x, $y", 0xFF, pixel ushr 24)
          val channels = intArrayOf((pixel shr 16) and 0xFF, (pixel shr 8) and 0xFF, pixel and 0xFF)
          for (k in 0..2) {
            val difference = abs(channels[k] - expected[3 * x + k])
            if (difference > 1.0) {
              fail("${case.name}: channel $k at $x, $y is ${channels[k]}, the fixture says ${expected[3 * x + k]}")
            }
          }
        }
        assertEquals("${case.name} holes of row $y", case.holes[y], holes[y])
      }
      assertEquals(case.name, case.filledPixels, result.filledPixels)
      assertEquals(case.name, case.meanLuma, result.meanLuma, 1e-9)
      assertEquals(case.name, case.flags, result.flags.map { it.xmp })
    }
  }

  @Test
  fun `the rows read and written one by one give the same eye as the arrays`() {
    for (case in cases) {
      val normalized = ReliefSynthesizer.normalize(case.depth, case.mapWidth, case.mapHeight)
      val whole = IntArray(case.eyeWidth * case.eyeHeight)
      ReliefSynthesizer.rightEye(
        case.image,
        case.eyeWidth,
        case.eyeHeight,
        normalized.values,
        case.mapWidth,
        case.mapHeight,
        whole,
        parallax = case.parallax,
        convergence = case.convergence,
      )
      val streamed = IntArray(case.eyeWidth * case.eyeHeight)
      val readRows = mutableListOf<Int>()
      ReliefSynthesizer.rightEye(
        case.eyeWidth,
        case.eyeHeight,
        normalized.values,
        case.mapWidth,
        case.mapHeight,
        read = { y, row ->
          readRows += y
          case.image.copyInto(row, 0, y * case.eyeWidth, (y + 1) * case.eyeWidth)
        },
        write = { y, row -> row.copyInto(streamed, y * case.eyeWidth) },
        parallax = case.parallax,
        convergence = case.convergence,
      )
      assertArrayEquals(case.name, whole, streamed)
      assertEquals("each row read once, in order", (0 until case.eyeHeight).toList(), readRows)
    }
  }

  @Test
  fun `a flat map gives a right eye equal to the left one`() {
    val width = 37
    val height = 11
    val left = photo(width, height)
    for (value in listOf(0.0, 3.0, -7.5)) {
      val normalized = ReliefSynthesizer.normalize(DoubleArray(9 * 5) { value }, 9, 5)
      assertTrue(normalized.lowRelief)
      assertTrue(normalized.values.all { it == 0.5 })
      val out = IntArray(width * height)
      val result =
        ReliefSynthesizer.rightEye(left, width, height, normalized.values, 9, 5, out, lowRelief = normalized.lowRelief)
      assertArrayEquals(left, out)
      assertEquals(0, result.filledPixels)
      assertEquals(listOf(ReliefFlag.LOW_RELIEF), result.flags)
    }
  }

  @Test
  fun `a flat map read back from the 16 bit cache still gives the left eye`() {
    val width = 64
    val height = 9
    val left = photo(width, height)
    val map = ReliefMap.quantize(9, 5, DoubleArray(9 * 5) { 0.5 })
    val out = IntArray(width * height)
    ReliefSynthesizer.rightEye(left, width, height, map.toNormalized(), map.width, map.height, out)
    assertArrayEquals(left, out)
  }

  @Test
  fun `no hole is left once filled, and only the right eye is written`() {
    val width = 48
    val height = 12
    val left = photo(width, height)
    val before = left.copyOf()
    val depth = DoubleArray(12 * 6) { i -> if (i % 12 in 4..7) 9.0 else 1.0 + (i / 12) * 0.5 }
    val normalized = ReliefSynthesizer.normalize(depth, 12, 6)
    val sentinel = 0x00123456
    val out = IntArray(width * height) { sentinel }
    var holes = 0
    val result =
      ReliefSynthesizer.rightEye(
        left,
        width,
        height,
        normalized.values,
        12,
        6,
        out,
        parallax = 0.3,
        holes = { _, row -> holes += row.count { it } },
      )
    assertTrue("holes were opened", holes > 0)
    assertEquals(holes, result.filledPixels)
    for (pixel in out) {
      assertNotEquals(sentinel, pixel)
      assertEquals(0xFF, pixel ushr 24)
    }
    assertArrayEquals("the left eye is never changed", before, left)
    assertTrue(ReliefFlag.HIDDEN_AREAS in result.flags)
  }

  @Test
  fun `a hole takes the colour of its background side`() {
    // One row: a near object (d = 1) in the middle of a far ground (d = 0), a wide parallax: the object moves left and
    // opens a hole at its right, which the far ground on the right fills
    val width = 20
    val left = IntArray(width) { x -> if (x in 8..11) GoldenCase.argb(250, 10, 10) else GoldenCase.argb(10, 10, 250) }
    val map = DoubleArray(20) { x -> if (x in 8..11) 1.0 else 0.0 }
    val out = IntArray(width)
    val mask = BooleanArray(width)
    ReliefSynthesizer.rightEye(
      left,
      width,
      1,
      map,
      20,
      1,
      out,
      parallax = 0.2,
      convergence = 0.5,
      holes = { _, row -> row.copyInto(mask) },
    )
    assertTrue("a hole opened", mask.any { it })
    for (x in 0 until width) {
      if (mask[x]) assertEquals("hole at $x is blue", 250, out[x] and 0xFF)
    }
  }

  @Test
  fun `on a tie of depth the left neighbour fills the hole`() {
    // A far strip (d = 0) between two parts at the same depth (0.5, which stays in place): the strip moves right
    // behind the right part and leaves a hole whose two neighbours are at 0.5. The fixture has no such tie (A0
    // review, minor 1).
    val width = 30
    val red = GoldenCase.argb(255, 0, 0)
    val blue = GoldenCase.argb(0, 0, 255)
    val left = IntArray(width) { x -> if (x < 12) red else if (x < 15) GoldenCase.argb(0, 255, 0) else blue }
    val map = DoubleArray(width) { x -> if (x in 10..16) 0.0 else 0.5 }
    val out = IntArray(width)
    val mask = BooleanArray(width)
    ReliefSynthesizer.rightEye(
      left,
      width,
      1,
      map,
      width,
      1,
      out,
      parallax = 0.4,
      holes = { _, row -> row.copyInto(mask) },
    )
    assertEquals("12 to 14 are holes", (0 until width).map { it in 12..14 }, mask.toList())
    assertEquals(red, out[12])
    assertEquals(red, out[13])
    assertEquals(GoldenCase.argb(170, 0, 85), out[14])
  }

  @Test
  fun `two neighbours within the link threshold of 4 hundredths are linked, and open beyond it`() {
    // The cases of right_eye_test.dart on the computers: 100 near pixels then 100 far ones, c = 0. The dilation of
    // the map makes the near part 102 pixels wide here (Dart gets the map dilated already): they move left by 100 d,
    // the far ones stay, and the step between columns 101 and 102 is linked or opens 4 holes.
    val width = 200
    val left = IntArray(width) { x -> GoldenCase.argb(x % 256, 3 * x % 256, 255 - x % 256) }
    for ((near, holesWanted) in listOf(0.04 to 0, 0.0375 to 0, 0.0425 to 4, 0.0401 to 4)) {
      val map = DoubleArray(width) { x -> if (x < 100) near else 0.0 }
      val out = IntArray(width)
      val mask = BooleanArray(width)
      val eye =
        ReliefSynthesizer.rightEye(
          left,
          width,
          1,
          map,
          width,
          1,
          out,
          parallax = 0.5,
          convergence = 0.0,
          holes = { _, row -> row.copyInto(mask) },
        )
      assertEquals("near at $near", holesWanted, eye.filledPixels)
      val wanted = if (holesWanted > 0) listOf(98, 99, 100, 101) else emptyList()
      assertEquals("near at $near", wanted, (0 until width).filter { mask[it] })
    }
  }

  @Test
  fun `a row where nothing lands is black`() {
    val width = 10
    val left = IntArray(width * 2) { GoldenCase.argb(200, 100, 50) }
    val out = IntArray(width * 2)
    val result =
      ReliefSynthesizer.rightEye(left, width, 2, DoubleArray(4) { 0.5 }, 2, 2, out, parallax = 5.0, convergence = 0.0)
    assertTrue(out.all { it == GoldenCase.argb(0, 0, 0) })
    assertEquals(20, result.filledPixels)
  }

  @Test
  fun `the percentile is taken by nearest rank`() {
    val hundred = DoubleArray(100) { (it + 1).toDouble() }
    assertEquals(2.0, ReliefSynthesizer.percentile(hundred, 2), 0.0)
    assertEquals(98.0, ReliefSynthesizer.percentile(hundred, 98), 0.0)
    val ten = DoubleArray(10) { (it + 1).toDouble() }
    assertEquals(1.0, ReliefSynthesizer.percentile(ten, 2), 0.0)
    assertEquals(10.0, ReliefSynthesizer.percentile(ten, 98), 0.0)
    assertEquals(7.0, ReliefSynthesizer.percentile(doubleArrayOf(7.0), 98), 0.0)
  }

  @Test
  fun `low relief is a spread under a tenth of p98, not at a tenth`() {
    // p2 = 9 and p98 = 10 on two values: a spread of exactly 0.1 x p98
    assertFalse(ReliefSynthesizer.normalize(doubleArrayOf(9.0, 10.0), 2, 1).lowRelief)
    assertTrue(ReliefSynthesizer.normalize(doubleArrayOf(9.0, 9.99), 2, 1).lowRelief)
  }

  @Test
  fun `the flags say hidden areas past 5 percent filled and dark under a luma of 20, in their order`() {
    // The cases of relief_flags_test.dart on the computers, on 100 x 20 pixels
    fun flags(lowRelief: Boolean = false, filled: Int = 0, luma: Double = 100.0) =
      ReliefSynthesizer.flags(lowRelief, filled, 100, 20, luma)
    assertEquals(emptyList<ReliefFlag>(), flags())
    assertEquals(emptyList<ReliefFlag>(), flags(filled = 100))
    assertEquals(listOf(ReliefFlag.HIDDEN_AREAS), flags(filled = 101))
    assertEquals(emptyList<ReliefFlag>(), flags(luma = 20.0))
    assertEquals(listOf(ReliefFlag.DARK), flags(luma = 19.99))
    assertEquals(
      listOf(ReliefFlag.LOW_RELIEF, ReliefFlag.HIDDEN_AREAS, ReliefFlag.DARK),
      flags(lowRelief = true, filled = 2000, luma = 3.0),
    )
  }

  @Test
  fun `the float map of the model gives the same normalisation as its doubles`() {
    val floats = FloatArray(16 * 4) { i -> 1f + 0.37f * (i % 16) + 0.11f * (i / 16) }
    val fromFloats = ReliefSynthesizer.normalize(floats, 16, 4)
    val fromDoubles = ReliefSynthesizer.normalize(DoubleArray(floats.size) { floats[it].toDouble() }, 16, 4)
    assertArrayEquals(fromDoubles.values, fromFloats.values, 0.0)
    assertEquals(fromDoubles.p2, fromFloats.p2, 0.0)
    assertEquals(fromDoubles.p98, fromFloats.p98, 0.0)
  }

  @Test
  fun `a value the model got wrong stays in the middle and out of the percentiles, as on the computers`() {
    val depth = DoubleArray(16) { it.toDouble() }
    depth[5] = Double.NaN
    depth[6] = Double.POSITIVE_INFINITY
    depth[7] = Double.NEGATIVE_INFINITY
    val normalized = ReliefSynthesizer.normalize(depth, 4, 4)
    assertTrue(normalized.values.all { it in 0.0..1.0 })
    assertEquals(0.5, normalized.values[5], 0.0)
    assertEquals(1.0, normalized.values[6], 0.0)
    assertEquals(0.0, normalized.values[7], 0.0)
    assertEquals("the percentiles skip them", 0.0, normalized.p2, 0.0)
    assertEquals(15.0, normalized.p98, 0.0)
    assertEquals(1.0, normalized.values[15], 0.0)
    val nothing = ReliefSynthesizer.normalize(DoubleArray(4) { Double.NaN }, 2, 2)
    assertTrue(nothing.lowRelief)
    assertTrue(nothing.values.all { it == 0.5 })
  }

  @Test
  fun `a cancelled synthesis stops between rows and writes no more`() {
    val width = 16
    val height = 200
    val left = photo(width, height)
    var asked = 0
    val written = mutableListOf<Int>()
    try {
      ReliefSynthesizer.rightEye(
        width,
        height,
        DoubleArray(4) { it / 3.0 },
        2,
        2,
        read = { y, row -> left.copyInto(row, 0, y * width, (y + 1) * width) },
        write = { y, _ -> written += y },
        cancelled = { ++asked > 1 },
      )
      fail("not cancelled")
    } catch (expected: CancellationException) {
      // The first check passes, the second one stops
    }
    assertEquals(ReliefV1.CANCEL_CHECK_ROWS, written.size)
    assertFalse(written.contains(height - 1))
  }

  @Test
  fun `the right eye of a near object moves left and the far ground right`() {
    val width = 200
    val left = IntArray(width) { x -> GoldenCase.argb(x, 0, 0) }
    val near = IntArray(width)
    ReliefSynthesizer.rightEye(left, width, 1, DoubleArray(2) { 1.0 }, 2, 1, near)
    // s = 0.02 * 200 * (0.5 minus 1) = -2: what was at x + 2 is now at x
    assertEquals(12, (near[10] shr 16) and 0xFF)
    val far = IntArray(width)
    ReliefSynthesizer.rightEye(left, width, 1, DoubleArray(2) { 0.0 }, 2, 1, far)
    assertEquals(8, (far[10] shr 16) and 0xFF)
  }

  private fun photo(width: Int, height: Int) =
    IntArray(width * height) { i ->
      val x = i % width
      val y = i / width
      GoldenCase.argb((17 * x + 3 * y * y) % 256, (5 * x * y + 40) % 256, (255 - 7 * x - 11 * y).mod(256))
    }

  private fun assertClose(message: String, expected: DoubleArray, actual: DoubleArray, tolerance: Double) {
    assertEquals("$message size", expected.size, actual.size)
    for (i in expected.indices) assertEquals("$message at $i", expected[i], actual[i], tolerance)
  }
}
