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

/**
 * The fields of the second telemetry reading (p2/telemetry-deep-dive-2026-10-24.md), on bodies taken from our own
 * capture of 23 October 2026: the end of a landing, the only 0.5 s of flight our captures hold. The bodies are in
 * telemetry-vectors.json, bytes 0 to 15 of the flight data (a position when there is a fix) set to zero.
 */
class TelemetryVectorsTest {
  private class Vector(val atMs: Long, val body: ByteArray)

  private val vectors: JsonObject = Json.parseToJsonElement(
    javaClass.classLoader!!.getResource("djilink/telemetry-vectors.json")!!.readText(),
  ).jsonObject

  private fun group(name: String): List<Vector> = vectors[name]!!.jsonArray.map { element ->
    val item = element.jsonObject
    val hex = item["body"]!!.jsonPrimitive.content
    Vector(
      atMs = (item["t"]!!.jsonPrimitive.double * 1000).toLong(),
      body = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() },
    )
  }

  private fun frame(set: Int, id: Int, body: ByteArray, senderType: Int) = P3Frame(
    version = 1,
    senderType = senderType,
    senderIndex = if (senderType == 18) 4 else 0,
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
  fun theLandingGivesTheHeightTheVerticalSpeedAndTenthsBelow() {
    val flights = group("flightData").map { TelemetryFields.flight(it.body)!! }
    assertEquals(6, flights.size)
    // The five frames with the motors running, then the one where they stopped
    assertEquals(listOf(true, true, true, true, true, false), flights.map { it.motorsOn })
    assertEquals(listOf(-0.4, -0.4, -0.4, -0.4, -0.5, 0.0), flights.map { it.heightM })
    // 2 on the wire, positive down: descending at 0.2 m/s, then 0.1 once landed
    assertEquals(listOf(-0.2, -0.2, -0.2, -0.2, -0.2, -0.1), flights.map { it.verticalSpeedMps })
    // A vertical touch down: no speed over ground while the motors ran
    flights.take(5).forEach { assertEquals(0.0, it.horizontalSpeedMps, 1e-9) }
    // Offset 41 in tenths of a metre (p2/telemetry-proof-2026-10-25.md, 4.4): a smoothed copy of the range below that
    // still showed the floor under the hand this landing came down on
    assertEquals(listOf(0.9, 0.8, 0.8, 0.1, 0.0, 0.0), flights.map { it.groundHeightM })
    flights.forEach { assertEquals(TelemetryFields.MODE_AUTOMATIC_LANDING, it.mode) }
    assertEquals(listOf(38.3, 38.4, 38.5, 38.6, 38.7, 38.7), flights.map { it.motorTimeS })
  }

  @Test
  fun theRangeBelowReadsMillimetresUntilTheMotorsStop() {
    val ranges = group("rangeBelow").map { TelemetryFields.rangeBelow(it.body)!! }
    assertEquals(
      listOf(0.135, 0.133, 0.126, 0.097, 0.080, 0.066, 0.056, 0.044, 0.042),
      ranges.take(9).map { it.distanceM },
    )
    // From the frame the motors stop: no reading, never a distance of 65.535 m
    ranges.drop(9).forEach { assertNull(it.distanceM) }
  }

  @Test
  fun theObstacleRingGivesItsNearestDistance() {
    val rings = group("obstacles").map { TelemetryFields.obstacles(it.body)!! }
    assertEquals(listOf(0.507, 0.506, 0.858, 0.868, 0.869), rings.map { it.nearestM })
    assertEquals(listOf(0, 0, 0, 0, 0), rings.map { it.nearestIndex })
    assertEquals(listOf(0, 0, 25, 25, 25), rings.map { it.noReading })
  }

  @Test
  fun theObstacleRingGivesSeventyTwoSectorsWithTheSameNearest() {
    val rings = group("obstacles").map { TelemetryFields.obstacles(it.body)!! }
    rings.forEach { ring ->
      val sectors = ring.sectorsMm!!
      assertEquals(72, sectors.size)
      // Index 0 is in sector 0, and the nearest sector is the nearest distance
      assertEquals(Math.round(ring.nearestM!! * 1000).toInt(), sectors[0])
      assertEquals(Math.round(ring.nearestM!! * 1000).toInt(), sectors.filterNotNull().min())
      // Blocks of five: 25 indexes without a reading are 5 sectors without one
      assertEquals(ring.noReading / 5, sectors.count { it == null })
    }
    assertEquals(listOf(507, 683, 772, 871), rings[0].sectorsMm!!.take(4))
    assertEquals(listOf(6, 7, 8, 10, 11), rings[2].sectorsMm!!.withIndex().filter { it.value == null }.map { it.index })
    // A ring of another count keeps its nearest distance and gives no sectors
    val body = group("obstacles").first().body
    val shorter = body.copyOf(8 + 2 * 359).also { it[6] = (359 and 0xFF).toByte(); it[7] = (359 shr 8).toByte() }
    val odd = TelemetryFields.obstacles(shorter)!!
    assertEquals(0.507, odd.nearestM!!, 1e-9)
    assertNull(odd.sectorsMm)
  }

  @Test
  fun aRingOfAnotherLengthOrEmptyIsNotRead() {
    val body = group("obstacles").first().body
    assertNull(TelemetryFields.obstacles(body.copyOf(727)))
    assertNull(TelemetryFields.obstacles(ByteArray(4)))
    // Every sector without a reading: nothing near, which never means the way is clear
    val empty = body.copyOf().also { ring ->
      for (index in 0 until 360) {
        ring[8 + 2 * index] = (60000 and 0xFF).toByte()
        ring[9 + 2 * index] = (60000 shr 8).toByte()
      }
    }
    val reading = TelemetryFields.obstacles(empty)!!
    assertNull(reading.nearestM)
    assertNull(reading.nearestIndex)
    assertEquals(360, reading.noReading)
  }

  @Test
  fun theDecoderKeepsEachGroupFromItsOwnSender() {
    val decoder = TelemetryDecoder()
    group("flightData").forEach { decoder.offer(frame(3, 67, it.body, senderType = 14), it.atMs) }
    group("rangeBelow").take(9).forEach { decoder.offer(frame(10, 3, it.body, senderType = 14), it.atMs) }
    group("obstacles").forEach { decoder.offer(frame(36, 8, it.body, senderType = 18), it.atMs) }
    group("signalBars").forEach { decoder.offer(frame(9, 117, it.body, senderType = 14), it.atMs) }
    val values = decoder.values(450)
    assertEquals(0.042, values.rangeBelow!!.value.distanceM!!, 1e-9)
    assertEquals(0.869, values.obstacles!!.value.nearestM!!, 1e-9)
    assertFalse(values.obstacles!!.stale)
    assertEquals(5, values.signalBars!!.value)
    assertEquals(0L, values.layoutMismatches)
    // The same pushes from another sender are not what our captures named
    val other = TelemetryDecoder()
    group("obstacles").forEach { other.offer(frame(36, 8, it.body, senderType = 3), it.atMs) }
    group("rangeBelow").forEach { other.offer(frame(10, 3, it.body, senderType = 9), it.atMs) }
    assertNull(other.values(450).obstacles)
    assertNull(other.values(450).rangeBelow)
  }

  @Test
  fun theFrameOfThePilotHoldsOnlyFreshValuesAndNoSpeedOnTheGround() {
    val decoder = TelemetryDecoder()
    group("flightData").take(5).forEach { decoder.offer(frame(3, 67, it.body, senderType = 14), it.atMs) }
    group("obstacles").forEach { decoder.offer(frame(36, 8, it.body, senderType = 18), it.atMs) }
    val flying = liveFramePigeon(decoder.values(450), ObstacleDecision.OFF, 450)
    assertEquals(-0.5, flying.heightM!!, 1e-9)
    assertEquals(-0.2, flying.verticalSpeedMps!!, 1e-9)
    assertEquals(0.0, flying.speedMps!!, 1e-9)
    assertEquals(0.869, flying.obstacleM!!, 1e-9)
    assertTrue(flying.landing)
    assertEquals(true, flying.motorsOn)
    // The motors stopped: no speed and no height (a reset to 0), whatever the drone still holds
    group("flightData").drop(5).forEach { decoder.offer(frame(3, 67, it.body, senderType = 14), it.atMs) }
    val landed = liveFramePigeon(decoder.values(560), ObstacleDecision.OFF, 560)
    assertNull(landed.speedMps)
    assertNull(landed.heightM)
    assertNull(landed.verticalSpeedMps)
    assertEquals(false, landed.motorsOn)
    // Long after: every group stale, every value gone
    val later = liveFramePigeon(decoder.values(60_000), ObstacleDecision.OFF, 60_000)
    assertNull(later.heightM)
    assertNull(later.motorTimeS)
    assertNull(later.obstacleM)
    assertNotNull(later.alert)
  }
}
