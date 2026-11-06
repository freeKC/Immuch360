package app.alextran.immich.spherical

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stabilisation table of the 360° player (issue 14): the lookup of the rotation of a frame at its presentation
 * time, and the frame conversion into what Media3's camera motion listener takes. The sign convention is pinned with a
 * synthetic rotation, through the formulas of Media3 1.10.0 written here apart from the code under test: its
 * equirectangular mesh (Projection.createEquirectangular), its conversion of an angle axis
 * (FrameRotationQueue.getRotationMatrixFromAngleAxis: x, -y, -z, then Matrix.setRotateM, a right handed rotation), and
 * its drawing (SceneRenderer.drawFrame: the view projection times that rotation times each vertex).
 */
class StabilizationTableTest {
  private val degree = PI / 180

  // ---- Math of the tests, apart from the code under test: 3 x 3 matrices row major, vectors as DoubleArray

  /** The rotation by [angle] radians about the unit [axis], right handed (Rodrigues), as Matrix.setRotateM builds it */
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

  private fun times(a: Array<DoubleArray>, b: Array<DoubleArray>) =
    Array(3) { r -> DoubleArray(3) { c -> a[r][0] * b[0][c] + a[r][1] * b[1][c] + a[r][2] * b[2][c] } }

  /** The quaternion (w, x, y, z) of the rotation by [angle] about the unit [axis] */
  private fun quaternion(axis: DoubleArray, angle: Double): DoubleArray {
    val n = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
    val s = sin(angle / 2) / n
    return doubleArrayOf(cos(angle / 2), axis[0] * s, axis[1] * s, axis[2] * s)
  }

  /** The rotation matrix of the unit quaternion [q] (w, x, y, z), acting on vectors */
  private fun matrixOf(q: DoubleArray): Array<DoubleArray> {
    val (w, x, y, z) = q.toList()
    return arrayOf(
      doubleArrayOf(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)),
      doubleArrayOf(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)),
      doubleArrayOf(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)),
    )
  }

  /** What Media3 makes of the angle axis [a] of a camera motion: x, -y, -z, then the rotation by its length */
  private fun media3Rotation(a: FloatArray): Array<DoubleArray> {
    val axis = doubleArrayOf(a[0].toDouble(), -a[1].toDouble(), -a[2].toDouble())
    val angle = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
    return if (angle == 0.0) rotation(doubleArrayOf(1.0, 0.0, 0.0), 0.0) else rotation(axis, angle)
  }

  /**
   * The vertex of Media3's equirectangular sphere for the texture coordinates (u, v) of the picture, v from the top
   * (the renderer samples 1 - t with t from the bottom, TEX_MATRIX_WHOLE): theta = 2 pi u, phi = pi / 2 - pi v,
   * (-sin theta cos phi, sin phi, cos theta cos phi)
   */
  private fun media3Vertex(u: Double, v: Double): DoubleArray {
    val theta = 2 * PI * u
    val phi = PI / 2 - PI * v
    return doubleArrayOf(-sin(theta) * cos(phi), sin(phi), cos(theta) * cos(phi))
  }

  /**
   * The view direction of the stitch for the same point of the picture (dual_fisheye_math.dart viewDirection):
   * longitude (2 u - 1) pi, latitude pi / 2 - pi v, (cos lat sin lon, -sin lat, cos lat cos lon); x to the right, y
   * down, z forward
   */
  private fun viewDirection(u: Double, v: Double): DoubleArray {
    val lon = (2 * u - 1) * PI
    val lat = PI / 2 - PI * v
    return doubleArrayOf(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon))
  }

  /** The direction of Media3's sphere frame (OpenGL, y up, z backward) of the view direction [d] */
  private fun glOf(d: DoubleArray) = doubleArrayOf(d[0], -d[1], -d[2])

  private fun assertVector(expected: DoubleArray, actual: DoubleArray, tolerance: Double, message: String = "") {
    for (i in 0 until 3) assertEquals("$message [$i]", expected[i], actual[i], tolerance)
  }

  private fun tableOf(times: LongArray, quaternions: List<DoubleArray>): StabilizationTable =
    StabilizationTable.of(times, quaternions.flatMap { it.toList() }.toDoubleArray()) { error("refused: $it") }!!

  // ---- The frame conversion

  @Test
  fun theMeshOfMedia3ShowsAPictureWhereTheStitchMeansIt() {
    // Each point of the equirectangular picture: Media3's vertex is the view direction of the stitch with y and z
    // negated, the change of frame Media3 also applies to the angle axis of a camera motion
    for (u in listOf(0.05, 0.25, 0.4, 0.5, 0.62, 0.75, 0.9)) {
      for (v in listOf(0.02, 0.2, 0.5, 0.7, 0.98)) {
        assertVector(glOf(viewDirection(u, v)), media3Vertex(u, v), 1e-12, "u $u v $v")
      }
    }
    // The centre of the picture straight ahead (OpenGL -z), its top up, its right half to the right
    assertVector(doubleArrayOf(0.0, 0.0, -1.0), media3Vertex(0.5, 0.5), 1e-12)
    assertVector(doubleArrayOf(0.0, 1.0, 0.0), media3Vertex(0.5, 0.0), 1e-12)
    assertVector(doubleArrayOf(1.0, 0.0, 0.0), media3Vertex(0.75, 0.5), 1e-12)
  }

  @Test
  fun aCameraPitchedDownHasItsCentreDrawnBelowTheFront() {
    // The camera looks 10 degrees below the horizon (its forward z goes to (0, sin 10, cos 10) of the level view, y
    // down) and the target is level: the correction is that rotation, about x by -10 degrees
    val k = quaternion(doubleArrayOf(1.0, 0.0, 0.0), -10 * degree)
    val table = tableOf(longArrayOf(0), listOf(k))
    val m = media3Rotation(table.angleAxisAt(0))
    // The centre of the stitched picture, what the camera looked at, is drawn 10 degrees below the front of the
    // sphere: the viewer looking ahead sees the horizon
    val centre = times(m, media3Vertex(0.5, 0.5))
    assertVector(doubleArrayOf(0.0, -sin(10 * degree), -cos(10 * degree)), centre, 1e-6)
    // And the point of the picture 10 degrees above its centre is the horizon: drawn straight ahead
    val above = times(m, media3Vertex(0.5, 0.5 - 10.0 / 180))
    assertVector(doubleArrayOf(0.0, 0.0, -1.0), above, 1e-6)
  }

  @Test
  fun aRolledCameraHasItsHorizonDrawnLevel() {
    // The camera rolled 15 degrees about its forward axis: the world's right (1, 0, 0) is seen at C^T (1, 0, 0)
    val roll = quaternion(doubleArrayOf(0.0, 0.0, 1.0), 15 * degree)
    val camera = matrixOf(roll)
    val seenRight = DoubleArray(3) { camera[0][it] }
    val table = tableOf(longArrayOf(0), listOf(roll))
    val m = media3Rotation(table.angleAxisAt(0))
    // That point of the picture is drawn at the right of the sphere, on the horizon
    assertVector(doubleArrayOf(1.0, 0.0, 0.0), times(m, glOf(seenRight)), 1e-6)
  }

  @Test
  fun anyCorrectionDrawsTheViewDirectionDWhereKdSays() {
    // Random rotations about random axes: Media3's matrix of the angle axis turns the vertex of d to the direction of
    // K d in its frame, for points all over the picture
    val random = java.util.Random(14)
    repeat(50) {
      val axis = doubleArrayOf(random.nextGaussian(), random.nextGaussian(), random.nextGaussian())
      val angle = (random.nextDouble() * 2 - 1) * PI * 0.95
      val q = quaternion(axis, angle)
      val k = matrixOf(q)
      val table = tableOf(longArrayOf(0), listOf(q))
      val m = media3Rotation(table.angleAxisAt(0))
      for (u in listOf(0.1, 0.5, 0.8)) {
        for (v in listOf(0.3, 0.5, 0.9)) {
          val d = viewDirection(u, v)
          assertVector(glOf(times(k, d)), times(m, media3Vertex(u, v)), 1e-5, "angle $angle u $u v $v")
        }
      }
      // q and -q are the same rotation: the same angle axis
      val negated = tableOf(longArrayOf(0), listOf(DoubleArray(4) { -q[it] }))
      assertArrayEquals(table.angleAxisAt(0), negated.angleAxisAt(0), 1e-6f)
    }
  }

  @Test
  fun theAngleAxisIsTheAxisTimesTheAngle() {
    assertArrayEquals(floatArrayOf(0f, 0f, 0f), StabilizationMath.angleAxis(doubleArrayOf(1.0, 0.0, 0.0, 0.0)), 0f)
    val quarter = StabilizationMath.angleAxis(quaternion(doubleArrayOf(0.0, 2.0, 0.0), PI / 2))
    assertArrayEquals(floatArrayOf(0f, (PI / 2).toFloat(), 0f), quarter, 1e-6f)
    // Half a turn, and a rotation written with w < 0: the angle stays within pi
    val half = StabilizationMath.angleAxis(quaternion(doubleArrayOf(0.0, 0.0, 1.0), PI))
    assertArrayEquals(floatArrayOf(0f, 0f, PI.toFloat()), half, 1e-6f)
    val long = StabilizationMath.angleAxis(quaternion(doubleArrayOf(1.0, 0.0, 0.0), 1.5 * PI))
    assertArrayEquals(floatArrayOf((-0.5 * PI).toFloat(), 0f, 0f), long, 1e-6f)
  }

  // ---- The lookup

  @Test
  fun givesTheRotationOfTheFrameAtItsTimeBlendedBetweenFrames() {
    // A constant turn about y of 2 degrees a frame, 30 frames a second
    val step = 33_367L
    val times = LongArray(30) { it * step }
    val table = tableOf(times, List(30) { quaternion(doubleArrayOf(0.0, 1.0, 0.0), 2.0 * it * degree) })

    for (i in listOf(0, 1, 7, 15, 29)) {
      assertArrayEquals(floatArrayOf(0f, (2.0 * i * degree).toFloat(), 0f), table.angleAxisAt(times[i]), 1e-6f)
    }
    // A quarter of the way from frame 10 to 11: 20.5 degrees
    assertArrayEquals(
      floatArrayOf(0f, (20.5 * degree).toFloat(), 0f),
      table.angleAxisAt(times[10] + step / 4),
      1e-5f,
    )
    // Before the first frame and after the last: those frames
    assertArrayEquals(floatArrayOf(0f, 0f, 0f), table.angleAxisAt(-500_000), 1e-7f)
    assertArrayEquals(floatArrayOf(0f, (58 * degree).toFloat(), 0f), table.angleAxisAt(times[29] + 10_000_000), 1e-6f)
    assertEquals(30, table.size)
    assertEquals(0L, table.firstTimeUs)
    assertEquals(29 * step, table.lastTimeUs)
  }

  @Test
  fun blendsAlongTheShorterArcWhateverTheSignOfTheNeighbours() {
    val a = quaternion(doubleArrayOf(1.0, 0.0, 0.0), 10 * degree)
    val b = quaternion(doubleArrayOf(1.0, 0.0, 0.0), 20 * degree).map { -it }.toDoubleArray()
    val table = tableOf(longArrayOf(0, 1000), listOf(a, b))
    assertArrayEquals(floatArrayOf((15 * degree).toFloat(), 0f, 0f), table.angleAxisAt(500), 1e-6f)
    val q = table.quaternionAt(500)
    assertEquals(1.0, sqrt(q.sumOf { it * it }), 1e-12)
  }

  @Test
  fun findsTheFramesOfALongTableByBinarySearch() {
    // An hour at 30 frames a second, the rotation of frame i about z by i / 1000 radian
    val count = 108_000
    val times = LongArray(count) { it * 33_367L + 1_234 }
    val values = DoubleArray(4 * count)
    for (i in 0 until count) {
      val q = quaternion(doubleArrayOf(0.0, 0.0, 1.0), (i % 3000) / 1000.0)
      for (j in 0 until 4) values[4 * i + j] = q[j]
    }
    val table = StabilizationTable.of(times, values)!!
    for (i in listOf(0, 1, 2999, 3000, 54_321, 107_999)) {
      assertEquals("frame $i", (i % 3000) / 1000.0, table.angleAxisAt(times[i])[2].toDouble(), 1e-6)
    }
  }

  @Test
  fun refusesATableItCannotUse() {
    val reasons = mutableListOf<String>()
    val one = doubleArrayOf(1.0, 0.0, 0.0, 0.0)
    assertNull(StabilizationTable.of(null, one) { reasons += it })
    assertNull(StabilizationTable.of(longArrayOf(), doubleArrayOf()) { reasons += it })
    assertNull(StabilizationTable.of(longArrayOf(0, 1), one) { reasons += it })
    assertNull(StabilizationTable.of(longArrayOf(5, 5), one + one) { reasons += it })
    assertNull(StabilizationTable.of(longArrayOf(0), doubleArrayOf(2.0, 0.0, 0.0, 0.0)) { reasons += it })
    assertNull(StabilizationTable.of(longArrayOf(0), doubleArrayOf(Double.NaN, 0.0, 0.0, 0.0)) { reasons += it })
    assertEquals(6, reasons.size)
    assertTrue(reasons[2], reasons[2].contains("4 values for 2 frames"))
    assertTrue(reasons[3], reasons[3].contains("does not follow"))
    assertNotNull(StabilizationTable.of(longArrayOf(0, 1), one + one))
  }

  @Test
  fun aSmallTurnOfTheCameraIsUndoneOnTheSphere() {
    // The camera shook 3 degrees to the right between two frames while the target kept its heading: the correction
    // turns the sphere 3 degrees back about the vertical, so the world point ahead stays ahead
    val shake = quaternion(doubleArrayOf(0.0, 1.0, 0.0), 3 * degree)
    val table = tableOf(longArrayOf(0, 33_367), listOf(doubleArrayOf(1.0, 0.0, 0.0, 0.0), shake))
    val m = media3Rotation(table.angleAxisAt(33_367))
    // The camera turned right about its down axis (y down): what it sees at its centre is the world 3 degrees to the
    // right; the sphere draws it there
    val k = rotation(doubleArrayOf(0.0, 1.0, 0.0), 3 * degree)
    val seenAhead = times(k, doubleArrayOf(0.0, 0.0, 1.0))
    assertTrue("the camera looked to the right", seenAhead[0] > 0)
    assertVector(glOf(seenAhead), times(m, media3Vertex(0.5, 0.5)), 1e-6)
    // The two rotations compose as matrices do: Media3's matrix is the change of frame of K
    val p = arrayOf(doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, -1.0, 0.0), doubleArrayOf(0.0, 0.0, -1.0))
    val expected = times(times(p, k), p)
    for (r in 0 until 3) for (c in 0 until 3) assertEquals(expected[r][c], m[r][c], 1e-6)
    assertTrue(abs(m[0][2]) > 0.05)
  }
}
