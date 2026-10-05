package app.alextran.immich.core.raw

import app.alextran.immich.core.raw.RawFixtures.view
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The CPU reference of the stitch shaders: the projections, their inverses, the blend and the EAC layout. */
class RawProjectionMathTest {
  private val x3Upright =
    RawProjection.parse(RawFixtures.X3_V1.replace("[0.9885,-0.0753,-0.1310]", "[1.0,0.0,0.0]"))
  private val b = RawProjection.parse(RawFixtures.B)
  private val d = RawProjection.parse(RawFixtures.D)

  private fun assertPixel(x: Double, y: Double, theta: Double, sample: RawProjection.LensSample?) {
    assertNotNull(sample)
    assertEquals("x", x, sample!!.canvasX, 0.01)
    assertEquals("y", y, sample.canvasY, 0.01)
    assertEquals("theta", theta, sample.thetaDegrees, 1e-3)
  }

  @Test
  fun `the Mei pixels of the X3 are the ones of the validated prototype`() {
    // The expectations of DualFisheyeCalibrationTest (Insta360 Studio's export, research V3)
    assertPixel(8933.2, 2998.6, 0.0, x3Upright.lensSample(1, view(0.0, 0.0)))
    assertPixel(2966.466, 2999.097, 0.0478, x3Upright.lensSample(0, view(180.0, 0.0)))
    assertPixel(9738.772, 2423.092, 35.5313, x3Upright.lensSample(1, view(30.0, 20.0)))
    assertPixel(4283.966, 4549.568, 69.2484, x3Upright.lensSample(0, view(-120.0, -45.0)))
    assertPixel(301.276, 2979.311, 90.038, x3Upright.lensSample(0, view(90.0, 0.0)))
    assertPixel(11585.691, 3022.211, 90.0, x3Upright.lensSample(1, view(90.0, 0.0)))
  }

  @Test
  fun `a lens does not see past maxTheta nor off its square`() {
    // Straight ahead is 180 degrees off the axis of lens 0
    assertNull(x3Upright.lensSample(0, view(0.0, 0.0)))
    assertNotNull(x3Upright.lensSample(1, view(0.0, 0.0)))
    // 99 degrees off lens 1 is still seen, 101 not
    assertNotNull(b.lensSample(1, view(99.0, 0.0)))
    assertNull(b.lensSample(1, view(101.0, 0.0)))
  }

  @Test
  fun `the blend shares a seam direction between both lenses and keeps the nearer one past the blend`() {
    val seam = b.fisheyeSamples(view(90.0, 0.0))
    assertEquals(2, seam.size)
    assertEquals(1.0, seam.sumOf { it.weight }, 1e-9)
    assertEquals(0.5, seam[0].weight, 1e-6)
    // Ahead: lens 1 alone with all the weight
    val ahead = b.fisheyeSamples(view(0.0, 0.0))
    assertEquals(listOf(1), ahead.map { it.lens })
    assertEquals(1.0, ahead[0].weight, 0.0)
    // One lens mode: the stream of lens 0 (texture 1) is not decoded, the back stays black
    assertTrue(b.fisheyeSamples(view(180.0, 0.0), enabled = setOf(0)).isEmpty())
  }

  @Test
  fun `Kannala-Brandt without distortion maps 90 degrees to fx times pi over 2`() {
    val plain =
      RawProjection.parse(
        RawFixtures.D.replace(Regex("\"k([1-5])\":-?[0-9.]+"), "\"k$1\":0.0")
          .replace("[0.999933,-0.007031,-0.009205,0.007135,0.999911,0.011292,0.009124,-0.011357,0.999894]",
            "[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]"),
      )
    val lens = plain.lenses[1]
    val sample = plain.lensSample(1, view(90.0, 0.0))!!
    assertEquals(90.0, sample.thetaDegrees, 1e-9)
    assertEquals(lens.fx * PI / 2, sample.canvasX - lens.cx, 1e-6)
    assertEquals(lens.cy, sample.canvasY, 1e-6)
  }

  @Test
  fun `the Kannala-Brandt projection inverts back to 2000 random directions within a hundredth of a degree`() {
    val random = Random(18)
    var checked = 0
    for (lens in 0..1) {
      repeat(1000) {
        val direction = randomDirectionNear(d.lenses[lens].viewToLens, 93.0, random)
        val sample = d.lensSample(lens, direction) ?: return@repeat
        val back = unprojectKannalaBrandt(d.lenses[lens], sample.canvasX, sample.canvasY)
        assertTrue("lens $lens", angleDegrees(direction, back) < 0.01)
        checked++
      }
    }
    assertTrue("checked $checked", checked >= 1900)
  }

  @Test
  fun `the Mei projection inverts back to 2000 random directions within a hundredth of a degree`() {
    val random = Random(5)
    var checked = 0
    val a = RawProjection.parse(RawFixtures.A)
    for (lens in 0..1) {
      repeat(1000) {
        val direction = randomDirectionNear(a.lenses[lens].viewToLens, 99.0, random)
        val sample = a.lensSample(lens, direction) ?: return@repeat
        val back = unprojectMei(a.lenses[lens], sample.canvasX, sample.canvasY)
        assertTrue("lens $lens", angleDegrees(direction, back) < 0.01)
        checked++
      }
    }
    assertTrue("checked $checked", checked >= 1900)
  }

  @Test
  fun `the Mei k4 and k5 terms move the pixel`() {
    val withTerms = RawProjection.parse(RawFixtures.B.replace("\"k4\":0.0,\"k5\":0.0", "\"k4\":0.01,\"k5\":-0.002"))
    // Near the edge of the lens, where r^8 and r^10 matter: a tenth of a pixel on this lens
    val direction = view(95.0, 0.0)
    val plain = b.lensSample(1, direction)!!
    val terms = withTerms.lensSample(1, direction)!!
    assertTrue("${terms.canvasX - plain.canvasX}", terms.canvasX - plain.canvasX > 0.1)
    // Near the axis they do not
    val near = view(10.0, 0.0)
    assertEquals(b.lensSample(1, near)!!.canvasX, withTerms.lensSample(1, near)!!.canvasX, 1e-6)
  }

  @Test
  fun `the regions of a side by side frame and of a whole track give the texture fractions`() {
    // Side by side: lens 1's square is the right half
    val a = RawProjection.parse(RawFixtures.A)
    val ahead = a.lensSample(1, view(0.0, 0.0))!!
    assertEquals(0.5 + (ahead.canvasX - 5952.0) / 5952.0 / 2, ahead.textureX, 1e-12)
    // Two tracks: lens 1 fills track 0
    val b1 = b.lensSample(1, view(0.0, 0.0))!!
    assertEquals(0, b1.texture)
    assertEquals(0.5, b1.textureX, 1e-9)
    assertEquals(0.5, b1.textureY, 1e-9)
  }

  @Test
  fun `the EAC test vectors of max2-reframe-resolve hold on the MAX 2 geometry`() {
    val max2 = RawProjection.parse(RawFixtures.MAX2_8BIT)
    fun check(direction: DoubleArray, vararg expected: RawProjection.EacSample) {
      val samples = max2.eacSamples(direction)
      assertEquals(expected.size, samples.size)
      for ((e, s) in expected.zip(samples)) {
        assertEquals("texture", e.texture, s.texture)
        assertEquals("x", e.x, s.x, 1e-3)
        assertEquals("y", e.y, s.y, 1e-3)
        assertEquals("weight", e.weight, s.weight, 1e-6)
      }
    }
    check(doubleArrayOf(0.0, 0.0, 1.0), RawProjection.EacSample(0, 2944.0, 960.0, 1.0))
    check(doubleArrayOf(0.0, 0.0, -1.0), RawProjection.EacSample(1, 2944.0, 960.0, 1.0))
    check(
      doubleArrayOf(1.0, 0.0, 0.0),
      RawProjection.EacSample(0, 4864.0, 960.0, 0.5078125),
      RawProjection.EacSample(0, 4928.0, 960.0, 0.4921875),
    )
    check(
      doubleArrayOf(-1.0, 0.0, 0.0),
      RawProjection.EacSample(0, 960.0, 960.0, 0.5078125),
      RawProjection.EacSample(0, 1024.0, 960.0, 0.4921875),
    )
    check(
      doubleArrayOf(0.0, -1.0, 0.0),
      RawProjection.EacSample(1, 4864.0, 960.0, 0.5078125),
      RawProjection.EacSample(1, 4928.0, 960.0, 0.4921875),
    )
    check(
      doubleArrayOf(0.0, 1.0, 0.0),
      RawProjection.EacSample(1, 960.0, 960.0, 0.5078125),
      RawProjection.EacSample(1, 1024.0, 960.0, 0.4921875),
    )
    check(view(30.0, 0.0), RawProjection.EacSample(0, 3584.0, 960.0, 1.0))
    check(view(0.0, 20.0), RawProjection.EacSample(0, 2944.0, 533.333, 1.0))
    val two = Math.toRadians(2.0)
    check(doubleArrayOf(-cos(two), 0.0, sin(two)), RawProjection.EacSample(0, 1066.667, 960.0, 1.0))
    check(view(170.0, 5.0), RawProjection.EacSample(1, 3052.304, 746.667, 1.0))
  }

  @Test
  fun `every direction falls on exactly one face within its square`() {
    val max = RawProjection.parse(RawFixtures.MAX)
    val geometry = max.eac!!
    for (i in 0 until 128) {
      for (j in 0 until 64) {
        val direction = view((i + 0.5) / 128 * 360 - 180, 90 - (j + 0.5) / 64 * 180)
        val c = RawProjection.multiply(geometry.viewToCamera, direction)
        val dots = geometry.faces.map { RawProjection.dot(c, it.forward) }
        val best = dots.max()
        val face = geometry.faces[dots.indexOf(best)]
        val u = RawProjection.dot(c, face.right) / best
        val v = RawProjection.dot(c, face.down) / best
        assertTrue("u $u at $i, $j", abs(u) <= 1 + 1e-9)
        assertTrue("v $v at $i, $j", abs(v) <= 1 + 1e-9)
        val samples = max.eacSamples(direction)
        assertTrue(samples.isNotEmpty() && samples.all { it.texture == face.texture })
        assertEquals(1.0, samples.sumOf { it.weight }, 1e-9)
        for (s in samples) {
          assertTrue(s.x in 0.5..(geometry.trackWidth - 0.5) && s.y in 0.5..(geometry.face - 0.5))
        }
      }
    }
  }

  @Test
  fun `the face table is orthonormal and every face centre lands in its slot centre`() {
    val max = RawProjection.parse(RawFixtures.MAX)
    val geometry = max.eac!!
    for (face in geometry.faces) {
      for (axis in listOf(face.forward, face.right, face.down)) assertEquals(1.0, RawProjection.dot(axis, axis), 1e-12)
      assertEquals(0.0, RawProjection.dot(face.forward, face.right), 1e-12)
      assertEquals(0.0, RawProjection.dot(face.forward, face.down), 1e-12)
      assertEquals(0.0, RawProjection.dot(face.right, face.down), 1e-12)
      // The view direction whose camera direction is the face's forward axis (viewToCamera is its own inverse)
      val direction = RawProjection.multiply(transpose(geometry.viewToCamera), face.forward)
      val samples = max.eacSamples(direction)
      // Face column 672 of 1344: the middle of the slot, or of each half of a split slot
      if (face.slot == 1) {
        assertEquals(listOf(geometry.middle + 672.0), samples.map { it.x })
      } else {
        val base = if (face.slot == 0) 0.0 else geometry.right.toDouble()
        val second = base + geometry.half + 672.0 - (geometry.face - geometry.half)
        assertEquals(listOf(base + 672.0, second), samples.map { it.x })
      }
      assertEquals(672.0, samples[0].y, 1e-9)
    }
  }

  @Test
  fun `the overlap blend of the MAX goes from the first half at face column 656 to the second at 688`() {
    val max = RawProjection.parse(RawFixtures.MAX)
    val geometry = max.eac!!
    // The left face (texture 0, slot 0): a direction at face column col, centre row
    fun weightOfSecondHalf(col: Double): Double {
      val face = geometry.faces.first { it.texture == 0 && it.slot == 0 }
      val u = Math.tan((col / geometry.face * 2 - 1) * PI / 4)
      val c = DoubleArray(3) { face.forward[it] + u * face.right[it] }
      val norm = sqrt(RawProjection.dot(c, c))
      val direction = RawProjection.multiply(transpose(geometry.viewToCamera), DoubleArray(3) { c[it] / norm })
      val samples = max.eacSamples(direction)
      return samples.filter { it.x >= geometry.half }.sumOf { it.weight }
    }
    assertEquals(0.0, weightOfSecondHalf(656.5), 1e-6)
    assertEquals(1.0, weightOfSecondHalf(688.5), 1e-6)
    assertEquals(0.5, weightOfSecondHalf(672.5), 1e-6)
  }

  private fun transpose(m: DoubleArray): DoubleArray = DoubleArray(9) { m[(it % 3) * 3 + it / 3] }

  /** A random view direction within [maxDegrees] of the axis of the lens of [viewToLens]. */
  private fun randomDirectionNear(viewToLens: DoubleArray, maxDegrees: Double, random: Random): DoubleArray {
    val theta = acos(1 - random.nextDouble() * (1 - cos(Math.toRadians(maxDegrees))))
    val phi = random.nextDouble() * 2 * PI
    val lens = doubleArrayOf(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
    return RawProjection.multiply(transpose(viewToLens), lens)
  }

  private fun angleDegrees(a: DoubleArray, b: DoubleArray): Double {
    val cosine = RawProjection.dot(a, b) / sqrt(RawProjection.dot(a, a) * RawProjection.dot(b, b))
    return Math.toDegrees(acos(cosine.coerceIn(-1.0, 1.0)))
  }

  /** Newton on theta_d(theta) = rho, then the view direction (the inverse of the shader's Kannala-Brandt). */
  private fun unprojectKannalaBrandt(lens: RawLens, px: Double, py: Double): DoubleArray {
    val a = (px - lens.cx) / lens.fx
    val b = (py - lens.cy) / lens.fy
    val rho = hypot(a, b)
    var theta = rho
    repeat(50) {
      val t2 = theta * theta
      val k = lens.k
      val f = theta * (1 + t2 * (k[0] + t2 * (k[1] + t2 * (k[2] + t2 * (k[3] + t2 * k[4]))))) - rho
      val df =
        1 + 3 * k[0] * t2 + 5 * k[1] * t2 * t2 + 7 * k[2] * t2 * t2 * t2 + 9 * k[3] * t2 * t2 * t2 * t2 +
          11 * k[4] * t2 * t2 * t2 * t2 * t2
      theta -= f / df
    }
    val d =
      if (rho > 1e-12) {
        doubleArrayOf(sin(theta) * a / rho, sin(theta) * b / rho, cos(theta))
      } else {
        doubleArrayOf(0.0, 0.0, 1.0)
      }
    return RawProjection.multiply(transpose(lens.viewToLens), d)
  }

  /** Newton on the distortion (numeric Jacobian), then the Mei unit sphere lift. */
  private fun unprojectMei(lens: RawLens, px: Double, py: Double): DoubleArray {
    val qx = (px - lens.cx) / lens.fx
    val qy = (py - lens.cy) / lens.fy
    fun distort(mx: Double, my: Double): Pair<Double, Double> {
      val r2 = mx * mx + my * my
      val k = lens.k
      val radial = 1 + r2 * (k[0] + r2 * (k[1] + r2 * (k[2] + r2 * (k[3] + r2 * k[4]))))
      return (radial * mx + 2 * lens.p1 * mx * my + lens.p2 * (r2 + 2 * mx * mx)) to
        (radial * my + lens.p1 * (r2 + 2 * my * my) + 2 * lens.p2 * mx * my)
    }
    var mx = qx
    var my = qy
    repeat(50) {
      val (fx, fy) = distort(mx, my)
      val ex = fx - qx
      val ey = fy - qy
      val h = 1e-7
      val (ax, ay) = distort(mx + h, my)
      val (bx, by) = distort(mx, my + h)
      val j11 = (ax - fx) / h
      val j21 = (ay - fy) / h
      val j12 = (bx - fx) / h
      val j22 = (by - fy) / h
      val det = j11 * j22 - j12 * j21
      mx -= (j22 * ex - j12 * ey) / det
      my -= (-j21 * ex + j11 * ey) / det
    }
    val r2 = mx * mx + my * my
    val xi = lens.xi
    val factor = (xi + sqrt(1 + (1 - xi * xi) * r2)) / (r2 + 1)
    val d = doubleArrayOf(factor * mx, factor * my, factor - xi)
    return RawProjection.multiply(transpose(lens.viewToLens), d)
  }
}
