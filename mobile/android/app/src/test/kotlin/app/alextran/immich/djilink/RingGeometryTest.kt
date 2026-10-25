package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.tan

/** Where the arcs fall on a picture's border (p2/design-obstacle-ring-2026-10-25.md, 2.2 and 2.4), for 16:9 and 4:3 */
class RingGeometryTest {
  private val boxes = listOf(1920.0 to 1080.0, 800.0 to 600.0)

  private fun assertPoint(expected: Pair<Double, Double>, actual: Pair<Double, Double>) {
    assertEquals(expected.first, actual.first, 1e-6)
    assertEquals(expected.second, actual.second, 1e-6)
  }

  @Test
  fun theFrontIsTheTopEdgeAndEachEdgeHoldsNinetyDegrees() {
    for ((w, h) in boxes) {
      assertPoint(w / 2 to 0.0, RingGeometry.borderPoint(0.0, w, h))
      assertPoint(w to 0.0, RingGeometry.borderPoint(45.0, w, h))
      assertPoint(w to h / 2, RingGeometry.borderPoint(90.0, w, h))
      assertPoint(w / 2 to h, RingGeometry.borderPoint(180.0, w, h))
      assertPoint(0.0 to h / 2, RingGeometry.borderPoint(-90.0, w, h))
      // 30 degrees on the top edge, tan(30) of the half width right of the centre
      val thirty = RingGeometry.borderPoint(30.0, w, h)
      assertPoint(w / 2 + tan(Math.toRadians(30.0)) * w / 2 to 0.0, thirty)
      // And back
      for (bearing in listOf(0.0, 30.0, 45.0, 90.0, 135.0, 180.0, -90.0, -150.0)) {
        val (x, y) = RingGeometry.borderPoint(bearing, w, h)
        assertEquals(bearing, ObstacleRing.normalize(RingGeometry.bearingOf(x, y, w, h)).let {
          if (bearing == 180.0 && it == -180.0) 180.0 else it
        }, 1e-6)
      }
    }
  }

  @Test
  fun theWindowAndTheDepth() {
    assertEquals(1.0, RingGeometry.window(0.0), 1e-9)
    assertEquals(0.5, RingGeometry.window(30.0), 1e-9)
    assertEquals(0.5, RingGeometry.window(-30.0), 1e-9)
    assertEquals(0.146, RingGeometry.window(45.0), 1e-3)
    assertEquals(0.0, RingGeometry.window(60.0), 1e-9)
    assertEquals(0.0, RingGeometry.window(120.0), 1e-9)
    assertEquals(30.0, RingGeometry.depth(0.0, 50.0), 1e-9)
    assertEquals(50.0, RingGeometry.depth(1.0, 50.0), 1e-9)
  }

  @Test
  fun anArcAheadGlowsAtTheTopCentreAndLeavesTheBottomEmpty() {
    val arc = ObstacleRing.arc(0.0, 1.0, RingSettings())
    val segments = RingGeometry.segments(listOf(arc), 1600.0, 900.0, 32)
    val strongest = segments.maxByOrNull { it.alpha }!!
    assertEquals(RingGeometry.Edge.TOP, strongest.edge)
    assertEquals(0.5, (strongest.from + strongest.to) / 2, 1.0 / 32)
    assertTrue(segments.none { it.edge == RingGeometry.Edge.BOTTOM })
    assertTrue(segments.all { it.alpha <= arc.opacity + 1e-9 })
  }

  @Test
  fun whereTwoArcsMeetTheLargerWinsAndTheyNeverAddUp() {
    val settings = RingSettings()
    val ahead = ObstacleRing.arc(0.0, 1.0, settings)
    val right = ObstacleRing.arc(90.0, 2.5, settings)
    val both = RingGeometry.segments(listOf(ahead, right), 1000.0, 1000.0, 36)
    val alone = RingGeometry.segments(listOf(ahead), 1000.0, 1000.0, 36).associateBy { it.edge to it.from }
    for (segment in both) {
      val one = alone[segment.edge to segment.from]
      if (one != null) {
        assertTrue(segment.alpha >= one.alpha - 1e-9)
      }
      assertTrue(segment.alpha <= ahead.opacity + 1e-9)
    }
    // The right edge's centre takes the right arc's colour
    val middleRight = both.first { it.edge == RingGeometry.Edge.RIGHT && it.from < 0.5 && it.to >= 0.5 }
    assertEquals(right.argb, middleRight.argb)
  }

  @Test
  fun theEvenGlowIsTheSameAllAround() {
    val even = ObstacleRing.arc(null, 2.0, RingSettings())
    val segments = RingGeometry.segments(listOf(even), 1280.0, 720.0, 16)
    assertEquals(64, segments.size)
    segments.forEach { assertEquals(even.opacity, it.alpha, 1e-9) }
    assertTrue(RingGeometry.segments(emptyList(), 1280.0, 720.0, 16).isEmpty())
  }
}
