package app.alextran.immich.immersive.splat

import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The frame of the splat module, as measured on a Quest 3 on 31 October 2026: a point p of the file on an entity of
 * pose (t, q) shows at M (t + q p), M = diag(1, 1, -1). The viewer hands the module its poses converted so that the
 * splat shows at t + q (M p), where its meshes would be.
 */
class SplatModuleFrameTest {
  /** v rotated by the unit quaternion (w, x, y, z): v' = q v q* */
  private fun rotate(w: Double, x: Double, y: Double, z: Double, v: DoubleArray): DoubleArray {
    // t = 2 (q.xyz cross v); v' = v + w t + q.xyz cross t
    val tx = 2 * (y * v[2] - z * v[1])
    val ty = 2 * (z * v[0] - x * v[2])
    val tz = 2 * (x * v[1] - y * v[0])
    return doubleArrayOf(
      v[0] + w * tx + (y * tz - z * ty),
      v[1] + w * ty + (z * tx - x * tz),
      v[2] + w * tz + (x * ty - y * tx),
    )
  }

  private fun mirror(v: DoubleArray) = doubleArrayOf(v[0], v[1], -v[2])

  /** Where the module draws the point [p] of the file for the pose it was given (as measured) */
  private fun drawn(given: FloatArray, p: DoubleArray): DoubleArray {
    val q = given.map { it.toDouble() }
    val turned = rotate(q[3], q[4], q[5], q[6], p)
    return mirror(doubleArrayOf(q[0] + turned[0], q[1] + turned[1], q[2] + turned[2]))
  }

  private fun unit(w: Double, x: Double, y: Double, z: Double): DoubleArray {
    val n = sqrt(w * w + x * x + y * y + z * z)
    return doubleArrayOf(w / n, x / n, y / n, z / n)
  }

  private fun pose(x: Float, y: Float, z: Float, q: DoubleArray) =
    floatArrayOf(x, y, z, q[0].toFloat(), q[1].toFloat(), q[2].toFloat(), q[3].toFloat())

  private val poses =
    listOf(
      floatArrayOf(0f, 1.6f, 1.5f, 1f, 0f, 0f, 0f),
      floatArrayOf(1.2f, 1.0f, 0.25f, 1f, 0f, 0f, 0f),
      // Quaternion(-30, 60, 20) or so, and a yaw of the head with a pitch of half a turn
      pose(0.4f, 1.2f, -0.7f, unit(0.82, -0.12, 0.51, 0.22)),
      pose(-2f, 1.3f, 3f, unit(cos(0.9) * cos(1.2), sin(1.2), 0.0, sin(0.9))),
    )

  private val points =
    listOf(
      doubleArrayOf(0.0, 0.0, 0.0),
      doubleArrayOf(0.3, 0.0, 0.0),
      doubleArrayOf(0.0, 0.3, 0.0),
      doubleArrayOf(0.0, 0.0, 0.3),
      doubleArrayOf(-0.4, 1.1, 0.7),
    )

  @Test
  fun `a converted pose shows the file where a mesh of the same pose would be, true to life`() {
    for (pose in poses) {
      val given = SplatModuleFrame.toModule(pose)
      val q = pose.map { it.toDouble() }
      for (p in points) {
        // Where the viewer wants the point: the pose applied to the file as the module shows it (z mirrored)
        val turned = rotate(q[3], q[4], q[5], q[6], SplatModuleFrame.filePoint(p))
        val wanted = doubleArrayOf(q[0] + turned[0], q[1] + turned[1], q[2] + turned[2])
        assertArrayEquals(wanted, drawn(given, p), 1e-5)
      }
    }
  }

  @Test
  fun `a pose handed over as it is draws the splat at its mirror image, as build 38 did`() {
    // 1.5 m in front of a head that looks along +z: drawn 1.5 m behind it
    val pose = floatArrayOf(0f, 1.6f, 1.5f, 1f, 0f, 0f, 0f)
    assertArrayEquals(doubleArrayOf(0.0, 1.6, -1.5), drawn(pose, doubleArrayOf(0.0, 0.0, 0.0)), 1e-6)
    val converted = drawn(SplatModuleFrame.toModule(pose), doubleArrayOf(0.0, 0.0, 0.0))
    assertArrayEquals(doubleArrayOf(0.0, 1.6, 1.5), converted, 1e-6)
  }

  @Test
  fun `the conversion negates z and the x and y of the quaternion only, and twice is nothing`() {
    val pose = floatArrayOf(1f, 2f, 3f, 0.5f, 0.5f, -0.5f, 0.5f)
    assertArrayEquals(floatArrayOf(1f, 2f, -3f, 0.5f, -0.5f, 0.5f, 0.5f), SplatModuleFrame.toModule(pose), 0f)
    assertArrayEquals(pose, SplatModuleFrame.toModule(SplatModuleFrame.toModule(pose)), 0f)
    assertArrayEquals(doubleArrayOf(1.0, 2.0, -3.0), SplatModuleFrame.filePoint(doubleArrayOf(1.0, 2.0, 3.0)), 0.0)
  }

  @Test
  fun `the file shows unmirrored, its right handed axes staying right handed`() {
    // x cross y = z in the file; drawn, the images of the three axes keep that order
    for (pose in poses) {
      val given = SplatModuleFrame.toModule(pose)
      val o = drawn(given, doubleArrayOf(0.0, 0.0, 0.0))
      fun axis(p: DoubleArray) = drawn(given, p).let { doubleArrayOf(it[0] - o[0], it[1] - o[1], it[2] - o[2]) }
      val ax = axis(doubleArrayOf(1.0, 0.0, 0.0))
      val ay = axis(doubleArrayOf(0.0, 1.0, 0.0))
      val az = axis(doubleArrayOf(0.0, 0.0, 1.0))
      // In the left handed frame of the SDK a right handed triple is mirrored once: x cross y = -z
      val cross =
        doubleArrayOf(ax[1] * ay[2] - ax[2] * ay[1], ax[2] * ay[0] - ax[0] * ay[2], ax[0] * ay[1] - ax[1] * ay[0])
      val dot = cross[0] * az[0] + cross[1] * az[1] + cross[2] * az[2]
      assertTrue("$dot", dot < -0.99)
    }
  }
}
