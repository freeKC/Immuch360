package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The glue of the controller's tick (p2/review-obstacle-ring-2026-10-25.md, major 1 and minors 4 and 5): what the
 * decision is fed with from the source in use, the phone's relayed choices, this device's own and "Show a sample",
 * with synthetic values and records. Nothing here reaches the remote or the drone.
 */
class ObstacleRingTickerTest {
  private val phone = RingChoices(offered = true, settings = RingSettings(), haptic = true)

  /** A TV or a headset with the ring on for its screen, as by default */
  private val screen = RingChoices(offered = true)

  /** The values of the source in use: one obstacle at [sector], [metres] away, or no ring at all for null */
  private fun values(
    metres: Double?,
    sector: Int = 0,
    ringAgeMs: Long = 50,
    motorsOn: Boolean = true,
  ): TelemetryValues {
    val sectors = List(ObstacleRing.SECTORS) { k -> if (k == sector) metres?.let { (it * 1000).toInt() } else null }
    return TelemetryValues(
      flight = Timed(
        FlightReading(
          heightM = if (motorsOn) 1.2 else 0.0,
          speedsMps = listOf(0.0, 0.0, 0.0),
          pitchDeg = 0.0,
          rollDeg = 0.0,
          headingDeg = 0.0,
          mode = 0,
          inAir = motorsOn,
          motorsOn = motorsOn,
          satellites = 0,
          groundHeightM = 0.0,
          motorTimeS = 10.0,
          flags = if (motorsOn) TelemetryFields.FLAGS_MOTORS_RUNNING else 0L,
        ),
        40,
        false,
      ),
      gimbal = null,
      battery = null,
      remoteBatteryPercent = null,
      link = LinkReadings(null, null, null, null, null, null),
      layoutMismatches = 0,
      decoded = emptyMap(),
      obstacles = metres?.let {
        Timed(
          ObstacleReading(nearestM = it, nearestIndex = sector * 5, noReading = 0, sectorsMm = sectors),
          ringAgeMs,
          false,
        )
      },
    )
  }

  /** A phone's TELEMETRY record built at [phoneMs] on its clock, the ring [ringAgeMs] old there */
  private fun record(
    phoneMs: Long,
    metres: Double?,
    sector: Int = 0,
    ringAgeMs: Long = 50,
    ring: RelayObstacleRing? = RelayObstacleRing(offered = true, farM = 3.0, nearM = 1.0, directional = false),
  ) = RelayTelemetryRecord(
    phoneNs = phoneMs * 1_000_000,
    sequence = phoneMs / 100,
    link = RelayLinkFacts(source = "cable", state = "videoReady", aircraft = true, remote = true),
    values = values(metres, sector, ringAgeMs),
    phoneVideo = null,
    headsets = 1,
    unitsDropped = 0,
    obstacleRing = ring,
  )

  @Test
  fun aSampleEndsAsSoonAsTheMotorsStartAndTheRealRingIsDecidedAtThatTick() {
    val ticker = ObstacleRingTicker()
    val ground = RingSource.local(values(null, motorsOn = false))
    assertTrue(ticker.startSample(ground, 0))
    // Two seconds in: the made up obstacle ahead, about 1.9 m
    val sample = ticker.tick(ground, phone, 2_000).decision
    assertTrue(sample.on)
    assertEquals(1.87, sample.nearestM!!, 0.01)
    // The motors start with nothing close: the sample ends at once, and nothing of it is held
    val takeOff = ticker.tick(RingSource.local(values(5.0)), phone, 2_050)
    assertNull(ticker.sampleStartMs)
    assertFalse(takeOff.decision.on)
    assertTrue(takeOff.decision.arcs.isEmpty())
    assertEquals(0, takeOff.decision.tickIntervalMs)
    // And the real ring is decided from there on
    val real = ticker.tick(RingSource.local(values(1.2, sector = 18)), phone, 2_150).decision
    assertTrue(real.on)
    assertEquals(1.2, real.nearestM!!, 1e-9)
  }

  @Test
  fun aSampleTakesTheMotorsOfAPhonesRecordOnAReceiverToo() {
    val ticker = ObstacleRingTicker()
    // A TV whose phone has no drone in the air: no ring in its record, the motors off
    val idle = RingSource.received(
      record(10_000, null).copy(values = values(null, motorsOn = false)),
      sinceMs = 20,
    )
    assertTrue(ticker.startSample(idle, 0))
    assertTrue(ticker.tick(idle, screen, 2_000).decision.on)
    // The pilot takes off: the TV's sample ends at the next record
    val flying = RingSource.received(record(10_100, 5.0), sinceMs = 20)
    assertFalse(ticker.tick(flying, screen, 2_050).decision.on)
    assertNull(ticker.sampleStartMs)
  }

  @Test
  fun aSampleIsRefusedWhileTheMotorsRunAndEndsAfterEightSeconds() {
    val ticker = ObstacleRingTicker()
    assertFalse(ticker.startSample(RingSource.local(values(2.0)), 0))
    assertNull(ticker.sampleStartMs)
    val ground = RingSource.local(values(null, motorsOn = false))
    assertTrue(ticker.startSample(ground, 1_000))
    ticker.tick(ground, RingChoices(), 8_999)
    assertNotNull(ticker.sampleStartMs)
    val over = ticker.tick(ground, RingChoices(), 9_000)
    assertNull(ticker.sampleStartMs)
    assertEquals(ObstacleDecision.OFF, over.decision)
    // Leaving the picture screen ends it as well
    assertTrue(ticker.startSample(ground, 10_000))
    ticker.reset()
    assertNull(ticker.sampleStartMs)
  }

  @Test
  fun onAReceiverThePhonesRecordDecidesWhetherItIsOfferedItsDistancesAndItsSide() {
    val sided = RelayObstacleRing(offered = true, farM = 2.0, nearM = 0.75, directional = true)
    // This TV's own distances say nothing (the defaults) and it asks for the tap: the phone's record wins on the
    // distances and the side, and a TV never taps
    val tv = RingChoices(offered = true, settings = RingSettings(), haptic = true)
    val fromPhone = RingSource.received(record(10_000, 0.7, sector = 18, ring = sided), 20)
    val received = ObstacleRingTicker().tick(fromPhone, tv, 0)
    assertTrue(received.decision.on)
    assertEquals(90.0, received.decision.arcs.single().centreDeg!!, 1e-9)
    assertTrue(received.decision.haptic)
    assertFalse(received.tap)
    // The TV's own switch can only turn it off on its screen
    assertEquals(ObstacleDecision.OFF, ObstacleRingTicker().tick(fromPhone, tv.copy(offered = false), 0).decision)
    // And the phone's switch off turns it off on every screen, whatever the TV says
    val phoneOff = RingSource.received(record(10_000, 0.7, sector = 18, ring = sided.copy(offered = false)), 20)
    assertEquals(ObstacleDecision.OFF, ObstacleRingTicker().tick(phoneOff, tv, 0).decision)
    // The same ring on the phone, with its own choices: it taps
    val onPhone = ObstacleRingTicker().tick(RingSource.local(values(0.7, sector = 18)), phone, 0)
    assertTrue(onPhone.decision.on)
    assertNull(onPhone.decision.arcs.single().centreDeg)
    assertTrue(onPhone.tap)
    // A phone of an earlier build relays no choices: no ring, whatever this TV chose
    val earlier = RingSource.received(record(10_000, 0.7, ring = null), 20)
    assertEquals(ObstacleDecision.OFF, ObstacleRingTicker().tick(earlier, phone, 0).decision)
    // Nor before the first record
    assertEquals(ObstacleDecision.OFF, ObstacleRingTicker().tick(RingSource.received(null, 0), phone, 0).decision)
  }

  @Test
  fun aReceiverCallsTheRingStaleAfterOneAndAHalfSecondsThePhoneAfterSixHundredMilliseconds() {
    val tv = ObstacleRingTicker()
    assertTrue(tv.tick(RingSource.received(record(10_000, 1.2, ringAgeMs = 100), 1_300), screen, 0).decision.on)
    val late = tv.tick(RingSource.received(record(10_000, 1.2, ringAgeMs = 100), 1_450), screen, 150).decision
    assertFalse(late.on)
    assertTrue(late.stopped)
    val onPhone = ObstacleRingTicker()
    assertTrue(onPhone.tick(RingSource.local(values(1.2, ringAgeMs = 100)), phone, 0).decision.on)
    assertTrue(onPhone.tick(RingSource.local(values(1.2, ringAgeMs = 650)), phone, 550).decision.stopped)
  }

  @Test
  fun onAReceiverARingIsSmoothedOnceWhateverTheTransitOfEachRecord() {
    val tv = ObstacleRingTicker()
    fun nearest(record: RelayTelemetryRecord, sinceMs: Long, nowMs: Long): Double? =
      tv.tick(RingSource.received(record, sinceMs), screen, nowMs).decision.nearestM
    // A ring at 1.0 m read by the phone at 9 900 ms of its clock
    assertEquals(1.0, nearest(record(10_000, 1.0, ringAgeMs = 100), 20, 50_000)!!, 1e-9)
    // The next ring, at 2.0 m, read at 10 000 ms: a leaving obstacle is smoothed halfway
    assertEquals(1.5, nearest(record(10_050, 2.0, ringAgeMs = 50), 40, 50_100)!!, 1e-9)
    // That ring again in the next record, 40 ms longer on the way: now minus its age moves by 40 ms, more than a
    // tick's tolerance would forgive, but it is the same ring, smoothed once
    assertEquals(1.5, nearest(record(10_150, 2.0, ringAgeMs = 150), 0, 50_200)!!, 1e-9)
    // A new ring, read at 10 100 ms: smoothed again
    assertEquals(1.75, nearest(record(10_160, 2.0, ringAgeMs = 60), 0, 50_210)!!, 1e-9)
  }

  @Test
  fun aReceivedRingIsToldApartByWhenItArrivedOnThePhone() {
    val source = RingSource.received(record(10_000, 1.0, ringAgeMs = 120), 300)
    assertTrue(source.receiving)
    assertEquals(9_880L, source.input.ringAtMs)
    assertEquals(420L, source.input.ageMs)
    assertEquals(true, source.input.motorsOn)
    assertNull(RingSource.received(record(10_000, null), 0).input.ringAtMs)
    val local = RingSource.local(values(1.0))
    assertFalse(local.receiving)
    assertNull(local.relayed)
    assertNull(local.input.ringAtMs)
  }
}
