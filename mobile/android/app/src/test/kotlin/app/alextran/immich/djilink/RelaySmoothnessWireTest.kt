package app.alextran.immich.djilink

import java.net.InetAddress
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
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
 * The wire of the relay's smoothness (p2/relay-smoothness-2026-10-25.md, 5.3 and 6.1), kept compatible both ways: a
 * receiver of this build says it reads the longer unit header and gets the content clock, and its long pings fill the
 * phone's row and export; a receiver of an earlier build gets the 32 byte header, and its short pings are taken.
 */
class RelaySmoothnessWireTest {
  private val code = "K7M2Q9XRTH"
  private val description = ResolvedDescription(ProfileRegistry.seed20261023!!, DescriptionSource.SESSION)

  private fun unit(clockMs: Long): AccessUnit = HevcSamples.unitOf(
    HevcSamples.DELIMITER,
    HevcSamples.slice(),
    HevcSamples.suffixSeiWithClock(counter = 3842, clockMs = (clockMs and 0xFFFF).toInt()),
  ).also { it.contentMs = clockMs }

  private fun JsonObject.receivers(): JsonArray = this["receivers"]!!.jsonArray

  @Test
  fun aReceiverOfThisBuildGetsTheContentClockAndItsLongPingsReachThePhone() {
    val server = RelayServer(runTicker = false)
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    val said = RelayPingNumbers(
      bufferTargetMs = 180,
      bufferNowMs = 176,
      freezes = 2,
      longestFreezeMs = 640,
      renderSkips = 9,
      lateUnits = 3,
      decoderStalls = 1,
      sequenceGaps = 0,
      primersUsed = 0,
      roundTripUs = 9_400,
      phoneToShownMs = 230,
      safetyFlushes = 0,
    )
    val listener = object : RecordingReceiverListener() {
      override fun pingNumbers(): RelayPingNumbers = said
    }
    val receiver = RelayReceiver(listener, pingIntervalMs = 50)
    try {
      receiver.connect("127.0.0.1", port, code, null, "Living room TV", "test", kind = "tv")
      assertNotNull(listener.await("connected"))
      assertTrue(eventually { server.headsetCount == 1 })
      server.submit(unit(112_217), description)
      assertNotNull(listener.await("unit 0"))
      val (received, header) = synchronized(listener.units) { listener.units.single() }
      assertEquals(112_217L, header.contentMs)
      assertEquals(3842, header.pictureCounter)
      val stamp = received.relay!!
      assertEquals(112_217L, stamp.contentMs)
      assertEquals(0L, stamp.sequence)
      // The unit's bytes start after the longer header
      assertEquals(HevcNal.ACCESS_UNIT_DELIMITER, received.nalTypes.first())
      val snapshot = receiver.snapshot()
      assertEquals(RelayWire.UNIT_HEADER_LONG_BYTES, snapshot.unitHeaderBytes)
      assertTrue(snapshot.longPings)
      // The long pings fill the phone's row
      assertTrue(eventually { server.snapshot().headsets.singleOrNull()?.receiver == said })
      val row = server.snapshot().headsets.single()
      assertEquals("tv", row.kind)
      assertEquals(0L, row.dropEvents)
      assertNotNull(row.sendBufferBytes)
      // One second later the tick writes a line of the timeline
      server.tick(System.nanoTime() + 1_100_000_000L)
      val report = server.report()
      val tv = report.receivers().single().jsonObject
      assertEquals(1_500, tv["dropAgeMs"]!!.jsonPrimitive.int)
      assertEquals(40, tv["unitHeaderBytes"]!!.jsonPrimitive.int)
      assertEquals(2, tv["receiverSays"]!!.jsonObject["freezes"]!!.jsonPrimitive.int)
      assertEquals(1, tv["recordsSent"]!!.jsonObject["unit"]!!.jsonPrimitive.int)
      assertEquals(1, tv["timeline"]!!.jsonArray.size)
      val line = (tv["timeline"]!!.jsonArray[0] as JsonPrimitive).content
      assertEquals(RelayReceiverStats.TIMELINE_HEADER.split(',').size, line.split(',').size)
      assertTrue(tv["roundTripMedianMs"]!!.jsonPrimitive.content.toDouble() > 9.0)
      // A receiver that left stays in the export with why
      receiver.disconnect()
      assertTrue(eventually { server.headsetCount == 0 })
      val left = server.report().receivers().single().jsonObject
      assertEquals("Living room TV", left["name"]!!.jsonPrimitive.content)
      assertNotNull(left["leftWhy"]!!.jsonPrimitive.content)
    } finally {
      receiver.disconnect()
      server.stop()
    }
  }

  @Test
  fun aHeadsetOfAnEarlierBuildGetsTheShortHeaderAndItsShortPingsAreTaken() {
    val server = RelayServer(runTicker = false)
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    TestHeadset(port).use { headset ->
      val welcome = headset.join(code)
      assertEquals(RelayWire.WELCOME, welcome.type)
      val json = RelayWire.parseJson(welcome.body, RelayWire.PROOF_BYTES)!!
      assertNull("no longer header for a hello that does not ask", json["unitHeader"])
      assertEquals(RelayWire.PING_LONG_BYTES, json["pingBytes"]!!.jsonPrimitive.int)
      assertTrue(eventually { server.headsetCount == 1 })
      val sent = unit(5_000)
      server.submit(sent, description)
      val record = headset.readUntil(RelayWire.UNIT)
      assertEquals(RelayWire.UNIT_HEADER_BYTES + sent.size, record.body.size)
      assertEquals(-1L, RelayWire.parseUnitHeader(record.body).contentMs)
      headset.ping()
      assertTrue(eventually { server.snapshot().headsets.single().relayDelayMs == 12.0 })
      assertNull(server.snapshot().headsets.single().receiver)
      val report = server.report().receivers().single().jsonObject
      assertEquals(32, report["unitHeaderBytes"]!!.jsonPrimitive.int)
      assertEquals(800, report["dropAgeMs"]!!.jsonPrimitive.int)
      assertFalse(report["sendBufferBytes"]!!.jsonPrimitive.content == "null")
    }
    server.stop()
  }
}
