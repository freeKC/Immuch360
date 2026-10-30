package app.alextran.immich.immersive

import com.meta.spatial.core.Vector3
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where a flat screen stands, what a ray points at, how a grab moves it, how far it goes and how large it grows (the
 * movable flat screens of Gaurav Mukherjee, gmfun/Immuch360 branch quest/flat-3d, redone on our quad code).
 */
class FlatScreenGeometryTest {
  private val eyes = Vector3(0f, 1.6f, 0f)
  private val ahead = ScreenPlace.inFront(eyes, Vector3(0f, 0f, 1f), 2f)

  private fun ray(yawDeg: Float, pitchDeg: Float = 0f): Vector3 {
    val yaw = Math.toRadians(yawDeg.toDouble())
    val pitch = Math.toRadians(pitchDeg.toDouble())
    return Vector3((sin(yaw) * cos(pitch)).toFloat(), sin(pitch).toFloat(), (cos(yaw) * cos(pitch)).toFloat())
  }

  private fun assertVector(expected: Vector3, actual: Vector3) {
    assertEquals("x of $actual", expected.x, actual.x, 1e-4f)
    assertEquals("y of $actual", expected.y, actual.y, 1e-4f)
    assertEquals("z of $actual", expected.z, actual.z, 1e-4f)
  }

  // Place

  @Test
  fun `a screen goes along the horizontal gaze, at the height of the eyes`() {
    assertVector(Vector3(0f, 1.6f, 2f), ahead.center)
    assertEquals(0f, ahead.yawDeg, 1e-4f)
    val lookingDown = ScreenPlace.inFront(eyes, Vector3(0f, -0.6f, 0.8f), 2f)
    assertVector(Vector3(0f, 1.6f, 2f), lookingDown.center)
    val right = ScreenPlace.inFront(eyes, Vector3(1f, 0f, 0f), 1.5f)
    assertEquals(90f, right.yawDeg, 1e-3f)
    assertVector(Vector3(1.5f, 1.6f, 0f), right.center)
    assertVector(Vector3(1f, 0f, 0f), right.direction)
  }

  @Test
  fun `a gaze straight up or down puts the screen ahead along +z`() {
    val up = ScreenPlace.inFront(eyes, Vector3(0f, 1f, 0f), 2f)
    assertVector(Vector3(0f, 1.6f, 2f), up.center)
  }

  @Test
  fun `at another distance a screen keeps its direction and the angle it is seen at from the eyes`() {
    val raised = ahead.copy(height = 2.1f)
    val nearer = raised.at(1f)
    assertEquals(1f, nearer.distance, 1e-6f)
    assertEquals(raised.yawDeg, nearer.yawDeg, 1e-6f)
    assertEquals(1.85f, nearer.height, 1e-4f)
  }

  // Ray

  @Test
  fun `a ray from the eyes or the hand hits the screen it points at, within its edges`() {
    assertTrue(FlatScreenGeometry.hits(ahead, 2f, 1f, eyes, ray(0f)))
    // From a hand at the waist, aimed at the top right corner
    val hand = Vector3(0.3f, 1.1f, 0.2f)
    val corner = Vector3(0.95f, 2.05f, 2f)
    assertTrue(FlatScreenGeometry.hits(ahead, 2f, 1f, hand, corner - hand))
    // Past the right edge (1 m from the center, plus the margin), above the top edge, behind the user
    assertFalse(FlatScreenGeometry.hits(ahead, 2f, 1f, eyes, Vector3(1.2f, 0f, 2f)))
    assertFalse(FlatScreenGeometry.hits(ahead, 2f, 1f, eyes, Vector3(0f, 0.65f, 2f)))
    assertFalse(FlatScreenGeometry.hits(ahead, 2f, 1f, eyes, ray(180f)))
    // Parallel to the screen
    assertFalse(FlatScreenGeometry.hits(ahead, 2f, 1f, eyes, ray(90f)))
  }

  @Test
  fun `the margin around the edges makes the screen easier to grab`() {
    val justOut = Vector3(1f + FlatScreenGeometry.HIT_MARGIN_M / 2, 0f, 2f)
    assertTrue(FlatScreenGeometry.hits(ahead, 2f, 1f, eyes, justOut))
    assertFalse(FlatScreenGeometry.hits(ahead, 2f, 1f, eyes, justOut, margin = 0f))
  }

  @Test
  fun `a screen turned to the side is hit from its own side`() {
    val right = ScreenPlace.inFront(eyes, Vector3(1f, 0f, 0f), 2f)
    assertTrue(FlatScreenGeometry.hits(right, 2f, 1f, eyes, ray(90f)))
    assertTrue(FlatScreenGeometry.hits(right, 2f, 1f, eyes, Vector3(1f, 0f, 0.45f)))
    assertFalse(FlatScreenGeometry.hits(right, 2f, 1f, eyes, ray(0f)))
  }

  // Drag

  @Test
  fun `a grab follows the ray around the eyes, keeping the point grabbed under it`() {
    // Grabbed 10 degrees right of its center, the ray then goes to 40 degrees
    val drag = ScreenDrag(ahead, eyes, ray(10f))
    val moved = drag.place(eyes, ray(40f))!!
    assertEquals(30f, moved.yawDeg, 1e-3f)
    assertEquals(1.6f, moved.height, 1e-4f)
    assertEquals(2f, moved.distance, 1e-6f)
    assertVector(eyes, moved.eyes)
  }

  @Test
  fun `a grab raises or lowers the screen with the ray`() {
    val drag = ScreenDrag(ahead, eyes, ray(0f))
    val pitch = Math.toDegrees(atan(0.5 / 2.0)).toFloat()
    assertEquals(2.1f, drag.place(eyes, ray(0f, pitch))!!.height, 1e-4f)
    assertEquals(1.1f, drag.place(eyes, ray(0f, -pitch))!!.height, 1e-4f)
  }

  @Test
  fun `a grab from the hand moves the screen the way the hand points`() {
    val hand = Vector3(0.25f, 1.15f, 0.15f)
    val drag = ScreenDrag(ahead, hand, ahead.center - hand)
    val target = Vector3(2f * sin(Math.toRadians(25.0)).toFloat(), 1.6f, 2f * cos(Math.toRadians(25.0)).toFloat())
    val moved = drag.place(hand, target - hand)!!
    assertEquals(25f, moved.yawDeg, 0.05f)
    assertEquals(1.6f, moved.height, 1e-3f)
  }

  @Test
  fun `a grab keeps the screen within a reach of the eyes in height, and a ray straight up moves nothing`() {
    val drag = ScreenDrag(ahead, eyes, ray(0f))
    assertEquals(1.6f + 2f * FlatScreenGeometry.MAX_ELEVATION, drag.place(eyes, ray(0f, 80f))!!.height, 1e-4f)
    assertEquals(1.6f - 2f * FlatScreenGeometry.MAX_ELEVATION, drag.place(eyes, ray(0f, -80f))!!.height, 1e-4f)
    assertNull(drag.place(eyes, Vector3(0f, 1f, 0f)))
  }

  // Distance and size

  @Test
  fun `the distance steps through the list from the nearest one, within its ends`() {
    assertEquals(2.5f, FlatScreenGeometry.nextDistance(2f, 1), 0f)
    assertEquals(1.75f, FlatScreenGeometry.nextDistance(2f, -1), 0f)
    assertEquals(2.5f, FlatScreenGeometry.nextDistance(2.2f, 1), 0f)
    assertEquals(FlatScreenGeometry.DISTANCES_M.last(), FlatScreenGeometry.nextDistance(8f, 1), 0f)
    assertEquals(FlatScreenGeometry.DISTANCES_M.first(), FlatScreenGeometry.nextDistance(0.75f, -1), 0f)
    assertEquals(2f, FlatScreenGeometry.DEFAULT_DISTANCE_M, 0f)
    assertTrue(FlatScreenGeometry.DEFAULT_DISTANCE_M in FlatScreenGeometry.DISTANCES_M.toList())
  }

  @Test
  fun `a screen brought nearer keeps its width in meters, so it looks larger, within the size bounds`() {
    val width = FlatScreenGeometry.width(48f, 2f)
    val nearer = FlatScreenGeometry.angleAtDistance(48f, 2f, 1.5f)
    assertEquals(width, FlatScreenGeometry.width(nearer, 1.5f), 1e-4f)
    assertTrue(nearer > 48f)
    assertEquals(FlatScreenGeometry.MAX_ANGLE_DEG, FlatScreenGeometry.angleAtDistance(100f, 2f, 0.75f), 0f)
    assertEquals(FlatScreenGeometry.MIN_ANGLE_DEG, FlatScreenGeometry.angleAtDistance(20f, 1f, 8f), 0f)
    assertEquals(40f, FlatScreenGeometry.angleAtDistance(48f, 2f, 1.5f, maxAngleDeg = 40f), 0f)
  }

  @Test
  fun `the size steps by six degrees within its bounds`() {
    assertEquals(54f, FlatScreenGeometry.nextAngle(48f, 1), 0f)
    assertEquals(42f, FlatScreenGeometry.nextAngle(48f, -1), 0f)
    assertEquals(FlatScreenGeometry.MAX_ANGLE_DEG, FlatScreenGeometry.nextAngle(108f, 1), 0f)
    assertEquals(FlatScreenGeometry.MIN_ANGLE_DEG, FlatScreenGeometry.nextAngle(18f, -1), 0f)
    assertEquals(60f, FlatScreenGeometry.nextAngle(58f, 1, maxAngleDeg = 60f), 0f)
  }

  @Test
  fun `a width in meters reads back as the angle it covers`() {
    for (angle in listOf(15f, 48f, 60f, 110f)) {
      assertEquals(angle, FlatScreenGeometry.angleForWidth(FlatScreenGeometry.width(angle, 2.5f), 2.5f), 1e-3f)
    }
  }

  @Test
  fun `a new screen fits in 60 degrees wide and 40 high whatever its shape`() {
    assertEquals(60f, FlatScreenGeometry.fittingAngle(16f / 9f), 1e-3f)
    val height43 = Math.toDegrees(2 * atan(tan(Math.toRadians(FlatScreenGeometry.fittingAngle(4f / 3f) / 2.0)) * 0.75))
    assertEquals(40.0, height43, 1e-3)
    val portrait = FlatScreenGeometry.fittingAngle(9f / 16f)
    assertEquals(23.1f, portrait, 0.1f)
    // Unknown shape: 16:9
    assertEquals(60f, FlatScreenGeometry.fittingAngle(0f), 1e-3f)
  }

  @Test
  fun `a distance reads as meters, without trailing zeros`() {
    assertEquals("2", FlatScreenGeometry.meters(2f))
    assertEquals("1.5", FlatScreenGeometry.meters(1.5f))
    assertEquals("0.75", FlatScreenGeometry.meters(0.75f))
    assertEquals("1.25", FlatScreenGeometry.meters(1.25f))
  }

  // Stretch

  @Test
  fun `both hands pulled apart or together scale the screen by the ratio of their spread`() {
    val stretch = ScreenStretch()
    assertNull(stretch.width(0.5f))
    stretch.start(0.4f, 2f)
    assertEquals(4f, stretch.width(0.8f)!!, 1e-4f)
    assertEquals(1f, stretch.width(0.2f)!!, 1e-4f)
    stretch.end()
    assertNull(stretch.width(0.8f))
  }

  @Test
  fun `hands one over the other neither divide by nothing nor shrink the screen to nothing`() {
    val stretch = ScreenStretch()
    stretch.start(0f, 2f)
    assertEquals(2f * ScreenStretch.MIN_SPREAD_M / ScreenStretch.MIN_SPREAD_M, stretch.width(0f)!!, 1e-4f)
    assertEquals(2f * 0.5f / ScreenStretch.MIN_SPREAD_M, stretch.width(0.5f)!!, 1e-3f)
  }
}
