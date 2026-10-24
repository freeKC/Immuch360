package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The obstacle alert (p2/design-final-2026-10-24.md, 4.5 and 4.7), fed with synthetic readings: no capture holds an
 * obstacle at a known distance yet. It decides what to draw and how fast to beep, and nothing else.
 */
class ObstacleAlertTest {
  private val alert = ObstacleAlert()

  private fun near(metres: Double?, ageMs: Long = 50, motorsOn: Boolean? = true, landing: Boolean = false) =
    ObstacleInput(nearestM = metres, ageMs = ageMs, motorsOn = motorsOn, landing = landing)

  @Test
  fun onAtThreeMetresStillOnUnderThreeAndAHalfOffFromThere() {
    assertFalse(alert.decide(true, near(3.2), 0).on)
    assertTrue(alert.decide(true, near(3.0), 100).on)
    assertTrue(alert.decide(true, near(3.4), 1_200).on)
    assertFalse(alert.decide(true, near(3.5), 1_300).on)
    // Off again: 3.4 m is not close enough to come back on
    assertFalse(alert.decide(true, near(3.4), 1_400).on)
  }

  @Test
  fun onceOnItStaysOnForOneSecond() {
    assertTrue(alert.decide(true, near(2.0), 0).on)
    assertTrue(alert.decide(true, near(6.0), 500).on)
    assertTrue(alert.decide(true, near(6.0), 999).on)
    assertFalse(alert.decide(true, near(6.0), 1_000).on)
  }

  @Test
  fun theDecisionCarriesTheNearestDistanceAndNoSideYet() {
    val decision = alert.decide(true, near(1.8), 0)
    assertTrue(decision.on)
    assertTrue(decision.listening)
    assertEquals(1.8, decision.distanceM!!, 1e-9)
    assertNull(decision.side)
    // A side only once a capture names one
    val sided = ObstacleAlert().decide(true, near(1.8).copy(side = ObstacleSide.LEFT), 0)
    assertEquals(ObstacleSide.LEFT, sided.side)
  }

  @Test
  fun aWarningAloneTurnsItOnWithNoNumber() {
    val decision = alert.decide(true, ObstacleInput(nearestM = null, ageMs = 50, motorsOn = true, warning = true), 0)
    assertTrue(decision.on)
    assertNull(decision.distanceM)
    assertEquals(ObstacleAlert.WARNING_BEEP_MS, decision.beepIntervalMs)
  }

  @Test
  fun aLandingAndStoppedMotorsNeverAlert() {
    assertFalse(alert.decide(true, near(0.3, landing = true), 0).on)
    assertFalse(alert.decide(true, near(0.3, motorsOn = false), 100).on)
    // Nothing seen in any sector is not an alert, and it is not a clear way either: the glyph only listens
    val nothing = alert.decide(true, near(null), 200)
    assertFalse(nothing.on)
    assertTrue(nothing.listening)
  }

  @Test
  fun aStaleRingStopsTheAlertAndSaysSoForFiveSecondsWithoutSound() {
    assertTrue(alert.decide(true, near(1.0), 0).on)
    val stopped = alert.decide(true, near(1.0, ageMs = 601), 700)
    assertFalse(stopped.on)
    assertTrue(stopped.stopped)
    assertEquals(0, stopped.beepIntervalMs)
    assertFalse(stopped.listening)
    assertTrue(alert.decide(true, near(1.0, ageMs = 5_000), 5_699).stopped)
    assertFalse(alert.decide(true, near(1.0, ageMs = 5_100), 5_700).stopped)
  }

  @Test
  fun aRingThatStopsWithTheMotorsEndsQuietly() {
    assertTrue(alert.decide(true, near(1.0), 0).on)
    val landed = alert.decide(true, near(1.0, ageMs = 700, motorsOn = false), 700)
    assertFalse(landed.on)
    assertFalse(landed.stopped)
  }

  @Test
  fun freshDataEndsTheStoppedLine() {
    alert.decide(true, near(1.0), 0)
    assertTrue(alert.decide(true, near(1.0, ageMs = 900), 900).stopped)
    val back = alert.decide(true, near(1.2), 1_000)
    assertFalse(back.stopped)
    assertTrue(back.on)
  }

  @Test
  fun notOfferedIsAlwaysOffWhateverArrives() {
    val decision = alert.decide(false, near(0.2), 0)
    assertEquals(ObstacleDecision.OFF, decision)
    assertEquals(ObstacleDecision.OFF, alert.decide(false, near(0.2, ageMs = 5_000), 1_000))
  }

  @Test
  fun theBeepQuickensAsTheDroneGetsCloser() {
    assertEquals(600, ObstacleAlert.beepIntervalMs(3.0))
    assertEquals(375, ObstacleAlert.beepIntervalMs(1.75))
    assertEquals(150, ObstacleAlert.beepIntervalMs(0.5))
    assertEquals(150, ObstacleAlert.beepIntervalMs(0.2))
    assertEquals(600, ObstacleAlert.beepIntervalMs(3.4))
  }

  @Test
  fun theAlertReadsTheRingTheMotorsAndTheLandingOfTheValues() {
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
          flags = TelemetryFields.FLAGS_MOTORS_RUNNING,
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
      obstacles = Timed(ObstacleReading(nearestM = 1.4, nearestIndex = 12, noReading = 0), 120, false),
    )
    val input = obstacleInputOf(values)
    assertEquals(1.4, input.nearestM!!, 1e-9)
    assertEquals(120L, input.ageMs)
    assertEquals(true, input.motorsOn)
    assertTrue(input.landing)
    val none = obstacleInputOf(null)
    assertNull(none.nearestM)
    assertNull(none.ageMs)
    assertNull(none.motorsOn)
  }
}

/** The beeps of the alert, with a fake beeper and a fake clock */
class ObstacleToneTest {
  private var beeps = mutableListOf<Long>()
  private var now = 0L
  private val tone = ObstacleTone { beeps.add(now) }

  private fun run(untilMs: Long, intervalMs: Int, soundOn: Boolean = true, screenShown: Boolean = true) {
    while (now <= untilMs) {
      tone.update(intervalMs, soundOn, screenShown, now)
      now += 50
    }
  }

  @Test
  fun aBeepAtEachInterval() {
    run(1_000, 300)
    assertEquals(listOf(0L, 300L, 600L, 900L), beeps)
  }

  @Test
  fun noBeepWhenMutedOrWithNoPictureScreenOrWhenSilent() {
    run(1_000, 300, soundOn = false)
    run(2_000, 300, screenShown = false)
    run(3_000, 0)
    assertTrue(beeps.isEmpty())
  }

  @Test
  fun theFirstBeepComesAtOnceWhenTheAlertComesOn() {
    run(500, 0)
    run(1_000, 600)
    assertEquals(listOf(550L), beeps)
  }

  @Test
  fun theTestIsThreeBeepsThreeHundredMillisecondsApart() {
    assertEquals(3, ObstacleTone.TEST_BEEPS)
    assertEquals(300L, ObstacleTone.TEST_INTERVAL_MS)
  }
}
