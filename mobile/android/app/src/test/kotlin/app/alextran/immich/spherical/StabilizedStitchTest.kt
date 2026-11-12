package app.alextran.immich.spherical

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stabilisation turned inside the stitch (issue 14, lot d3, the immersive viewer of the Meta Quest): the mat3
 * uniform uStabilization of the stitch shaders, which turns the view direction e of each output pixel into the
 * direction of the stitched view it shows. The checks of StabilizationTableTest (Media3's sphere) are ported here to
 * the stitch: the point at direction d of the stitched view must be shown at K d, as Flutter means, so the pixel at e
 * must show the point at K^T e. The GLSL product of a mat3 uniform uploaded without transpose (column major) and the
 * view direction of the stitch (RawStitchShaders viewDirection) are written here apart from the code under test.
 */
class StabilizedStitchTest {
  private val degree = PI / 180

  // ---- Math of the tests, apart from the code under test

  /** The rotation by [angle] radians about the unit [axis], right handed (Rodrigues), row major */
  private fun rotation(axis: DoubleArray, angle: Double): Array<DoubleArray> {
    val n = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
    val (x, y, z) = Triple(axis[0] / n, axis[1] / n, axis[2] / n)
    val c = cos(angle)
    val s = sin(angle)
    val t = 1 - c
    return arrayOf(
      doubleArrayOf(t * x * x + c, t * x * y - s * z, t * x * z + s * y),
      doubleArrayOf(t * x * y + s * z, t * y * y + c, t * y * z - s * x),
      doubleArrayOf(t * x * z - s * y, t * y * z + s * x, t * z * z + c),
    )
  }

  private fun times(m: Array<DoubleArray>, v: DoubleArray) =
    DoubleArray(3) { m[it][0] * v[0] + m[it][1] * v[1] + m[it][2] * v[2] }

  /** The quaternion (w, x, y, z) of the rotation by [angle] about the unit [axis] */
  private fun quaternion(axis: DoubleArray, angle: Double): DoubleArray {
    val n = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
    val s = sin(angle / 2) / n
    return doubleArrayOf(cos(angle / 2), axis[0] * s, axis[1] * s, axis[2] * s)
  }

  /** The rotation matrix of the unit quaternion [q] (w, x, y, z), acting on vectors, row major */
  private fun matrixOf(q: DoubleArray): Array<DoubleArray> {
    val (w, x, y, z) = q.toList()
    return arrayOf(
      doubleArrayOf(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
      doubleArrayOf(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
      doubleArrayOf(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)),
    )
  }

  /**
   * What GLSL computes for `uStabilization * e` with the nine values [uniform] uploaded by glUniformMatrix3fv without
   * transpose: the values are the columns one after the other, and the product sums the columns weighted by e
   */
  private fun glsl(uniform: FloatArray, e: DoubleArray) =
    DoubleArray(3) { row -> (0 until 3).sumOf { column -> uniform[3 * column + row].toDouble() * e[column] } }

  /**
   * The view direction of the stitch for a point of the equirectangular output (RawStitchShaders viewDirection, u
   * across, v from the top): longitude (2 u - 1) pi, latitude pi / 2 - pi v, (cos lat sin lon, -sin lat, cos lat cos
   * lon); x to the right, y down, z forward
   */
  private fun viewDirection(u: Double, v: Double): DoubleArray {
    val lon = (2 * u - 1) * PI
    val lat = PI / 2 - PI * v
    return doubleArrayOf(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon))
  }

  private fun assertVector(expected: DoubleArray, actual: DoubleArray, tolerance: Double, message: String = "") {
    for (i in 0 until 3) assertEquals("$message [$i]", expected[i], actual[i], tolerance)
  }

  private fun tableOf(times: LongArray, quaternions: List<DoubleArray>): StabilizationTable =
    StabilizationTable.of(times, quaternions.flatMap { it.toList() }.toDoubleArray()) { error("refused: $it") }!!

  /** The stitched direction the output pixel at direction [e] shows, with the uniform of [stitch] at [timeUs] */
  private fun shown(stitch: StabilizedStitch, timeUs: Long, e: DoubleArray) = glsl(stitch.matrixAt(timeUs), e)

  private fun stitchOf(table: StabilizationTable?) = StabilizedStitch().also { it.table = table }

  // ---- The four checks of StabilizationTableTest, on the stitch

  @Test
  fun aCameraPitchedDownHasItsCentreDrawnBelowTheFront() {
    // The camera looks 10 degrees below the horizon and the target is level: the correction is the rotation about x
    // by -10 degrees
    val stitch = stitchOf(tableOf(longArrayOf(0), listOf(quaternion(doubleArrayOf(1.0, 0.0, 0.0), -10 * degree))))
    // The output pixel 10 degrees below the front (y down) shows the centre of the stitched picture, what the camera
    // looked at
    val below = doubleArrayOf(0.0, sin(10 * degree), cos(10 * degree))
    assertVector(doubleArrayOf(0.0, 0.0, 1.0), shown(stitch, 0, below), 1e-6)
    // And the output pixel straight ahead shows the point of the picture 10 degrees above its centre: the horizon
    val ahead = shown(stitch, 0, doubleArrayOf(0.0, 0.0, 1.0))
    assertVector(viewDirection(0.5, 0.5 - 10.0 / 180), ahead, 1e-6)
  }

  @Test
  fun aRolledCameraHasItsHorizonDrawnLevel() {
    // The camera rolled 15 degrees about its forward axis: the world's right (1, 0, 0) is seen at C^T (1, 0, 0)
    val roll = quaternion(doubleArrayOf(0.0, 0.0, 1.0), 15 * degree)
    val camera = matrixOf(roll)
    val seenRight = DoubleArray(3) { camera[0][it] }
    val stitch = stitchOf(tableOf(longArrayOf(0), listOf(roll)))
    // The output pixel at the right of the view, on the horizon, shows that point of the picture
    assertVector(seenRight, shown(stitch, 0, doubleArrayOf(1.0, 0.0, 0.0)), 1e-6)
  }

  @Test
  fun anyCorrectionDrawsTheViewDirectionDWhereKdSays() {
    // Random rotations about random axes: the pixel at e shows the point d with K d = e, all over the picture
    val random = java.util.Random(14)
    repeat(50) {
      val axis = doubleArrayOf(random.nextGaussian(), random.nextGaussian(), random.nextGaussian())
      val angle = (random.nextDouble() * 2 - 1) * PI * 0.95
      val q = quaternion(axis, angle)
      val k = matrixOf(q)
      val stitch = stitchOf(tableOf(longArrayOf(0), listOf(q)))
      for (u in listOf(0.1, 0.5, 0.8)) {
        for (v in listOf(0.3, 0.5, 0.9)) {
          val d = viewDirection(u, v)
          // The pixel at K d shows d
          assertVector(d, shown(stitch, 0, times(k, d)), 1e-5, "angle $angle u $u v $v")
        }
      }
      // q and -q are the same rotation: the same uniform
      val negated = stitchOf(tableOf(longArrayOf(0), listOf(DoubleArray(4) { -q[it] })))
      assertArrayEquals(stitch.matrixAt(0), negated.matrixAt(0), 1e-6f)
    }
  }

  @Test
  fun aSmallTurnOfTheCameraIsUndoneInTheStitch() {
    // The camera shook 3 degrees to the right between two frames while the target kept its heading
    val shake = quaternion(doubleArrayOf(0.0, 1.0, 0.0), 3 * degree)
    val stitch = stitchOf(tableOf(longArrayOf(0, 33_367), listOf(doubleArrayOf(1.0, 0.0, 0.0, 0.0), shake)))
    // What the camera sees at its centre is the world 3 degrees to the right: the output pixel there shows it
    val k = rotation(doubleArrayOf(0.0, 1.0, 0.0), 3 * degree)
    val seenAhead = times(k, doubleArrayOf(0.0, 0.0, 1.0))
    assertTrue("the camera looked to the right", seenAhead[0] > 0)
    assertVector(doubleArrayOf(0.0, 0.0, 1.0), shown(stitch, 33_367, seenAhead), 1e-6)
    // The output pixel straight ahead shows the point 3 degrees to the left of the picture's centre
    val ahead = shown(stitch, 33_367, doubleArrayOf(0.0, 0.0, 1.0))
    assertTrue("the front shows the left of the picture", ahead[0] < -0.05)
    // The first frame, unturned, draws the stitch as it is
    assertVector(doubleArrayOf(0.0, 0.0, 1.0), shown(stitch, 0, doubleArrayOf(0.0, 0.0, 1.0)), 1e-7)
  }

  // ---- The table, the time base, the identity

  @Test
  fun isTheIdentityWithoutATable() {
    val stitch = StabilizedStitch()
    assertArrayEquals(floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f), stitch.matrixAt(123_456), 0f)
    assertArrayEquals(StabilizedStitch.identity(), StabilizedStitch.matrixOf(null, 5), 0f)
    // A table taken away: the identity again
    stitch.table = tableOf(longArrayOf(0), listOf(quaternion(doubleArrayOf(0.0, 1.0, 0.0), 0.3)))
    stitch.table = null
    assertArrayEquals(StabilizedStitch.identity(), stitch.matrixAt(0), 0f)
  }

  @Test
  fun findsTheFrameOnTheTimelineWithTheTimeBaseOfTheSideBySideEffect() {
    // A turn about y of 1 degree a frame, 30 frames a second; the effect of a player started at 2 s gets the times
    // of its frames 2 s early (StabilizedFrames.timeBaseUs)
    val step = 33_367L
    val times = LongArray(300) { it * step }
    val table = tableOf(times, List(300) { quaternion(doubleArrayOf(0.0, 1.0, 0.0), it * degree) })
    val effect = stitchOf(table).also { it.timeBaseUs = StabilizedFrames.timeBaseUs(true, 2_000) }
    val lens = stitchOf(table).also { it.timeBaseUs = StabilizedFrames.timeBaseUs(false, 2_000) }
    assertEquals(2_000_000L, effect.timeBaseUs)
    assertEquals(0L, lens.timeBaseUs)
    // Frame 90 (3.003 s on the timeline): the effect gets it at 1.003 s, the lens compositor at 3.003 s
    val frame = 90
    val expected = matrixOf(quaternion(doubleArrayOf(0.0, 1.0, 0.0), frame * degree))
    val e = doubleArrayOf(0.3, -0.2, 0.9)
    assertVector(times(transpose(expected), e), glsl(effect.matrixAt(times[frame] - 2_000_000L), e), 1e-6)
    assertVector(times(transpose(expected), e), glsl(lens.matrixAt(times[frame]), e), 1e-6)
  }

  @Test
  fun reportsTheFirstFrameDrawnWithEachTable() {
    var reports = 0
    val stitch = StabilizedStitch { reports++ }
    stitch.matrixAt(0)
    assertEquals("no table, no report", 0, reports)
    val table = tableOf(longArrayOf(0), listOf(doubleArrayOf(1.0, 0.0, 0.0, 0.0)))
    stitch.table = table
    stitch.matrixAt(0)
    stitch.matrixAt(33_000)
    assertEquals(1, reports)
    // The same table again: still once; another one (the switch turned off and on brings the same, a new media
    // another): once more
    stitch.table = table
    stitch.matrixAt(66_000)
    assertEquals(1, reports)
    stitch.table = null
    stitch.table = table
    stitch.matrixAt(99_000)
    assertEquals(2, reports)
  }

  private fun transpose(m: Array<DoubleArray>) = Array(3) { r -> DoubleArray(3) { c -> m[c][r] } }
}
