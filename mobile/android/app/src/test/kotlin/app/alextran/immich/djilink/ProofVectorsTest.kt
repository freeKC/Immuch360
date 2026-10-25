package app.alextran.immich.djilink

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.ln

/**
 * The gates opened by the proof flights of 25 October 2026 (p2/telemetry-proof-2026-10-25.md), on bodies cut from the
 * afternoon capture (dji-link-20261025-154528, tools/proof_vectors.py): the motors from the spin up, the air from lift
 * off, the height against the range below, offset 41 in tenths of a metre, the speed along the heading, the nose sector
 * closing by the distance flown, a turn to the right moving the ring to the left, and the height held back after a
 * hand launch. Bytes 0 to 15 of the flight data are zero; no 35/178 body is kept.
 */
class ProofVectorsTest {
  private class Vector(val atMs: Long, val body: ByteArray)

  private val vectors: JsonObject = Json.parseToJsonElement(
    javaClass.classLoader!!.getResource("djilink/proof-vectors.json")!!.readText(),
  ).jsonObject

  private fun group(window: String, name: String): List<Vector> =
    vectors[window]!!.jsonObject[name]!!.jsonArray.map { element ->
      val item = element.jsonObject
      val hex = item["body"]!!.jsonPrimitive.content
      Vector(
        atMs = Math.round(item["t"]!!.jsonPrimitive.double * 1000),
        body = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() },
      )
    }

  private fun flights(window: String) = group(window, "flightData").map { it.atMs to TelemetryFields.flight(it.body)!! }

  private fun ranges(window: String) = group(window, "rangeBelow").map { it.atMs to TelemetryFields.rangeBelow(it.body)!! }

  private fun rings(window: String) = group(window, "obstacles").map { it.atMs to TelemetryFields.obstacles(it.body)!! }

  /** The range reading nearest [atMs] within 100 ms, null without one */
  private fun List<Pair<Long, RangeBelowReading>>.at(atMs: Long): Double? =
    filter { abs(it.first - atMs) <= 100 }.minByOrNull { abs(it.first - atMs) }?.second?.distanceM

  private fun List<Pair<Long, FlightReading>>.at(atMs: Long): FlightReading = minBy { abs(it.first - atMs) }.second

  @Test
  fun theMotorsRunFromTheSpinUpAndTheAirComesAtLiftOff() {
    val flights = flights("liftOff")
    // Bit 0x08 at 62.56 s, 4.1 s before bit 0x04 at 66.66 s
    val motors = flights.first { it.second.motorsOn }.first
    val air = flights.first { it.second.inAir }.first
    assertTrue("$motors", motors in 62_550L..62_570L)
    assertTrue("$air", air in 66_650L..66_670L)
    assertTrue(flights.first().first < motors)
    // The spin up: the motors run on a hand, the range below reads millimetres, the vertical speed about 0, and the
    // height drifts to -1.2 m: nothing a pilot reads comes from these frames
    val ranges = ranges("liftOff")
    val spinning = flights.filter { it.second.motorsOn && !it.second.inAir }
    assertEquals(41, spinning.size)
    assertEquals(-1.2, spinning.minOf { it.second.heightM }, 1e-9)
    spinning.forEach { (atMs, flight) ->
      assertNull(flight.airborne)
      assertTrue(abs(flight.verticalSpeedMps) <= 0.1)
      ranges.at(atMs)?.let { assertTrue("$atMs: $it", it < 0.07) }
    }
    // In the air: every frame from lift off on
    assertTrue(flights.filter { it.first >= air }.all { it.second.airborne != null })
  }

  /** The frames of [window] through a decoder in the order they came, flight data and range below interleaved */
  private fun decoded(window: String): List<Pair<Long, FlightReading>> {
    val decoder = TelemetryDecoder()
    val flights = group(window, "flightData").map { Triple(it.atMs, 0, it.body) }
    val ranges = group(window, "rangeBelow").map { Triple(it.atMs, 1, it.body) }
    val out = mutableListOf<Pair<Long, FlightReading>>()
    (flights + ranges).sortedWith(compareBy({ it.first }, { it.second })).forEach { (atMs, kind, body) ->
      if (kind == 0) {
        decoder.offer(proofFrame(body, 3, 67), atMs)
        out += atMs to decoder.values(atMs).flight!!.value
      } else {
        decoder.offer(proofFrame(body, 10, 3), atMs)
      }
    }
    return out
  }

  private fun proofFrame(body: ByteArray, set: Int, id: Int) = P3Frame(
    version = 1,
    senderType = 14,
    senderIndex = 0,
    receiverType = DeviceTypes.APPLICATION,
    receiverIndex = 0,
    sequence = 1,
    isAcknowledgement = false,
    ackPolicy = 0,
    encryption = 0,
    commandSet = set,
    commandId = id,
    body = body,
  )

  @Test
  fun aHandLaunchShowsNoHeightUntilTheDroneHasLeftTheHand() {
    // Flight 1: bit 0x04 at 66.66 s, the height still -1.1 m from the spin up drift, back to 0.0 at 67.77 s; the range
    // below passes 0.15 m at 67.18 s. Held for 1.5 s: the first height a pilot reads is 0.3 m at 68.16 s
    val frames = decoded("liftOff").filter { it.second.inAir }
    assertTrue("${frames.first().first}", frames.first().first in 66_650L..66_670L)
    val launch = frames.first().first
    val held = frames.filter { it.first - launch < HeightHold.LAUNCH_MS }
    assertTrue(held.size >= 14)
    assertTrue(held.all { it.second.pilotHeightM == null })
    assertEquals(-1.1, held.minOf { it.second.heightM }, 1e-9)
    val shown = frames.filter { it.first - launch >= HeightHold.LAUNCH_MS }
    assertTrue(shown.isNotEmpty())
    assertEquals(0.3, shown.first().second.pilotHeightM!!, 1e-9)
    assertTrue(shown.all { it.second.pilotHeightM!! >= 0.0 })
    // The speeds are not held: the climb reads from the first frames
    assertTrue(held.all { it.second.airborne != null })
  }

  @Test
  fun theHeightAndTheVerticalSpeedFollowTheRangeBelow() {
    val flights = flights("liftOff")
    val ranges = ranges("liftOff")
    // The climb, positive while climbing: 1.0 to 1.5 m/s as the range below grows by 0.7 m in 0.5 s
    val climb = flights.filter { it.first in 67_350L..67_770L }.map { it.second.airborne!!.verticalSpeedMps }
    assertEquals(5, climb.size)
    assertTrue(climb.toString(), climb.all { it >= 1.0 })
    assertTrue(ranges.at(67_760L)!! - ranges.at(67_360L)!! > 0.0)
    // Still over the floor, 69.06 to 69.96 s: the height grows by 0.4 m, the range below by 0.374 m
    val rise = flights.at(69_960L).heightM - flights.at(69_060L).heightM
    val rangeRise = ranges.at(69_960L)!! - ranges.at(69_060L)!!
    assertEquals(0.4, rise, 1e-9)
    assertEquals(rangeRise, rise, 0.1)
  }

  @Test
  fun offsetFortyOneIsTenthsOfTheRangeBelow() {
    var near = 0
    var nearAsCentimetres = 0
    var count = 0
    for (window in listOf("liftOff", "handLanding", "leg", "approach", "turn")) {
      val ranges = ranges(window)
      flights(window).filter { it.second.inAir }.forEach { (atMs, flight) ->
        val range = ranges.at(atMs) ?: return@forEach
        count += 1
        if (abs(flight.groundHeightM - range) <= 0.15) near += 1
        if (abs(flight.groundHeightM / 10 - range) <= 0.15) nearAsCentimetres += 1
      }
    }
    assertTrue("$near of $count", count >= 150 && near >= count * 85 / 100)
    assertTrue("$nearAsCentimetres of $count", nearAsCentimetres <= count / 10)
    // A smoothed copy: a hand comes under the drone at 171.86 s, the range drops to 0.52 m, offset 41 keeps 1.5 m
    val flights = flights("handLanding")
    val ranges = ranges("handLanding")
    assertEquals(1.5, flights.at(171_660L).groundHeightM, 1e-9)
    assertEquals(1.475, ranges.at(171_660L)!!, 0.002)
    assertTrue(ranges.at(171_860L)!! < 0.55)
    assertEquals(1.5, flights.at(172_370L).groundHeightM, 1e-9)
    assertEquals(0.4, flights.at(172_470L).groundHeightM, 1e-9)
  }

  @Test
  fun aHandLandingEndsTheAirAndResetsTheHeight() {
    val flights = flights("handLanding")
    // Mode 12 from 173.17 s, descending at 0.1 to 0.2 m/s onto the hand
    val landing = flights.filter { it.second.mode == TelemetryFields.MODE_AUTOMATIC_LANDING && it.second.inAir }
    assertTrue("${landing.first().first}", landing.first().first in 173_160L..173_175L)
    assertTrue(landing.drop(1).all { it.second.verticalSpeedMps in -0.2..0.0 })
    // The motors stop 0.5 m above the lift off point: both bits go, and the height reads 0 there
    val last = flights.last { it.second.motorsOn }
    assertTrue("${last.first}", last.first in 175_160L..175_175L)
    assertEquals(0.5, last.second.heightM, 1e-9)
    val stopped = flights.first { it.first > last.first }.second
    assertFalse(stopped.inAir)
    assertEquals(0.0, stopped.heightM, 1e-9)
    assertTrue(ranges("handLanding").at(175_170L)!! < 0.03)
    // After the second landing the vertical speed holds 0.2 m/s down on the ground: not in the air, not given
    val second = flights("secondLanding").filter { !it.second.motorsOn }
    assertTrue(second.isNotEmpty())
    assertTrue(second.any { abs(it.second.verticalSpeedMps) >= 0.2 })
    assertTrue(second.all { it.second.airborne == null })
  }

  @Test
  fun theSpeedPointsAlongTheHeading() {
    val flights = flights("leg")
    var flown = 0.0
    flights.zipWithNext { (a, _), (b, flight) -> flown += flight.horizontalSpeedMps * (b - a) / 1000.0 }
    // 4.5 m forward in 5.8 s (telemetry_series.py ringcheck: 4.53 m from the 50 Hz positions)
    assertEquals(4.5, flown, 0.3)
    val moving = flights.map { it.second }.filter { it.horizontalSpeedMps >= 0.3 }
    assertTrue(moving.size >= 50)
    moving.forEach { flight ->
      // Along the axes heading 0 and heading 90 count from; north and east only if heading 0 is north, not checked
      val (alongZero, alongNinety) = flight.speedsMps
      val course = Math.toDegrees(atan2(alongNinety, alongZero))
      assertTrue("${flight.headingDeg} $course", ObstacleRing.separation(course, flight.headingDeg) <= 15.0)
    }
  }

  @Test
  fun theNoseSectorClosesByTheDistanceFlown() {
    val (first, second) = rings("approach")
    val flights = flights("approach").filter { it.first in first.first..second.first }
    var flown = 0.0
    flights.zipWithNext { (a, _), (b, flight) -> flown += flight.horizontalSpeedMps * (b - a) / 1000.0 }
    assertTrue(abs(flights.first().second.headingDeg - flights.last().second.headingDeg) < 5.0)
    fun nose(ring: ObstacleReading): Double {
      val sectors = ring.sectorsMm!!
      val front = listOf(-1, 0, 1).map { ObstacleRing.sectorAt(it * ObstacleRing.SECTOR_DEG.toDouble()) }
      return front.mapNotNull { sectors[it] }.min() / 1000.0
    }
    // 1.71 m ahead, then 1.14 m after 0.59 m forward
    assertEquals(1.71, nose(first.second), 0.02)
    assertEquals(0.59, flown, 0.05)
    assertEquals(-flown, nose(second.second) - nose(first.second), 0.1)
  }

  @Test
  fun aTurnToTheRightMovesWhatWasAheadToTheLeft() {
    val (before, after) = rings("turn")
    val flights = flights("turn")
    val turned = ObstacleRing.normalize(flights.at(after.first).headingDeg - flights.at(before.first).headingDeg)
    // +82.4 degrees: the heading grows on a turn to the right
    assertEquals(82.4, turned, 1.0)
    val a = before.second.sectorsMm!!
    val b = after.second.sectorsMm!!
    fun score(shift: Int): Double {
      val terms = (0 until ObstacleRing.SECTORS).mapNotNull { sector ->
        val x = a[sector]
        val y = b[Math.floorMod(sector + shift, ObstacleRing.SECTORS)]
        if (x == null || y == null) null else abs(ln(x.toDouble() / y))
      }
      return if (terms.size < 20) Double.MAX_VALUE else terms.average()
    }
    val best = (-36 until 36).minBy { score(it) }
    // The pattern moves by -heading change / 5 sectors: -16.5 predicted
    assertTrue("$best", abs(best + turned / ObstacleRing.SECTOR_DEG) <= 3.0)
    assertTrue(score(best) < score(0) / 4)
    // What was at the nose is on the left now, as ObstacleRing.MAPPING draws it
    val bearing = ObstacleRing.bearingDeg(Math.floorMod(ObstacleRing.MAPPING.noseSector + best, ObstacleRing.SECTORS))
    assertTrue("$bearing", bearing in -100.0..-70.0)
    assertEquals(RingMapping(noseSector = 0, clockwise = true), ObstacleRing.MAPPING)
  }

  @Test
  fun thePilotsFrameShowsTheHeightAndTheSpeedsInTheAirOnly() {
    val decoder = TelemetryDecoder()
    fun frame(body: ByteArray, set: Int, id: Int, senderType: Int) = P3Frame(
      version = 1,
      senderType = senderType,
      senderIndex = 0,
      receiverType = DeviceTypes.APPLICATION,
      receiverIndex = 0,
      sequence = 1,
      isAcknowledgement = false,
      ackPolicy = 0,
      encryption = 0,
      commandSet = set,
      commandId = id,
      body = body,
    )
    // In the order they came: the height hold reads the range below between the flight frames
    val flights = group("liftOff", "flightData").map { Triple(it.atMs, 67, it.body) }
    val ranges = group("liftOff", "rangeBelow").map { Triple(it.atMs, 3, it.body) }
    val frames = (flights + ranges).sortedBy { it.first }
    fun feedUntil(atMs: Long) {
      frames.filter { it.first <= atMs }.forEach { (at, id, body) ->
        decoder.offer(if (id == 67) frame(body, 3, 67, 14) else frame(body, 10, 3, 14), at)
      }
    }
    // 66.06 s: the motors spin on a hand, the height reads -1.2 m: no height, no speeds, the distance below given
    feedUntil(66_060L)
    val spinning = liveFramePigeon(decoder.values(66_100L), ObstacleDecision.OFF, 66_100L)
    assertEquals(true, spinning.motorsOn)
    assertNull(spinning.heightM)
    assertNull(spinning.verticalSpeedMps)
    assertNull(spinning.speedMps)
    assertNotNull(spinning.distanceBelowM)
    // 67.06 s, 0.4 s after the lift off from the hand: the height reads -0.9 m and is held back, the climb shows
    decoder.reset()
    feedUntil(67_100L)
    val launching = liveFramePigeon(decoder.values(67_100L), ObstacleDecision.OFF, 67_100L)
    assertNull(launching.heightM)
    assertNotNull(launching.verticalSpeedMps)
    // 69.96 s, in the air: 0.7 m above the lift off point, 1.77 m above the floor
    decoder.reset()
    feedUntil(70_000L)
    val flying = liveFramePigeon(decoder.values(70_000L), ObstacleDecision.OFF, 70_000L)
    assertEquals(0.7, flying.heightM!!, 1e-9)
    assertEquals(0.0, flying.verticalSpeedMps!!, 1e-9)
    assertEquals(1.767, flying.distanceBelowM!!, 0.002)
  }
}
