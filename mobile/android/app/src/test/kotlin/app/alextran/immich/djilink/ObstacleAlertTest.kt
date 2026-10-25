package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The decision of the obstacle ring (p2/design-obstacle-ring-2026-10-25.md, 2.1 to 2.5 and 3), fed with synthetic
 * rings: no capture holds an obstacle at a known place and distance yet. It decides what to draw and how fast to tick,
 * and nothing else.
 */
class ObstacleAlertTest {
  private val alert = ObstacleAlert()
  private val even = RingSettings()
  private val sided = RingSettings(directional = true)

  /** A ring with one obstacle at [sector], [metres] away, the other sectors reading nothing */
  private fun at(
    metres: Double?,
    sector: Int = 0,
    ageMs: Long = 50,
    motorsOn: Boolean? = true,
    landing: Boolean = false,
  ): ObstacleInput {
    val sectors = List(ObstacleRing.SECTORS) { k -> if (k == sector && metres != null) (metres * 1000).toInt() else null }
    return ObstacleInput(sectors, metres, ageMs, motorsOn, landing)
  }

  @Test
  fun nothingShowsUntilASectorIsUnderGlowFrom() {
    val far = alert.decide(true, even, at(3.2), 0)
    assertFalse(far.on)
    assertTrue(far.arcs.isEmpty())
    assertTrue(far.listening)
    val near = alert.decide(true, even, at(3.0), 100)
    assertTrue(near.on)
    assertEquals(1, near.arcs.size)
    assertNull(near.arcs[0].centreDeg)
    assertTrue(near.even)
  }

  @Test
  fun inAtGlowFromOutPastItsHysteresisAfterOneSecond() {
    assertTrue(alert.decide(true, even, at(3.0), 0).on)
    // 3.25 m: still close; 3.5 m: smoothed to 3.34, past 3.3
    assertTrue(alert.decide(true, even, at(3.25), 100).arcs.isNotEmpty())
    assertTrue(alert.decide(true, even, at(3.25), 1_100).arcs.isNotEmpty())
    val leaving = alert.decide(true, even, at(3.5), 1_200)
    assertFalse(leaving.on)
    assertTrue(leaving.arcs.isEmpty())
  }

  @Test
  fun onceShownItStaysAtLeastOneSecondWithTheLastArcsAndNoTick() {
    val first = alert.decide(true, even, at(0.8), 0)
    assertTrue(first.on)
    assertTrue(first.tickIntervalMs > 0)
    val held = alert.decide(true, even, at(null), 500)
    assertTrue(held.on)
    assertEquals(first.arcs, held.arcs)
    assertEquals(0, held.tickIntervalMs)
    assertTrue(alert.decide(true, even, at(null), 999).on)
    assertFalse(alert.decide(true, even, at(null), 1_000).on)
  }

  @Test
  fun aNearingObstacleShowsAtOnceALeavingOneHalfwayPerRing() {
    assertEquals(2.0, alert.decide(true, even, at(2.0), 0).nearestM!!, 1e-9)
    assertEquals(1.0, alert.decide(true, even, at(1.0), 100).nearestM!!, 1e-9)
    assertEquals(1.5, alert.decide(true, even, at(2.0), 200).nearestM!!, 1e-9)
    assertEquals(1.75, alert.decide(true, even, at(2.0), 300).nearestM!!, 1e-9)
    // The same ring seen again at the next tick is not smoothed twice
    assertEquals(1.75, alert.decide(true, even, at(2.0, ageMs = 100), 350).nearestM!!, 1e-9)
  }

  @Test
  fun theSideShowsOnlyWhenAskedAndOnTheObstaclesSide() {
    val sideless = alert.decide(true, even, at(1.6, sector = 6), 0)
    assertTrue(sideless.even)
    assertNull(sideless.arcs.single().centreDeg)
    val side = ObstacleAlert().decide(true, sided, at(1.6, sector = 6), 0)
    assertFalse(side.even)
    assertEquals(30.0, side.arcs.single().centreDeg!!, 1e-9)
    // Another mapping, the same ring: the side follows the constant
    val other = ObstacleAlert().decide(true, sided, at(1.6, sector = 6), 0, mapping = RingMapping(0, clockwise = false))
    assertEquals(-30.0, other.arcs.single().centreDeg!!, 1e-9)
    // A ring of another count: its nearest only, as an even glow, whatever the setting
    val odd = ObstacleAlert().decide(true, sided, ObstacleInput(null, 1.2, 50, true), 0)
    assertTrue(odd.even)
    assertEquals(1.2, odd.arcs.single().distanceM, 1e-9)
  }

  @Test
  fun notOfferedStaleMotorsOffOrALandingShowNothing() {
    assertEquals(ObstacleDecision.OFF, alert.decide(false, even, at(0.2), 0))
    assertFalse(alert.decide(true, even, at(0.3, landing = true), 0).on)
    assertFalse(alert.decide(true, even, at(0.3, motorsOn = false), 100).on)
    // Stale: 0.6 s on the phone, 1.5 s on a receiver
    assertFalse(ObstacleAlert().decide(true, even, at(0.3, ageMs = 601), 0).listening)
    val receiver = ObstacleAlert()
    assertTrue(receiver.decide(true, even, at(0.3, ageMs = 1_400), 0, ObstacleAlert.RECEIVER_STALE_MS).on)
    assertFalse(ObstacleAlert().decide(true, even, at(0.3, ageMs = 1_501), 0, ObstacleAlert.RECEIVER_STALE_MS).on)
    // Nothing seen in any sector is not an alert, and it is not a clear way either
    val nothing = alert.decide(true, even, at(null), 5_000)
    assertFalse(nothing.on)
    assertTrue(nothing.arcs.isEmpty())
  }

  @Test
  fun aStaleRingTurnsTheLastArcsWhiteForFiveSecondsWithoutTick() {
    assertTrue(alert.decide(true, sided, at(1.0, sector = 18), 0).on)
    val stopped = alert.decide(true, sided, at(1.0, sector = 18, ageMs = 601), 700)
    assertFalse(stopped.on)
    assertTrue(stopped.stopped)
    assertEquals(0, stopped.tickIntervalMs)
    assertEquals(ObstacleRing.WHITE, stopped.arcs.single().argb)
    assertEquals(90.0, stopped.arcs.single().centreDeg!!, 1e-9)
    assertEquals(ObstacleRing.STOPPED_OPACITY, stopped.arcs.single().opacity, 1e-9)
    val half = alert.decide(true, sided, at(1.0, ageMs = 3_000), 3_200)
    assertEquals(ObstacleRing.STOPPED_OPACITY / 2, half.arcs.single().opacity, 1e-9)
    assertTrue(alert.decide(true, sided, at(1.0, ageMs = 5_000), 5_699).stopped)
    val over = alert.decide(true, sided, at(1.0, ageMs = 5_100), 5_700)
    assertFalse(over.stopped)
    assertTrue(over.arcs.isEmpty())
  }

  @Test
  fun aRingThatStopsWithTheMotorsEndsQuietly() {
    assertTrue(alert.decide(true, even, at(1.0), 0).on)
    val landed = alert.decide(true, even, at(1.0, ageMs = 700, motorsOn = false), 700)
    assertFalse(landed.on)
    assertFalse(landed.stopped)
    // And the motors reported off during the fade end it too
    val other = ObstacleAlert()
    other.decide(true, even, at(1.0), 0)
    assertTrue(other.decide(true, even, at(1.0, ageMs = 700), 700).stopped)
    assertFalse(other.decide(true, even, at(1.0, ageMs = 900, motorsOn = false), 900).stopped)
  }

  @Test
  fun freshDataEndsTheStoppedFade() {
    alert.decide(true, even, at(1.0), 0)
    assertTrue(alert.decide(true, even, at(1.0, ageMs = 900), 900).stopped)
    val back = alert.decide(true, even, at(1.2), 1_000)
    assertFalse(back.stopped)
    assertTrue(back.on)
  }

  @Test
  fun theTickStartsHalfwayWithTheSideAtStrongGlowFromEvenlyAndTheTapOnlyWithinStrongGlowFrom() {
    fun decide(metres: Double, settings: RingSettings = sided) = ObstacleAlert().decide(true, settings, at(metres), 0)
    assertEquals(0, decide(2.1).tickIntervalMs)
    assertEquals(1_000, decide(2.0).tickIntervalMs)
    assertEquals(625, decide(1.5).tickIntervalMs)
    assertEquals(250, decide(1.0).tickIntervalMs)
    assertEquals(150, decide(0.5).tickIntervalMs)
    assertEquals(150, decide(0.3).tickIntervalMs)
    assertFalse(decide(1.5).haptic)
    assertTrue(decide(1.0).haptic)
    assertTrue(decide(0.4).haptic)
    // The even glow, which says no side and lasts a whole flight in a room: silent until "Strong glow from", then once
    // a second down to 150 ms at half of it
    assertEquals(0, decide(2.0, even).tickIntervalMs)
    assertEquals(0, decide(1.5, even).tickIntervalMs)
    assertEquals(1_000, decide(1.0, even).tickIntervalMs)
    assertEquals(150, decide(0.5, even).tickIntervalMs)
    assertFalse(decide(1.5, even).haptic)
    assertTrue(decide(1.0, even).haptic)
    // The pilot's distances move both
    val indoor = RingSettings(1.5, 0.5, directional = true)
    assertEquals(0, ObstacleAlert().decide(true, indoor, at(1.2), 0).tickIntervalMs)
    assertEquals(1_000, ObstacleAlert().decide(true, indoor, at(1.0), 0).tickIntervalMs)
    assertTrue(ObstacleAlert().decide(true, indoor, at(1.6), 0).arcs.isEmpty())
  }

  @Test
  fun theStrengthAndTheColourFollowTheDistances() {
    val faint = ObstacleAlert().decide(true, even, at(3.0), 0).arcs.single()
    assertEquals(0.0, faint.strength, 1e-9)
    assertEquals(ObstacleRing.AMBER, faint.argb)
    val strong = ObstacleAlert().decide(true, sided, at(0.8), 0).arcs.single()
    assertEquals(1.0, strong.strength, 1e-9)
    assertEquals(0.70, strong.opacity, 1e-9)
    assertEquals(ObstacleRing.RED, strong.argb)
    // The even glow on four edges: as red, half as strong
    val evenStrong = ObstacleAlert().decide(true, even, at(0.8), 0).arcs.single()
    assertEquals(0.35, evenStrong.opacity, 1e-9)
    assertEquals(ObstacleRing.RED, evenStrong.argb)
  }

  @Test
  fun theSampleRunsThroughTheSameDecision() {
    val sample = ObstacleAlert()
    val start = sample.decide(true, sided, obstacleSampleInput(0)!!, 0)
    assertTrue(start.arcs.isEmpty())
    val ahead = sample.decide(true, sided, obstacleSampleInput(2_000)!!, 2_000)
    assertEquals(0.0, ahead.arcs.first().centreDeg!!, 1e-9)
    val six = sample.decide(true, sided, obstacleSampleInput(6_000)!!, 6_000)
    assertEquals(listOf(-90.0, 135.0), six.arcs.map { it.centreDeg })
    assertNull(obstacleSampleInput(8_000))
  }

  @Test
  fun theRingReadsTheSectorsTheMotorsAndTheLandingOfTheValues() {
    val sectors = List<Int?>(ObstacleRing.SECTORS) { if (it == 3) 1_400 else null }
    val values = TelemetryValues(
      flight = Timed(
        FlightReading(
          heightM = 1.2,
          speedsMps = listOf(0.0, 0.0, 0.0),
          pitchDeg = 0.0,
          rollDeg = 0.0,
          headingDeg = 0.0,
          mode = TelemetryFields.MODE_AUTOMATIC_LANDING,
          inAir = true,
          motorsOn = true,
          satellites = 0,
          groundHeightM = 0.0,
          motorTimeS = 10.0,
          flags = TelemetryFields.FLAG_IN_AIR or TelemetryFields.FLAG_MOTORS_ON,
        ),
        80,
        false,
      ),
      gimbal = null,
      battery = null,
      remoteBatteryPercent = null,
      link = LinkReadings(null, null, null, null, null, null),
      layoutMismatches = 0,
      decoded = emptyMap(),
      obstacles = Timed(ObstacleReading(nearestM = 1.4, nearestIndex = 15, noReading = 355, sectorsMm = sectors), 120, false),
    )
    val input = obstacleInputOf(values)
    assertEquals(1.4, input.nearestM!!, 1e-9)
    assertEquals(sectors, input.sectorsMm)
    assertEquals(120L, input.ageMs)
    assertEquals(true, input.motorsOn)
    assertTrue(input.landing)
    val none = obstacleInputOf(null)
    assertNull(none.nearestM)
    assertNull(none.sectorsMm)
    assertNull(none.ageMs)
    assertNull(none.motorsOn)
  }
}

/** The ticks of the ring, with a fake beeper, a fake tap and a fake clock */
class ObstacleToneTest {
  private var ticks = mutableListOf<Long>()
  private var taps = mutableListOf<Long>()
  private var now = 0L
  private val tone = ObstacleTone({ ticks.add(now) }) { taps.add(now) }

  private fun run(
    untilMs: Long,
    intervalMs: Int,
    soundOn: Boolean = true,
    screenShown: Boolean = true,
    tapOn: Boolean = false,
  ) {
    while (now <= untilMs) {
      tone.update(intervalMs, soundOn, screenShown, now, tapOn)
      now += 50
    }
  }

  @Test
  fun aTickAtEachInterval() {
    run(1_000, 300)
    assertEquals(listOf(0L, 300L, 600L, 900L), ticks)
    assertTrue(taps.isEmpty())
  }

  @Test
  fun noTickWhenMutedOrWithNoPictureScreenOrWhenSilent() {
    run(1_000, 300, soundOn = false)
    run(2_000, 300, screenShown = false)
    run(3_000, 0)
    assertTrue(ticks.isEmpty())
  }

  @Test
  fun theFirstTickComesAtOnceWhenTheRingAsksForIt() {
    run(500, 0)
    run(1_000, 600)
    assertEquals(listOf(550L), ticks)
  }

  @Test
  fun theTapComesWithTheTicksOnlyWhenAskedEvenMuted() {
    run(600, 250, tapOn = true)
    assertEquals(listOf(0L, 250L, 500L), taps)
    assertEquals(taps, ticks)
    run(1_200, 250, soundOn = false, tapOn = true)
    assertEquals(listOf(0L, 250L, 500L), ticks)
    assertEquals(listOf(0L, 250L, 500L, 750L, 1_000L), taps)
  }

  @Test
  fun playTheSoundIsThreeTicksThreeHundredMillisecondsApartWithNoTap() {
    val scheduled = mutableListOf<Pair<Long, () -> Unit>>()
    tone.playTest { delayMs, tick -> scheduled += delayMs to tick }
    assertEquals(listOf(0L, 300L, 600L), scheduled.map { it.first })
    // Nothing sounds before the handler runs them
    assertTrue(ticks.isEmpty())
    for ((delayMs, tick) in scheduled) {
      now = delayMs
      tick()
    }
    assertEquals(listOf(0L, 300L, 600L), ticks)
    assertTrue(taps.isEmpty())
  }

  @Test
  fun theTickIsThirtyMillisecondsOfA1600HzSineWithRamps() {
    val samples = TickSound.samples()
    assertEquals(TickSound.SAMPLE_RATE * 30 / 1000, samples.size)
    assertEquals(0, samples.first().toInt())
    assertTrue(kotlin.math.abs(samples.last().toInt()) < 200)
    assertTrue(samples.maxOf { it.toInt() } > 30_000)
    // 1.6 kHz over 30 ms: 48 periods, 96 sign changes
    val signs = samples.map { it.toInt() }.filter { it != 0 }.map { it > 0 }
    val changes = signs.zipWithNext().count { (a, b) -> a != b }
    assertTrue("$changes sign changes", changes in 95..97)
    // The ramps: within the first 2.5 ms never more than half of full scale, so the tick does not click
    val ramp = TickSound.SAMPLE_RATE * TickSound.RAMP_MS / 1000
    assertTrue(samples.take(ramp / 2).all { kotlin.math.abs(it.toInt()) <= Short.MAX_VALUE / 2 + 1 })
  }
}
