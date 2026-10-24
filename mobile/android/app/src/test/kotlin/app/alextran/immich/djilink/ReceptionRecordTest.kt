package app.alextran.immich.djilink

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** What a headset received, kept for a bug report (p2/design-final-2026-10-24.md, section 5) */
class ReceptionRecordTest {
  private var nowNs = 0L
  private var nowMs = 1_792_800_000_000L

  private fun record(head: Int = 1_024) = ReceptionRecord(
    headBytes = head,
    tailBytes = CaptureRing.MIN_CAPACITY,
    telemetryBytes = CaptureRing.MIN_CAPACITY,
    monotonicNs = { nowNs },
    wallMs = { nowMs },
  )

  private fun telemetry(sequence: Long): RelayRecord {
    val values = TelemetryValues(
      flight = null,
      gimbal = null,
      battery = Timed(BatteryReading(6.9, -0.7, 1615, 557, 28.3, 2, 34, 0L), 300, false),
      remoteBatteryPercent = null,
      link = LinkReadings(null, null, null, null, null, null),
      layoutMismatches = 0,
      decoded = emptyMap(),
      obstacles = Timed(ObstacleReading(1.4, 12, 0), 40, false),
    )
    val link = RelayLinkFacts(source = "cable", state = "videoReady", aircraft = true, remote = true)
    val json = RelayTelemetry.build(nowNs, sequence, link, values, null, 1, 0)
    return RelayRecord(RelayWire.TELEMETRY, 0, RelayWire.jsonBody(json))
  }

  private fun unit(size: Int) = RelayRecord(RelayWire.UNIT, RelayWire.UNIT_KEY, ByteArray(size) { (it % 251).toByte() })

  @Test
  fun nothingIsKeptBeforeAReceptionStarts() {
    val kept = record()
    kept.record(unit(100))
    kept.state("RECEIVING")
    assertEquals(0L, kept.received)
    assertTrue(kept.records().bytes.isEmpty())
  }

  @Test
  fun theHeadTheTailAndEveryTelemetryRecordAreKept() {
    val kept = record()
    kept.start(ReceptionRecord.Watched("Immuch360 on Galaxy S24+", "192.168.1.21", 8362))
    kept.record(telemetry(0))
    // Far more units than the tail holds: the middle of the session goes, the head and the last seconds stay
    for (index in 1..40) {
      nowNs += 33_000_000
      kept.record(unit(4_000))
      if (index % 3 == 0) {
        kept.record(telemetry(index.toLong()))
      }
    }
    assertEquals(54L, kept.received)
    val records = kept.records()
    assertTrue(records.entries.any { it.direction == CaptureDirection.GAP })
    assertTrue(records.bytes.size <= 1_024 + CaptureRing.MIN_CAPACITY)
    // Each record starts with its relay header: the kind, the flags, the length of the body
    assertEquals(RelayWire.TELEMETRY, records.bytes[0].toInt() and 0xFF)
    // The telemetry ring has all fourteen, whatever the units pushed out of the tail
    val telemetry = kept.telemetryRecords()
    assertEquals(14, telemetry.entries.count { it.direction == CaptureDirection.IN })
    assertFalse(telemetry.entries.any { it.direction == CaptureDirection.GAP })
  }

  @Test
  fun theHeaderSaysThePhoneTheStatesAndTheRecordsPerKindAndNeverTheCode() {
    val kept = record()
    kept.start(ReceptionRecord.Watched("Immuch360 on Galaxy S24+", "192.168.1.21", 8362))
    kept.state("CONNECTING")
    kept.state("RECEIVING")
    kept.state("RECEIVING")
    kept.record(telemetry(1))
    kept.record(unit(500))
    kept.record(unit(500))
    kept.state("LOST")
    val header = kept.header()
    assertEquals("reception", header["kind"]!!.jsonPrimitive.content)
    assertEquals("192.168.1.21", header["phone"]!!.jsonObject["host"]!!.jsonPrimitive.content)
    val states = header["states"]!!.jsonArray.map { it.jsonObject["state"]!!.jsonPrimitive.content }
    assertEquals(listOf("CONNECTING", "RECEIVING", "LOST"), states)
    val kinds = header["recordsByKind"]!!.jsonObject
    assertEquals(2L, kinds["unit"]!!.jsonPrimitive.long)
    assertEquals(1L, kinds["telemetry"]!!.jsonPrimitive.long)
    // The code a headset types is never part of the record, nor a position or a serial number
    val keys = mutableSetOf<String>()
    fun walk(element: JsonElement) {
      if (element is JsonObject) {
        element.forEach { (key, value) ->
          keys += key
          walk(value)
        }
      }
    }
    walk(header)
    for (forbidden in listOf("code", "position", "latitude", "longitude", "serial")) {
      assertFalse(forbidden, keys.any { it.equals(forbidden, ignoreCase = true) })
    }
    assertFalse(String(kept.records().bytes, Charsets.ISO_8859_1).contains("K7M2Q9XRTH"))
  }

  @Test
  fun aClearForgetsEverything() {
    val kept = record()
    kept.start(ReceptionRecord.Watched(null, "192.168.1.21", 8362))
    kept.record(unit(500))
    kept.clear()
    assertEquals(0L, kept.received)
    assertTrue(kept.records().bytes.isEmpty())
    kept.record(unit(500))
    assertEquals(0L, kept.received)
  }
}
