package app.alextran.immich.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The calibration of the Insta360 X3 photo of the research report (docs 16-formats-research.txt, V3 lens values,
 * canvas 11904x5952), as Flutter sends it (docs 16-dual-fisheye-spec.md section 5). The expected pixels come from the
 * prototype that matched Insta360 Studio's export (native-formats/stitch/x3-v3-gyroview-pose), run on the same values.
 */
class DualFisheyeCalibrationTest {
  private companion object {
    const val X3_JSON =
      """{"kind":"dualFisheye","model":"mei","frameWidth":5760,"frameHeight":2880,"canvasSquare":5952,
      "downBody":[1.0,0.0,0.0],
      "lenses":[{"xi":1.948,"fx":4627.5,"fy":4627.5,"cx":2967.5,"cy":2999.9,"yaw":-0.029,"pitch":-0.038,"roll":89.51,
      "k1":0.388,"k2":1.295,"k3":-3.969,"p1":0.0018,"p2":-0.0016},
      {"xi":1.948,"fx":4615.5,"fy":4615.5,"cx":8933.2,"cy":2998.6,"yaw":0.0,"pitch":0.0,"roll":89.49,
      "k1":0.388,"k2":1.295,"k3":-3.969,"p1":0.0,"p2":0.0}]}"""

    /** Gravity of the 2224 accelerometer samples of the X3 photo, in the body frame (research report). */
    val X3_GRAVITY = listOf(0.9885, -0.0753, -0.1310)

    /** Within a hundredth of a canvas pixel of the prototype, which prints three decimals. */
    const val PIXEL_TOLERANCE = 0.01

    fun view(lonDegrees: Double, latDegrees: Double): DoubleArray {
      val lon = Math.toRadians(lonDegrees)
      val lat = Math.toRadians(latDegrees)
      return doubleArrayOf(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon))
    }

    fun multiply(m: FloatArray, v: DoubleArray): DoubleArray =
      DoubleArray(3) { row -> m[row * 3] * v[0] + m[row * 3 + 1] * v[1] + m[row * 3 + 2] * v[2] }

    fun assertOrthonormal(m: FloatArray) {
      for (a in 0 until 3) {
        for (b in 0 until 3) {
          val dot = (0 until 3).sumOf { (m[it * 3 + a] * m[it * 3 + b]).toDouble() }
          assertEquals("columns $a and $b", if (a == b) 1.0 else 0.0, dot, 1e-5)
        }
      }
      val det =
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
      assertEquals("a rotation, not a mirror", 1.0, det.toDouble(), 1e-5)
    }

    fun assertPixel(
      expectedX: Double,
      expectedY: Double,
      expectedTheta: Double,
      actual: DualFisheyeCalibration.Projection,
    ) {
      assertEquals("x", expectedX, actual.x, PIXEL_TOLERANCE)
      assertEquals("y", expectedY, actual.y, PIXEL_TOLERANCE)
      assertEquals("theta", expectedTheta, actual.thetaDegrees, 1e-3)
    }
  }

  private val x3 = DualFisheyeCalibration.parse(X3_JSON)

  @Test
  fun `the JSON of Flutter gives the model, the frame, the canvas and both lenses`() {
    assertEquals(DualFisheyeModel.MEI, x3.model)
    assertEquals(5760, x3.frameWidth)
    assertEquals(2880, x3.frameHeight)
    assertEquals(5952.0, x3.canvasSquare, 0.0)
    assertEquals(listOf(1.0, 0.0, 0.0), x3.downBody)
    assertEquals(2, x3.lenses.size)
    val lens0 = x3.lenses[0]
    assertEquals(1.948, lens0.xi, 0.0)
    assertEquals(4627.5, lens0.fx, 0.0)
    assertEquals(2967.5, lens0.cx, 0.0)
    assertEquals(2999.9, lens0.cy, 0.0)
    assertEquals(-0.029, lens0.yaw, 0.0)
    assertEquals(89.51, lens0.roll, 0.0)
    assertEquals(-3.969, lens0.k3, 0.0)
    assertEquals(-0.0016, lens0.p2, 0.0)
    assertEquals(8933.2, x3.lenses[1].cx, 0.0)
  }

  @Test
  fun `the canvas scales to the frame by the whole square`() {
    assertEquals(2880.0 / 5952.0, x3.canvasToFrameScale(), 1e-12)
    // The 72 MP photo of the report: 5984 rows for a 5952 canvas
    assertEquals(5984.0 / 5952.0, x3.canvasToFrameScale(5984), 1e-12)
  }

  @Test
  fun `the roll is mirrored about its nearest multiple of 90 degrees`() {
    assertEquals(90.49, DualFisheyeCalibration.mirroredRoll(89.51), 1e-9)
    assertEquals(10.0, DualFisheyeCalibration.mirroredRoll(-10.0), 1e-9)
    assertEquals(179.0, DualFisheyeCalibration.mirroredRoll(181.0), 1e-9)
  }

  @Test
  fun `the lens rotations of the X3 are the ones of the prototype`() {
    val expected0 =
      floatArrayOf(
        -0.00855234f, -0.99996321f, -0.00065887f,
        0.99996330f, -0.00855201f, -0.00051180f,
        0.00050615f, -0.00066323f, 0.99999965f,
      )
    val expected1 =
      floatArrayOf(
        -0.00890106f, 0.99996038f, 0f,
        0.99996038f, 0.00890106f, 0f,
        0f, 0f, -1f,
      )
    val r0 = x3.lensRotation(0)
    val r1 = x3.lensRotation(1)
    for (i in 0 until 9) {
      assertEquals("R0[$i]", expected0[i], r0[i], 1e-6f)
      assertEquals("R1[$i]", expected1[i], r1[i], 1e-6f)
    }
    assertOrthonormal(r0)
    assertOrthonormal(r1)
  }

  @Test
  fun `an upright camera looks forward along lens 1 with gravity down the view`() {
    val g = x3.bodyFromView()
    val expected = floatArrayOf(0f, 1f, 0f, 1f, 0f, 0f, 0f, 0f, -1f)
    for (i in 0 until 9) assertEquals("G[$i]", expected[i], g[i], 1e-6f)
    // Straight ahead in the view is -z of the body, the axis of lens 1 (Studio's forward)
    val forward = multiply(g, view(0.0, 0.0))
    assertEquals(-1.0, forward[2], 1e-6)
  }

  @Test
  fun `the measured gravity levels the view`() {
    val calibration = x3.copy(downBody = X3_GRAVITY.map { it / Math.sqrt(X3_GRAVITY.sumOf { v -> v * v }) })
    val g = calibration.bodyFromView()
    assertOrthonormal(g)
    // The view's down (latitude -90 degrees) is gravity, its up the opposite
    val down = multiply(g, view(0.0, -90.0))
    for (i in 0 until 3) assertEquals(calibration.downBody[i], down[i], 1e-6)
    val expected =
      floatArrayOf(
        0.07595596f, 0.98851812f, -0.13062396f,
        0.99711117f, -0.07530138f, 0.00995041f,
        0f, -0.13100240f, -0.99138205f,
      )
    for (i in 0 until 9) assertEquals("G[$i]", expected[i], g[i], 1e-5f)
  }

  @Test
  fun `the view to lens matrix is the lens rotation after G`() {
    val r = x3.lensRotation(1)
    val g = x3.bodyFromView()
    val m = x3.viewToLens(1)
    for (row in 0 until 3) {
      for (col in 0 until 3) {
        val product = (0 until 3).sumOf { (r[row * 3 + it] * g[it * 3 + col]).toDouble() }
        assertEquals(product, m[row * 3 + col].toDouble(), 1e-6)
      }
    }
  }

  @Test
  fun `the Mei projection of the X3 matches the prototype`() {
    // Straight ahead: the centre of lens 1
    assertPixel(8933.2, 2998.6, 0.0, x3.canvasPixel(1, view(0.0, 0.0)))
    // Straight behind: next to the centre of lens 0
    assertPixel(2966.466, 2999.097, 0.0478, x3.canvasPixel(0, view(180.0, 0.0)))
    // Off axis, inside the blend or the field of each lens
    assertPixel(9738.772, 2423.092, 35.5313, x3.canvasPixel(1, view(30.0, 20.0)))
    assertPixel(4283.966, 4549.568, 69.2484, x3.canvasPixel(0, view(-120.0, -45.0)))
    // On the seam, 90 degrees off both axes
    assertPixel(301.276, 2979.311, 90.038, x3.canvasPixel(0, view(90.0, 0.0)))
    assertPixel(11585.691, 3022.211, 90.0, x3.canvasPixel(1, view(90.0, 0.0)))
    assertPixel(2988.261, 346.356, 90.029, x3.canvasPixel(0, view(0.0, 90.0)))
  }

  @Test
  fun `the Mei projection with the measured gravity matches the prototype`() {
    val calibration = x3.copy(downBody = X3_GRAVITY.map { it / Math.sqrt(X3_GRAVITY.sumOf { v -> v * v }) })
    assertPixel(8950.663, 2793.479, 7.5275, calibration.canvasPixel(1, view(0.0, 0.0)))
    assertPixel(2980.374, 3205.07, 7.4958, calibration.canvasPixel(0, view(180.0, 0.0)))
    assertPixel(9817.02, 2292.501, 40.361, calibration.canvasPixel(1, view(30.0, 20.0)))
    assertPixel(4483.212, 4617.312, 75.0088, calibration.canvasPixel(0, view(-120.0, -45.0)))
    assertPixel(2800.86, 563.861, 82.5043, calibration.canvasPixel(0, view(0.0, 90.0)))
  }

  @Test
  fun `the equidistant fallback reaches the V1 radius at 100 degrees and matches the prototype`() {
    val equidistant =
      DualFisheyeCalibration.parse(
        """{"kind":"dualFisheye","model":"equidistant","frameWidth":5760,"frameHeight":2880,"canvasSquare":5952,
        "lenses":[{"radius":2905.88,"cx":2967.5,"cy":2999.9,"yaw":-0.029,"pitch":-0.038,"roll":89.51},
        {"radius":2897.78,"cx":8933.2,"cy":2998.6,"yaw":0.0,"pitch":0.0,"roll":89.49}]}""",
      )
    assertEquals(DualFisheyeModel.EQUIDISTANT, equidistant.model)
    // No downBody: a camera standing upright
    assertEquals(listOf(1.0, 0.0, 0.0), equidistant.downBody)
    assertEquals(2905.88 / Math.toRadians(100.0), DualFisheyeCalibration.equidistantFocal(equidistant.lenses[0]), 1e-9)
    assertPixel(8933.2, 2998.6, 0.0, equidistant.canvasPixel(1, view(0.0, 0.0)))
    assertPixel(9770.987, 2400.076, 35.5313, equidistant.canvasPixel(1, view(30.0, 20.0)))
    assertPixel(4271.687, 4532.331, 69.2484, equidistant.canvasPixel(0, view(-120.0, -45.0)))
    assertPixel(351.199, 2977.525, 90.038, equidistant.canvasPixel(0, view(90.0, 0.0)))
  }

  @Test
  fun `a direction off both axes sits on the seam of the two lenses`() {
    for (lat in listOf(-60.0, -20.0, 0.0, 30.0, 75.0)) {
      val theta0 = x3.canvasPixel(0, view(90.0, lat)).thetaDegrees
      val theta1 = x3.canvasPixel(1, view(90.0, lat)).thetaDegrees
      assertTrue("theta0 $theta0 + theta1 $theta1", abs(theta0 + theta1 - 180.0) < 0.2)
    }
  }

  @Test
  fun `a degenerate gravity means a camera standing upright`() {
    val zero = DualFisheyeCalibration.parse(X3_JSON.replace("[1.0,0.0,0.0]", "[0,0,0]"))
    assertEquals(listOf(1.0, 0.0, 0.0), zero.downBody)
    val short = DualFisheyeCalibration.parse(X3_JSON.replace("[1.0,0.0,0.0]", "[1.0]"))
    assertEquals(listOf(1.0, 0.0, 0.0), short.downBody)
    // Gravity along the lens axes (filming straight down) still gives a rotation
    assertOrthonormal(x3.copy(downBody = listOf(0.0, 0.0, 1.0)).bodyFromView())
  }

  @Test
  fun `gravity is made unit length`() {
    val scaled = DualFisheyeCalibration.parse(X3_JSON.replace("[1.0,0.0,0.0]", "[0.0,-2.0,0.0]"))
    assertEquals(listOf(0.0, -1.0, 0.0), scaled.downBody)
  }

  @Test
  fun `anything but a dual fisheye calibration with two usable lenses is refused`() {
    val refused =
      listOf(
        "not json",
        "[]",
        X3_JSON.replace("dualFisheye", "equirect"),
        X3_JSON.replace("\"mei\"", "\"kannalaBrandt\""),
        X3_JSON.replace("\"canvasSquare\":5952", "\"canvasSquare\":0"),
        X3_JSON.replace("\"frameWidth\":5760,", ""),
        X3_JSON.replace("\"fx\":4615.5,", ""),
        X3_JSON.replace("\"cx\":8933.2,", ""),
        """{"kind":"dualFisheye","model":"mei","frameWidth":1,"frameHeight":1,"canvasSquare":1,"lenses":[]}""",
        """{"kind":"dualFisheye","model":"equidistant","frameWidth":1,"frameHeight":1,"canvasSquare":1,
        "lenses":[{"cx":1,"cy":1},{"cx":1,"cy":1}]}""",
      )
    for (json in refused) {
      assertThrows(json, IllegalArgumentException::class.java) { DualFisheyeCalibration.parse(json) }
    }
  }

  @Test
  fun `unknown fields are ignored`() {
    val withExtras = DualFisheyeCalibration.parse(X3_JSON.replace("{\"kind\"", "{\"serial\":\"IAQEB\",\"kind\""))
    assertEquals(x3, withExtras)
  }
}
