package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The obstacle indicator as a circle around the picture's centre (FreeKC, 25 October, "comme dans Fortnite"): the
 * front at the top of the circle, arcs about 70 degrees wide, the even glow a whole faint circle. The same numbers as
 * dji_live_obstacle.widget.dart.
 */
class RingCircleTest {
  private fun assertPoint(expected: Pair<Double, Double>, actual: Pair<Double, Double>) {
    assertEquals(expected.first, actual.first, 1e-6)
    assertEquals(expected.second, actual.second, 1e-6)
  }

  @Test
  fun aQuarterOfThePictureHeightTheFrontAtTheTop() {
    assertEquals(270.0, RingCircle.radius(1080.0), 1e-9)
    assertEquals(48.6, RingCircle.fullThickness(1080.0), 1e-9)
    val (cx, cy) = 960.0 to 540.0
    assertPoint(960.0 to 270.0, RingCircle.point(0.0, cx, cy, 270.0))
    assertPoint(1230.0 to 540.0, RingCircle.point(90.0, cx, cy, 270.0))
    assertPoint(960.0 to 810.0, RingCircle.point(180.0, cx, cy, 270.0))
    assertPoint(690.0 to 540.0, RingCircle.point(-90.0, cx, cy, 270.0))
    // A strong arc is the full thickness, a faint one 60 % of it
    assertEquals(48.6, RingCircle.thickness(1.0, 48.6), 1e-9)
    assertEquals(29.16, RingCircle.thickness(0.0, 48.6), 1e-9)
  }

  @Test
  fun anArcIsAboutSeventyDegreesWide() {
    assertEquals(1.0, RingCircle.window(0.0), 1e-9)
    assertEquals(0.5, RingCircle.window(22.5), 1e-9)
    assertEquals(0.5, RingCircle.window(-22.5), 1e-9)
    assertEquals(0.0, RingCircle.window(45.0), 1e-9)
    assertEquals(0.0, RingCircle.window(90.0), 1e-9)
    // What shows above a tenth of its strength spans 60 to 90 degrees
    val arc = ObstacleRing.arc(0.0, 1.0, RingSettings())
    val lit = RingCircle.pieces(listOf(arc)).filter { it.alpha >= arc.opacity * 0.1 }
    val span = lit.sumOf { it.toDeg - it.fromDeg }
    assertTrue("span $span", span in 60.0..90.0)
  }

  @Test
  fun anArcAheadGlowsAtTheTopAndLeavesTheBottomEmpty() {
    val arc = ObstacleRing.arc(0.0, 1.0, RingSettings())
    val pieces = RingCircle.pieces(listOf(arc))
    val strongest = pieces.maxByOrNull { it.alpha }!!
    assertEquals(0.0, (strongest.fromDeg + strongest.toDeg) / 2, 360.0 / RingCircle.PIECES)
    assertTrue(pieces.none { kotlin.math.abs(ObstacleRing.normalize((it.fromDeg + it.toDeg) / 2)) > 90 })
    assertTrue(pieces.all { it.alpha <= arc.opacity + 1e-9 })
    assertEquals(arc.argb, strongest.argb)
    // An arc on the right glows at three o'clock
    val right = RingCircle.pieces(listOf(ObstacleRing.arc(90.0, 1.0, RingSettings()))).maxByOrNull { it.alpha }!!
    assertEquals(90.0, (right.fromDeg + right.toDeg) / 2, 360.0 / RingCircle.PIECES)
  }

  @Test
  fun whereTwoArcsMeetTheLargerWins() {
    val near = ObstacleRing.arc(0.0, 0.8, RingSettings())
    val far = ObstacleRing.arc(30.0, 2.8, RingSettings())
    val pieces = RingCircle.pieces(listOf(near, far))
    for (piece in pieces) {
      val middle = (piece.fromDeg + piece.toDeg) / 2
      val a = near.opacity * RingCircle.window(ObstacleRing.separation(middle, 0.0))
      val b = far.opacity * RingCircle.window(ObstacleRing.separation(middle, 30.0))
      assertEquals(maxOf(a, b), piece.alpha, 1e-9)
      assertEquals(if (a >= b) near.argb else far.argb, piece.argb)
    }
  }

  @Test
  fun theEvenGlowIsTheWholeCircleFaint() {
    val even = ObstacleRing.arc(null, 0.8, RingSettings())
    val pieces = RingCircle.pieces(listOf(even))
    assertEquals(RingCircle.PIECES, pieces.size)
    assertTrue(pieces.all { it.alpha == even.opacity })
    // Never stronger than the even glow's own cap
    assertTrue(even.opacity <= 0.35 + 1e-9)
    assertEquals(360.0, pieces.sumOf { it.toDeg - it.fromDeg }, 1e-6)
  }

  @Test
  fun theNumberSitsOutsideTheCircleByTheNearestArc() {
    val (cx, cy) = 960.0 to 540.0
    val ahead = RingCircle.numberPoint(ObstacleRing.arc(0.0, 1.4, RingSettings()), cx, cy, 1080.0, 30.0)
    assertPoint(960.0 to 540.0 - (270.0 + 24.3 + 30.0), ahead)
    // With the even glow, low on the left
    val even = RingCircle.numberPoint(ObstacleRing.arc(null, 1.4, RingSettings()), cx, cy, 1080.0, 30.0)
    assertTrue(even.first < cx && even.second > cy)
  }

  @Test
  fun nothingToDrawWithoutArcs() {
    assertTrue(RingCircle.pieces(emptyList()).isEmpty())
  }
}
