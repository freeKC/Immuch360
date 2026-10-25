package app.alextran.immich.djilink

import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The phone's steady stream as the server sees it, played by the test: its calls are recorded */
class FakeSteadySource : RelaySteadySource {
  @Volatile
  var isAvailable = true

  @Volatile
  var isUsable = true

  @Volatile
  var isProducing = true
  override val available: Boolean get() = isAvailable
  override val usable: Boolean get() = isUsable
  override val producing: Boolean get() = isProducing
  override val why: String? get() = if (isUsable) null else TranscoderWhy.HOT.wire
  val keys = CopyOnWriteArrayList<RelayKeyCause>()

  @Volatile
  var needed = false

  @Volatile
  var enabled = false

  @Volatile
  var capable = false

  @Volatile
  var bitrate: Int? = null

  @Volatile
  var perSecond = 30
  var ticks = 0

  override fun setEnabled(on: Boolean, nowNs: Long) {
    enabled = on
  }

  override fun setCapableReceivers(any: Boolean, nowNs: Long) {
    capable = any
  }

  override fun setNeeded(needed: Boolean, nowNs: Long) {
    this.needed = needed
  }

  override fun requestKey(cause: RelayKeyCause, nowNs: Long) {
    keys += cause
  }

  override fun setBitrate(bps: Int, nowNs: Long) {
    bitrate = bps
  }

  override fun setPictureRate(perSecond: Int, nowNs: Long) {
    this.perSecond = perSecond
  }

  override fun tick(nowNs: Long) {
    ticks += 1
  }

  override fun line(nowNs: Long): RelaySteadyLine =
    RelaySteadyLine("running", null, "c2.fake.hevc.encoder", 1920, 1080, perSecond, bitrate, 12.0, 21.0)

  override fun report(nowNs: Long): JsonObject = buildJsonObject { put("state", "running") }
}

/** A receiver's listener that keeps every unit's flags and the parameter sets' flags */
class SteadyRecordingListener : RecordingReceiverListener() {
  val flags = CopyOnWriteArrayList<Int>()
  val network = RelayPingNetwork(
    transport = RelayPingNetwork.TRANSPORT_WIFI,
    frequencyMhz = 5_180,
    linkMbps = 866,
    rssiDbm = -55,
  )

  override fun onUnit(unit: AccessUnit, header: RelayUnitHeader, flags: Int, arrivalNs: Long) {
    this.flags += flags
    super.onUnit(unit, header, flags, arrivalNs)
  }

  override fun pingNumbers(): RelayPingNumbers = RelayPingNumbers(bufferTargetMs = 150)

  override fun pingNetwork(): RelayPingNetwork = network
}

/**
 * The steady stream on the wire (p2/relay-bandwidth-2026-10-25.md, 7.8), kept compatible both ways: a real server and a
 * real receiver of this build on loopback with a fake steady source. The hello and welcome fields, a switch (new
 * parameter sets, a key unit with BREAK, no primer), the 96 byte ping and its network in the phone's report, the way
 * back with today's primer; a receiver of an earlier build stays on the full stream with the 64 byte pings.
 */
class RelaySteadyWireTest {
  private val code = "K7M2Q9XRTH"
  private val drone = ResolvedDescription(ProfileRegistry.seed20261023!!, DescriptionSource.SESSION)
  private val vectors: JsonObject by lazy {
    val stream = javaClass.classLoader!!.getResourceAsStream("djilink/relay-encoder-vectors.json")!!
    val text = stream.bufferedReader().readText()
    Json.parseToJsonElement(text).jsonObject
  }

  private fun encoded(index: Int): ByteArray =
    StreamDescription.hexBytes(vectors["a1080"]!!.jsonObject["units"]!!.jsonArray[index].jsonPrimitive.content)!!

  private val phoneDescription: ResolvedDescription by lazy {
    ResolvedDescription(EncodedUnits.descriptionOf(encoded(0))!!, DescriptionSource.SESSION)
  }

  private fun droneUnit(counter: Int, key: Boolean = false): AccessUnit = HevcSamples.unitOf(
    HevcSamples.DELIMITER,
    HevcSamples.slice(type = if (key) 19 else 1),
    HevcSamples.suffixSeiWithClock(counter = counter, clockMs = counter * 17),
  ).also { it.contentMs = counter * 17L }

  private fun steadyUnit(index: Int, counter: Int): AccessUnit =
    EncodedUnits.unitOf(encoded(index), RelaySourceStamp(1, 2, 5_000L + counter * 33, -1), 0, counter)!!

  @Test
  fun aReceiverOfThisBuildSwitchesToTheSteadyStreamAndBackWithItsNetworkInThePhonesReport() {
    val steady = FakeSteadySource()
    val server = RelayServer(runTicker = false, steady = steady)
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    val listener = SteadyRecordingListener()
    val receiver = RelayReceiver(listener, pingIntervalMs = 50)
    try {
      receiver.connect("127.0.0.1", port, code, null, "Salon 2", "test", kind = "tv")
      assertNotNull(listener.await("connected"))
      assertTrue(eventually { server.headsetCount == 1 })
      val said = receiver.snapshot()
      assertTrue(said.steadyOffered)
      assertTrue(said.steadyPings)
      // The drone's stream first, as today
      server.submit(droneUnit(1, key = true), drone)
      server.submit(droneUnit(2), drone)
      assertNotNull(listener.await("unit 1"))
      assertFalse(receiver.snapshot().steady)
      // The setting asks for the steady stream: a key picture is asked, the drone's stream goes on until it comes
      server.quality = RelayQuality.STEADY
      server.tick(System.nanoTime())
      assertTrue(steady.needed)
      assertTrue(steady.enabled)
      assertTrue(steady.capable)
      assertEquals(listOf(RelayKeyCause.SWITCH), steady.keys.toList())
      server.submit(droneUnit(3), drone)
      assertNotNull(listener.await("unit 2"))
      // A P picture of the steady stream is not a place to switch at
      server.submitSteady(steadyUnit(1, 0), phoneDescription)
      server.submitSteady(steadyUnit(0, 1), phoneDescription)
      server.submitSteady(steadyUnit(1, 2), phoneDescription)
      assertNotNull(listener.await("unit 4"))
      // The drone's units no longer go to it
      server.submit(droneUnit(4), drone)
      server.submitSteady(steadyUnit(2, 3), phoneDescription)
      assertNotNull(listener.await("unit 5"))
      val flags = listener.flags.toList()
      assertEquals(6, flags.size)
      val switchKey = flags[3]
      assertTrue((switchKey and RelayWire.UNIT_PHONE) != 0)
      assertTrue((switchKey and RelayWire.UNIT_KEY) != 0)
      assertTrue((switchKey and RelayWire.UNIT_BREAK) != 0)
      assertEquals(0, switchKey and RelayWire.UNIT_PRIMER)
      assertTrue(flags.drop(3).all { (it and RelayWire.UNIT_PHONE) != 0 })
      // The steady stream's own parameter sets came before its key unit, as the phone's encoder's
      val sets = synchronized(listener.parameters) { listener.parameters.toList() }
      assertTrue(sets.last().first.sameSetsAs(phoneDescription.description))
      // Its own consecutive counter, in the header, in place of the SEI
      val headers = synchronized(listener.units) { listener.units.map { it.second } }
      assertEquals(listOf(1, 2, 3), headers.drop(3).map { it.pictureCounter })
      assertEquals(5_000L + 33, headers[3].contentMs)
      // No gap: the drone units it did not get are a switch, not a loss
      assertEquals(listOf(0L, 1L, 2L, 3L, 4L, 5L), headers.map { it.sequence })
      val received = receiver.snapshot()
      assertTrue(received.steady)
      assertEquals(1L, received.streamSwitches)
      assertEquals(0L, received.lostOnWifi)
      // The 96 byte pings carry its network to the phone
      assertTrue(eventually { server.snapshot().headsets.single().network?.linkMbps == 866 })
      val heard = server.snapshot().headsets.single().network!!
      val expected =
        listener.network.copy(bytesLastSecond = heard.bytesLastSecond, longestReadGapMs = heard.longestReadGapMs)
      assertEquals(expected, heard)
      assertTrue(heard.bytesLastSecond > 0)
      assertTrue(heard.longestReadGapMs >= 0)
      val row = server.snapshot().headsets.single()
      assertEquals("steady", row.stream)
      assertTrue(row.steadyCapable)
      assertEquals(8.0, row.allowedMegabits!!, 0.001)
      val snapshot = server.snapshot()
      assertEquals(RelayQuality.STEADY, snapshot.quality)
      assertEquals("c2.fake.hevc.encoder", snapshot.steadyLine!!.encoderName)
      server.tick(System.nanoTime() + 1_100_000_000L)
      val report = server.report()
      assertEquals("steady", report["quality"]!!.jsonPrimitive.content)
      assertEquals("running", report["transcoder"]!!.jsonObject["state"]!!.jsonPrimitive.content)
      val tv = report["receivers"]!!.jsonArray.single().jsonObject
      assertEquals(96, tv["pingBytes"]!!.jsonPrimitive.int)
      assertEquals("steady", tv["stream"]!!.jsonPrimitive.content)
      val switch = tv["streamSwitches"]!!.jsonArray.single().jsonObject
      assertEquals("full", switch["from"]!!.jsonPrimitive.content)
      assertEquals("steady", switch["to"]!!.jsonPrimitive.content)
      assertEquals("setting", switch["why"]!!.jsonPrimitive.content)
      val network = tv["receiverNetwork"]!!.jsonObject
      assertEquals("wifi", network["transport"]!!.jsonPrimitive.content)
      assertEquals("5", network["band"]!!.jsonPrimitive.content)
      assertEquals(866, network["linkMbps"]!!.jsonPrimitive.int)
      assertEquals(-55, network["rssiDbm"]!!.jsonPrimitive.int)
      val columns = tv["timelineColumns"]!!.jsonPrimitive.content.split(',')
      assertEquals(listOf("stream", "bitrateKbps"), columns.takeLast(2))
      val line = tv["timeline"]!!.jsonArray.last().jsonPrimitive.content.split(',')
      assertEquals(columns.size, line.size)
      assertEquals("1", line[columns.indexOf("stream")])
      assertEquals("8000", line[columns.indexOf("bitrateKbps")])
      // The steady stream stops: back to the drone's stream at once, with today's primer
      steady.isUsable = false
      server.tick(System.nanoTime() + 1_200_000_000L)
      assertNotNull(listener.await("unit 6"))
      val primer = listener.flags.last()
      assertTrue((primer and RelayWire.UNIT_PRIMER) != 0)
      assertTrue((primer and RelayWire.UNIT_BREAK) != 0)
      assertEquals(0, primer and RelayWire.UNIT_PHONE)
      server.submit(droneUnit(5), drone)
      assertNotNull(listener.await("unit 7"))
      assertEquals(0, listener.flags.last() and RelayWire.UNIT_PHONE)
      assertTrue(eventually { !receiver.snapshot().steady })
      val back = server.report()["receivers"]!!.jsonArray.single().jsonObject["streamSwitches"]!!.jsonArray.last()
      assertEquals("transcoder", back.jsonObject["why"]!!.jsonPrimitive.content)
    } finally {
      receiver.disconnect()
      server.stop()
    }
  }

  @Test
  fun withSteadyStreamSetAReceiverJoinsOnItWithAKeyMadeForItAndNoPrimer() {
    val steady = FakeSteadySource()
    val server = RelayServer(runTicker = false, steady = steady)
    server.quality = RelayQuality.STEADY
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    // A drone key was seen: today it would be the join primer
    server.submit(droneUnit(1, key = true), drone)
    val listener = SteadyRecordingListener()
    val receiver = RelayReceiver(listener, pingIntervalMs = 50)
    try {
      receiver.connect("127.0.0.1", port, code, null, "Salon 2", "test", kind = "tv")
      assertNotNull(listener.await("connected"))
      assertTrue(eventually { server.headsetCount == 1 })
      assertTrue(eventually { steady.keys.contains(RelayKeyCause.JOIN) })
      server.submit(droneUnit(2), drone)
      server.submitSteady(steadyUnit(1, 0), phoneDescription)
      server.submitSteady(steadyUnit(3, 1), phoneDescription)
      val first = listener.await("unit")
      assertNotNull(first)
      val flags = listener.flags.first()
      assertTrue((flags and RelayWire.UNIT_PHONE) != 0)
      assertTrue((flags and RelayWire.UNIT_KEY) != 0)
      assertEquals(0, flags and RelayWire.UNIT_PRIMER)
      assertEquals(1, synchronized(listener.parameters) { listener.parameters.size })
      assertTrue(receiver.snapshot().steady)
      assertEquals(0L, receiver.snapshot().primers)
    } finally {
      receiver.disconnect()
      server.stop()
    }
  }

  @Test
  fun aReceiverOfAnEarlierBuildStaysOnTheFullStreamWithItsPings() {
    val steady = FakeSteadySource()
    val server = RelayServer(runTicker = false, steady = steady)
    server.quality = RelayQuality.STEADY
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    TestHeadset(port).use { headset ->
      val welcome = headset.join(code, kind = "tv")
      val json = RelayWire.parseJson(welcome.body, RelayWire.PROOF_BYTES)!!
      assertNull(json["steady"])
      assertEquals(RelayWire.PING_LONG_BYTES, json["pingBytes"]!!.jsonPrimitive.int)
      assertTrue(eventually { server.headsetCount == 1 })
      server.tick(System.nanoTime())
      assertFalse(steady.capable)
      assertFalse(steady.needed)
      assertTrue(steady.keys.isEmpty())
      server.submitSteady(steadyUnit(0, 0), phoneDescription)
      server.submit(droneUnit(1, key = true), drone)
      val unit = headset.readUntil(RelayWire.UNIT)
      assertEquals(0, unit.flags and RelayWire.UNIT_PHONE)
      assertEquals("full", server.snapshot().headsets.single().stream)
      assertFalse(server.snapshot().headsets.single().steadyCapable)
    }
    server.stop()
  }

  @Test
  fun aPhoneWithoutAnEncoderOffersNoSteadyStreamButTakesTheLongerPing() {
    val steady = FakeSteadySource().apply {
      isAvailable = false
      isUsable = false
    }
    val server = RelayServer(runTicker = false, steady = steady)
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    val listener = SteadyRecordingListener()
    val receiver = RelayReceiver(listener, pingIntervalMs = 50)
    try {
      receiver.connect("127.0.0.1", port, code, null, "Salon 2", "test", kind = "tv")
      assertNotNull(listener.await("connected"))
      val said = receiver.snapshot()
      assertFalse(said.steadyOffered)
      assertTrue(said.steadyPings)
      assertTrue(eventually { server.snapshot().headsets.singleOrNull()?.network?.rssiDbm == -55 })
    } finally {
      receiver.disconnect()
      server.stop()
    }
  }

  @Test
  fun theLongerPingIsReadBackWholeAndAnEarlierPhoneWouldNeverGetIt() {
    val network = RelayPingNetwork(RelayPingNetwork.TRANSPORT_ETHERNET, -1, -1, -1, 180_000, 42)
    val body = RelayWire.pingBody(7, 8, 9, RelayPingNumbers(freezes = 3), network)
    assertEquals(RelayWire.PING_STEADY_BYTES, body.size)
    val ping = RelayWire.parsePing(body)
    assertEquals(3, ping.numbers!!.freezes)
    assertEquals(network, ping.network)
    assertEquals("ethernet", RelayPingNetwork.transportName(ping.network!!.transport))
    RelayWire.check(RelayWire.PING, RelayWire.PING_STEADY_BYTES.toLong(), fromPhone = false)
    // Without its numbers, the longer ping still says -1 for them
    assertEquals(-1, RelayWire.parsePing(RelayWire.pingBody(1, 2, 3, null, network)).numbers!!.freezes)
    assertEquals(DescriptionSource.SESSION, RelayWire.sourceOfParametersFlag(RelayWire.PARAMETERS_PHONE_ENCODER))
  }
}
