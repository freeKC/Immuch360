package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The obstacle ring turned into arcs (p2/design-obstacle-ring-2026-10-25.md, 2.2 and 2.3), on synthetic rings: no
 * capture holds an obstacle at a known place and distance yet. It reads, decides and draws, and nothing else.
 */
class ObstacleRingTest {
  private val defaults = RingSettings()
  private val sided = RingSettings(directional = true)

  /** 72 sectors with no reading but those given, in metres */
  private fun ring(vararg sectors: Pair<Int, Double>): List<Double?> =
    MutableList<Double?>(ObstacleRing.SECTORS) { null }.also { list -> sectors.forEach { (k, d) -> list[k] = d } }

  private fun arcsOf(distances: List<Double?>, settings: RingSettings = sided): List<RingArc> =
    ObstacleRing.arcs(distances, ObstacleRing.closeSectors(distances, emptySet(), settings.farM), settings)

  @Test
  fun theSectorsAreTheSmallestOfTheirFiveIndexesAndTheFirstCoversIndexes358To2() {
    val values = IntArray(360) { TelemetryFields.OBSTACLE_NO_READING }
    values[358] = 1_200
    values[2] = 900
    values[3] = 700
    values[90] = 2_000
    val sectors = ObstacleRing.sectors(values)!!
    assertEquals(72, sectors.size)
    assertEquals(900, sectors[0])
    assertEquals(700, sectors[1])
    assertEquals(2_000, sectors[18])
    // 60000 in all five: no reading, never a distance
    assertNull(sectors[2])
    assertNull(sectors[71])
    // A ring of another count gives no sectors
    assertNull(ObstacleRing.sectors(IntArray(359)))
  }

  @Test
  fun theBearingsOfTheMappingAndOfOthers() {
    assertEquals(0.0, ObstacleRing.bearingDeg(0), 1e-9)
    assertEquals(90.0, ObstacleRing.bearingDeg(18), 1e-9)
    assertEquals(180.0, ObstacleRing.bearingDeg(36), 1e-9)
    assertEquals(-90.0, ObstacleRing.bearingDeg(54), 1e-9)
    assertEquals(-5.0, ObstacleRing.bearingDeg(71), 1e-9)
    val counter = RingMapping(noseSector = 0, clockwise = false)
    assertEquals(-90.0, ObstacleRing.bearingDeg(18, counter), 1e-9)
    val shifted = RingMapping(noseSector = 2, clockwise = true)
    assertEquals(0.0, ObstacleRing.bearingDeg(2, shifted), 1e-9)
    assertEquals(-10.0, ObstacleRing.bearingDeg(0, shifted), 1e-9)
    // And back
    assertEquals(54, ObstacleRing.sectorAt(-90.0))
    assertEquals(18, ObstacleRing.sectorAt(-90.0, counter))
    assertEquals(2, ObstacleRing.sectorAt(0.0, shifted))
  }

  @Test
  fun theStrengthTheOpacityAndTheColour() {
    assertEquals(0.0, ObstacleRing.strength(3.0, defaults), 1e-9)
    assertEquals(0.5, ObstacleRing.strength(2.0, defaults), 1e-9)
    assertEquals(1.0, ObstacleRing.strength(1.0, defaults), 1e-9)
    assertEquals(1.0, ObstacleRing.strength(0.4, defaults), 1e-9)
    assertEquals(0.15, ObstacleRing.opacity(0.0), 1e-9)
    assertEquals(0.425, ObstacleRing.opacity(0.5), 1e-9)
    assertEquals(0.70, ObstacleRing.opacity(1.0), 1e-9)
    assertEquals(ObstacleRing.AMBER, ObstacleRing.argb(0.0))
    assertEquals(ObstacleRing.RED, ObstacleRing.argb(1.0))
    // FF B3 00 and E5 39 35, mixed per channel, rounded half up
    assertEquals(0xFFF2761B.toInt(), ObstacleRing.argb(0.5))
  }

  @Test
  fun aSectorJoinsAtGlowFromAndLeavesPastItsHysteresis() {
    val inAt = ObstacleRing.closeSectors(ring(5 to 3.0), emptySet(), 3.0)
    assertEquals(setOf(5), inAt)
    assertEquals(setOf(5), ObstacleRing.closeSectors(ring(5 to 3.25), inAt, 3.0))
    assertEquals(emptySet<Int>(), ObstacleRing.closeSectors(ring(5 to 3.35), inAt, 3.0))
    // Not close before: 3.25 m does not bring it in
    assertEquals(emptySet<Int>(), ObstacleRing.closeSectors(ring(5 to 3.25), emptySet(), 3.0))
  }

  @Test
  fun oneObstacleGivesOneArcCentredOnIt() {
    val arcs = arcsOf(ring(6 to 1.6, 7 to 1.8))
    assertEquals(1, arcs.size)
    assertEquals(30.0, arcs[0].centreDeg!!, 1e-9)
    assertEquals(1.6, arcs[0].distanceM, 1e-9)
  }

  @Test
  fun twoObstaclesNinetyDegreesApartMakeTwoArcsThirtyApartOneAtTheNearer() {
    val apart = arcsOf(ring(0 to 2.0, 18 to 1.5))
    assertEquals(listOf(90.0, 0.0), apart.map { it.centreDeg })
    val near = arcsOf(ring(0 to 2.0, 6 to 1.5))
    assertEquals(1, near.size)
    assertEquals(30.0, near[0].centreDeg!!, 1e-9)
    assertEquals(1.5, near[0].distanceM, 1e-9)
  }

  @Test
  fun fiveObstaclesAroundGiveTheFourNearest() {
    val arcs = arcsOf(ring(0 to 2.5, 14 to 1.0, 29 to 2.0, 43 to 1.5, 58 to 2.8))
    assertEquals(4, arcs.size)
    assertEquals(listOf(1.0, 1.5, 2.0, 2.5), arcs.map { it.distanceM })
  }

  @Test
  fun aWallOverHalfTheRingGivesArcsAtItsMinimaAtLeast45DegreesApart() {
    // A wall ahead, nearest at the nose, farther toward the sides: sectors -18 to +18
    val wall = (-18..18).map { offset -> Math.floorMod(offset, 72) to 0.8 + 0.05 * kotlin.math.abs(offset) }
    val arcs = arcsOf(ring(*wall.toTypedArray()))
    assertTrue(arcs.size in 2..4)
    assertEquals(0.0, arcs[0].centreDeg!!, 1e-9)
    for (i in arcs.indices) {
      for (j in arcs.indices) {
        if (i != j) {
          assertTrue(ObstacleRing.separation(arcs[i].centreDeg!!, arcs[j].centreDeg!!) > 45.0)
        }
      }
    }
  }

  @Test
  fun noReadingGivesNoArcAndTheEvenModeOneArcWithoutBearing() {
    assertTrue(arcsOf(ring()).isEmpty())
    // Far: nothing either
    assertTrue(arcsOf(ring(0 to 4.0)).isEmpty())
    val even = arcsOf(ring(0 to 2.5, 18 to 1.2), defaults)
    assertEquals(1, even.size)
    assertNull(even[0].centreDeg)
    assertEquals(1.2, even[0].distanceM, 1e-9)
  }

  @Test
  fun theSettingsAreClamped() {
    assertEquals(RingSettings(6.0, 2.5), RingSettings(9.0, 4.0).clamped())
    assertEquals(RingSettings(1.5, 1.0), RingSettings(1.0, 1.4).clamped())
    assertEquals(RingSettings(3.0, 2.5), RingSettings(3.0, 2.75).clamped())
    assertEquals(RingSettings(2.0, 1.5), RingSettings(2.0, 1.75).clamped())
    assertEquals(RingSettings(3.0, 0.5), RingSettings(3.0, 0.2).clamped())
    assertEquals(RingSettings(), RingSettings(Double.NaN, Double.NaN).clamped())
  }

  @Test
  fun theTickStartsHalfwayAndQuickens() {
    assertEquals(0, ObstacleRing.tickIntervalMs(2.1, defaults))
    assertEquals(1_000, ObstacleRing.tickIntervalMs(2.0, defaults))
    assertEquals(625, ObstacleRing.tickIntervalMs(1.5, defaults))
    assertEquals(250, ObstacleRing.tickIntervalMs(1.0, defaults))
    assertEquals(200, ObstacleRing.tickIntervalMs(0.75, defaults))
    assertEquals(150, ObstacleRing.tickIntervalMs(0.5, defaults))
    assertEquals(150, ObstacleRing.tickIntervalMs(0.3, defaults))
    assertEquals(0, ObstacleRing.tickIntervalMs(null, defaults))
    // With other distances, halfway moves with them
    assertEquals(1_000, ObstacleRing.tickIntervalMs(1.0, RingSettings(1.5, 0.5)))
    assertEquals(0, ObstacleRing.tickIntervalMs(1.1, RingSettings(1.5, 0.5)))
  }

  @Test
  fun theSampleTimeline() {
    fun nearest(sectors: List<Int?>): Pair<Int, Int>? =
      sectors.withIndex().filter { it.value != null }.minByOrNull { it.value!! }?.let { it.index to it.value!! }
    // Ahead at 4.0 m, then closing in
    assertEquals(0 to 4_000, nearest(ObstacleRing.sample(0)!!))
    val two = nearest(ObstacleRing.sample(2_000)!!)!!
    assertEquals(0, two.first)
    assertEquals(1_867, two.second)
    // Halfway to the left at 0.8 m
    assertEquals(ObstacleRing.sectorAt(-45.0) to 800, nearest(ObstacleRing.sample(4_000)!!))
    // On the left at 0.8 m, and a second one behind on the right at 2.0 m
    val six = ObstacleRing.sample(6_000)!!
    assertEquals(800, six[54])
    assertEquals(2_000, six[27])
    // Then nothing, and over at 8 s
    assertTrue(ObstacleRing.sample(7_500)!!.all { it == null })
    assertNull(ObstacleRing.sample(8_000))
    // Placed with the mapping: a ring that grows the other way puts the left on sector 18
    assertEquals(800, ObstacleRing.sample(6_000, RingMapping(0, clockwise = false))!![18])
  }
}
