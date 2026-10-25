package app.alextran.immich.djilink

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone encoder's output as the relay sends it (p2/relay-bandwidth-2026-10-25.md, 7.2 and 7.3), on access units
 * made by libx265 on this PC (relay-encoder-vectors.json, made by make_encoder_vectors.py beside it): the codec
 * configuration buffer, a key picture with its sets in band, P pictures, a CRA key picture; then the presentation time
 * map, the decimator and the always increasing presentation times.
 */
class EncodedUnitsTest {
  private val vectors: JsonObject by lazy {
    val stream = javaClass.classLoader!!.getResourceAsStream("djilink/relay-encoder-vectors.json")!!
    val text = stream.bufferedReader().readText()
    Json.parseToJsonElement(text).jsonObject
  }

  private fun units(name: String): List<ByteArray> =
    vectors[name]!!.jsonObject["units"]!!.jsonArray.map { StreamDescription.hexBytes(it.jsonPrimitive.content)!! }

  private val stamp =
    RelaySourceStamp(firstArrivalNs = 1_000, lastArrivalNs = 2_000, contentMs = 112_217, counter = 3842)

  @Test
  fun aKeyPictureWithItsSetsInBandGivesTheStreamsDescription() {
    val bytes = units("a1080")[0]
    val unit = EncodedUnits.unitOf(bytes, stamp, nowNs = 9_999, counter = 0)!!
    assertTrue(unit.isKey)
    assertTrue(unit.hasParameterSets)
    assertEquals(listOf(HevcNal.VPS, HevcNal.SPS, HevcNal.PPS, 20), unit.nalTypes.toList())
    // Shared, never copied
    assertTrue(unit.bytes === bytes)
    val description = EncodedUnits.descriptionOf(bytes)!!
    assertEquals(1920, description.info.width)
    assertEquals(1080, description.info.height)
    // Coded in 16 pixel units: 1088 lines and a conformance window, read the same way as the drone's SPS
    assertEquals(1088, description.info.codedHeight)
    assertEquals(4, description.info.confWindowBottom)
    assertEquals("Main", description.info.profileName)
  }

  @Test
  fun theUnitCarriesItsSourcesTimesAndTheSteadyStreamsOwnCounter() {
    val unit = EncodedUnits.unitOf(units("a1080")[1], stamp, nowNs = 9_999, counter = 41)!!
    assertFalse(unit.isKey)
    assertFalse(unit.hasParameterSets)
    assertEquals(1_000L, unit.firstArrivalNs)
    assertEquals(2_000L, unit.lastArrivalNs)
    assertEquals(112_217L, unit.contentMs)
    assertEquals(41, unit.headerCounter)
    // No SEI 240 in the phone's stream: the receivers' lost picture rule never fires on the decimation
    assertNull(unit.pictureCounter)
    // A stamp gone from the map: the unit says now, and no content time
    val lost = EncodedUnits.unitOf(units("a1080")[2], null, nowNs = 9_999, counter = 42)!!
    assertEquals(9_999L, lost.lastArrivalNs)
    assertEquals(-1L, lost.contentMs)
  }

  @Test
  fun aCraPictureIsAKeyPictureToo() {
    val unit = EncodedUnits.unitOf(units("a1080")[3], stamp, 0, 3)!!
    assertTrue(unit.isKey)
    assertTrue(unit.hasParameterSets)
    assertEquals(21, unit.nalTypes.last())
  }

  @Test
  fun aSeparateCodecConfigurationBufferGivesTheDescriptionAndTheKeyPictureHasNoSets() {
    val config = StreamDescription.hexBytes(vectors["b720"]!!.jsonObject["config"]!!.jsonPrimitive.content)!!
    val description = EncodedUnits.descriptionOf(config)!!
    assertEquals(1280, description.info.width)
    assertEquals(720, description.info.height)
    // What the relay sends as a PARAMETERS body is what a receiver parses back
    assertNotNull(RelayWire.parseParameters(RelayWire.parametersBody(description)))
    val key = EncodedUnits.unitOf(units("b720")[0], stamp, 0, 0)!!
    assertTrue(key.isKey)
    assertFalse(key.hasParameterSets)
    assertNull(EncodedUnits.descriptionOf(key.bytes))
    val withSets = EncodedUnits.unitOf(description.configuration() + key.bytes, stamp, 0, 0)!!
    assertTrue(withSets.isKey)
    assertTrue(withSets.hasParameterSets)
    assertTrue(description.sameSetsAs(EncodedUnits.descriptionOf(withSets.bytes)))
    assertNull(EncodedUnits.unitOf(ByteArray(16) { 0x55 }, stamp, 0, 0))
  }

  @Test
  fun thePresentationTimeMapFindsTheStampsBackAndForgetsTheOldest() {
    val map = RelayPtsMap(capacity = 4)
    val stamps = (0 until 5).map { RelaySourceStamp(it * 10L, it * 10L + 5, it * 33L, it) }
    stamps.forEachIndexed { index, it -> map.put(1_000_000L + index * 33_333, it) }
    // The first was replaced by the fifth
    assertNull(map.find(1_000_000L))
    assertEquals(stamps[1], map.find(1_033_333L))
    // An encoder that rounds its time to the microsecond
    assertEquals(stamps[4], map.find(1_133_333L))
    assertEquals(stamps[4], map.find(1_133_332L))
    assertNull(map.find(1_133_335L))
    assertNull(map.find(5L))
    map.clear()
    assertNull(map.find(1_033_333L))
  }

  private fun kept(decimator: RelayDecimator, stepsUs: List<Long>, count: Int): Int {
    var at = 0L
    var kept = 0
    repeat(count) { index ->
      if (decimator.keep(at)) kept += 1
      at += stepsUs[index % stepsUs.size]
    }
    return kept
  }

  @Test
  fun theDecimatorKeepsThirtyOrFifteenPicturesASecond() {
    // 60 a second on the drone's millisecond clock: steps of 16 and 17 ms
    val sixty = listOf(16_000L, 17_000L, 17_000L)
    val thirty = listOf(33_000L, 34_000L, 33_000L)
    assertEquals(30, kept(RelayDecimator(30), sixty, 60))
    assertEquals(30, kept(RelayDecimator(30), thirty, 30))
    assertEquals(15, kept(RelayDecimator(15), sixty, 60))
    assertEquals(15, kept(RelayDecimator(15), thirty, 30))
  }

  @Test
  fun theDecimatorStartsAgainWhenTheTimeStepsBack() {
    val decimator = RelayDecimator(30)
    assertTrue(decimator.keep(10_000_000))
    assertFalse(decimator.keep(10_016_000))
    assertTrue(decimator.keep(2_000_000))
    assertFalse(decimator.keep(2_016_000))
    assertTrue(decimator.keep(2_033_000))
    decimator.perSecond = 15
    assertFalse(decimator.keep(2_066_000))
    assertTrue(decimator.keep(2_100_000))
  }

  @Test
  fun presentationTimesAlwaysIncrease() {
    val pts = MonotonicPts()
    assertEquals(1_000_000L, pts.of(1_000_000))
    assertEquals(1_016_000L, pts.of(1_016_000))
    // A capture that loops: on after the last time given
    val looped = pts.of(0)
    assertEquals(1_016_000L + MonotonicPts.STEP_US, looped)
    assertEquals(looped + 33_000, pts.of(33_000))
    // A repeat of the same time
    val again = pts.of(33_000)
    assertTrue(again > looped + 33_000)
    pts.reset()
    assertEquals(5L, pts.of(5))
  }

  @Test
  fun theUnitsBytesAreTheEncodersOwn() {
    val bytes = units("a1080")[1]
    val unit = EncodedUnits.unitOf(bytes, stamp, 0, 0)!!
    assertArrayEquals(bytes, unit.bytes)
    assertEquals(bytes.size, unit.size)
  }
}
