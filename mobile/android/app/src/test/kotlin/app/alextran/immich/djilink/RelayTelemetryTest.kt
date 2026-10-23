package app.alextran.immich.djilink

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The TELEMETRY record (design 4.7): the phone's values to JSON and back, ages, staleness, no position anywhere */
class RelayTelemetryTest {
  private fun flightBody(): ByteArray = ByteArray(85).apply {
    fun i16(at: Int, value: Int) {
      this[at] = (value and 0xFF).toByte()
      this[at + 1] = ((value shr 8) and 0xFF).toByte()
    }
    i16(16, -5)
    i16(18, 4)
    i16(20, -4)
    i16(24, -110)
    i16(26, 269)
    i16(28, 635)
    this[30] = 6
    this[32] = 0x10
    this[41] = 9
    i16(42, 387)
  }

  private fun frame(set: Int, id: Int, body: ByteArray) = P3Frame(
    version = 1,
    senderType = 3,
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

  private fun values(): TelemetryValues {
    val decoder = TelemetryDecoder()
    decoder.offer(frame(3, 67, flightBody()), 1_000)
    val decoded = decoder.values(1_040)
    return decoded.copy(
      gimbal = Timed(GimbalReading(63.4, 92_700, 63.41, 0.0, -0.5, listOf(0.85, 0.0, 0.0, 0.52)), 60, false),
      battery = Timed(BatteryReading(6.756, -0.706, 1525, 582, 31.0, 2, 38, 0x0123456789ABCDEFL), 300, false),
      remoteBatteryPercent = Timed(50, 400, false),
      link = LinkReadings(
        signalAircraftSide = Timed(90, 20, false),
        signalRemoteSide = Timed(88, 30, false),
        liveRateMbps = Timed(5.6, 900, false),
        aircraftClockMs = Timed(92_757L, 20, false),
        clockJitterP95Ms = 6.0,
        clockDriftMs = null,
      ),
    )
  }

  private val link = RelayLinkFacts(
    source = "replay",
    state = RelayTelemetry.stateName(LinkState.VIDEO_READY),
    aircraft = true,
    remote = true,
    replayName = "dji-link-20261023-102731",
    replayPositionMs = 4_100,
    codec = "h265",
  )

  private val phoneVideo = RelayPhoneVideo(30.0, 5.1, 0.4, 9.0, 14.0, 0, 0, 4_100)

  @Test
  fun theValuesComeBackAsThePhoneDecodedThem() {
    val sent = values()
    val json = RelayTelemetry.build(81_234_567_890_123L, 412, link, sent, phoneVideo, headsets = 1, unitsDropped = 3)
    val back = RelayTelemetry.parseBody(RelayWire.jsonBody(json))!!
    assertEquals(81_234_567_890_123L, back.phoneNs)
    assertEquals(412L, back.sequence)
    assertEquals(link, back.link)
    assertEquals(phoneVideo, back.phoneVideo)
    assertEquals(1, back.headsets)
    assertEquals(3L, back.unitsDropped)
    // Every group as the decoder gave it; the flags word of the flight data is not sent (its two bits are)
    assertEquals(sent.flight!!.copy(value = sent.flight!!.value.copy(flags = 0)), back.values.flight)
    assertEquals(sent.gimbal, back.values.gimbal)
    assertEquals(sent.battery, back.values.battery)
    assertEquals(sent.remoteBatteryPercent, back.values.remoteBatteryPercent)
    assertEquals(sent.link, back.values.link)
    assertEquals(63.5, back.values.flight!!.value.headingDeg, 1e-9)
    assertEquals(6, back.values.flight!!.value.mode)
    assertEquals(40L, back.values.flight!!.ageMs)
  }

  @Test
  fun thereIsNoPositionNoSerialAndNoAccessoryStringAnywhere() {
    val text = RelayTelemetry.build(1, 1, link, values(), phoneVideo, 1, 0).toString()
    val keys = mutableSetOf<String>()
    fun walk(element: JsonElement) {
      when (element) {
        is JsonObject -> element.forEach { (key, value) ->
          keys += key
          walk(value)
        }
        is kotlinx.serialization.json.JsonArray -> element.forEach { walk(it) }
        else -> Unit
      }
    }
    walk(Json.parseToJsonElement(text))
    for (forbidden in listOf("position", "latitude", "longitude", "lat", "lon", "serial", "manufacturer", "model")) {
      assertFalse(forbidden, keys.any { it.equals(forbidden, ignoreCase = true) })
    }
    assertTrue(keys.containsAll(listOf("flight", "gimbal", "battery", "remoteBattery", "radio", "phoneVideo", "relay")))
  }

  @Test
  fun agesGrowOnTheHeadsetAndAGroupTurnsStale() {
    val back = RelayTelemetry.parseBody(RelayWire.jsonBody(RelayTelemetry.build(1, 1, link, values(), phoneVideo, 1, 0)))!!
    val soon = back.aged(200)
    assertEquals(240L, soon.flight!!.ageMs)
    assertFalse(soon.flight!!.stale)
    assertEquals(500L, soon.battery!!.ageMs)
    val late = back.aged(TelemetryDecoder.MIN_STALE_MS + 1)
    assertTrue(late.flight!!.stale)
    assertTrue(late.link.aircraftClockMs!!.stale)
    assertTrue(late.link.signalAircraftSide!!.stale)
  }

  @Test
  fun withoutASourceOnlyTheLinkAndThePhoneNumbersGo() {
    val none = link.copy(source = "none", replayName = null, replayPositionMs = null)
    val json = RelayTelemetry.build(5, 2, none, null, phoneVideo, 0, 0)
    assertNull(json["flight"])
    val back = RelayTelemetry.parse(json)!!
    assertEquals("none", back.link.source)
    assertNull(back.values.flight)
    assertNull(back.values.link.aircraftClockMs)
  }

  @Test
  fun unknownKeysAreIgnoredAndARecordThatIsNotOneGivesNothing() {
    val text = """{"t":3,"seq":9,"later":{"x":1},"link":{"source":"cable","state":"videoReady","aircraft":true,
      |"remote":false,"newField":[1,2]},"flight":{"ageMs":10,"stale":false,"heightM":1.5,"speedsMps":[0,0,0],
      |"headingDeg":10.0,"mode":6,"surprise":true}}""".trimMargin()
    val back = RelayTelemetry.parseBody(text.toByteArray())!!
    assertEquals("cable", back.link.source)
    assertFalse(back.link.remote)
    assertEquals(1.5, back.values.flight!!.value.heightM, 1e-9)
    assertEquals(3, back.values.flight!!.value.speedsMps.size)
    assertNull(RelayTelemetry.parseBody("not json".toByteArray()))
    assertNull(RelayTelemetry.parseBody("[1,2]".toByteArray()))
  }

  @Test
  fun theStateNamesAreThoseOfThePage() {
    assertEquals("videoReady", RelayTelemetry.stateName(LinkState.VIDEO_READY))
    assertEquals("absent", RelayTelemetry.stateName(LinkState.ABSENT))
    assertEquals("aircraftLinked", RelayTelemetry.stateName(LinkState.AIRCRAFT_LINKED))
    // The arrays of numbers keep their order
    val quaternion = RelayTelemetry.build(1, 1, link, values(), null, 0, 0)["gimbal"]!!.jsonObject["quaternion"]!!.jsonArray
    assertEquals("0.85", quaternion[0].toString())
  }
}
