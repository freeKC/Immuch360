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
import kotlinx.serialization.json.long
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
open class SteadyRecordingListener : RecordingReceiverListener() {
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

  private lateinit var listenerForSets: RecordingReceiverListener

  private fun sets(): List<Pair<StreamDescription, DescriptionSource>> =
    synchronized(listenerForSets.parameters) { listenerForSets.parameters.toList() }

  /** A drone unit of [body] bytes at [perSecond] (its content clock steps of 17 or 33 ms) */
  private fun droneAt(counter: Int, perSecond: Int, key: Boolean = false, body: Int = 40, base: Int = 0): AccessUnit {
    val step = if (perSecond >= 45) 50.0 / 3 else 100.0 / 3
    val clock = base + (counter * step).toInt()
    return HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.slice(type = if (key) 19 else 1, body = body),
      HevcSamples.suffixSeiWithClock(counter = counter, clockMs = clock and 0xFFFF),
    ).also { it.contentMs = clock.toLong() }
  }

  @Test
  fun aReceiverOfThisBuildSwitchesToTheSteadyStreamAndBackWithItsNetworkInThePhonesReport() {
    val steady = FakeSteadySource()
    val server = RelayServer(runTicker = false, steady = steady)
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    val listener = SteadyRecordingListener()
    listenerForSets = listener
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
      assertTrue(sets().last().first.sameSetsAs(phoneDescription.description))
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
      // The steady stream stops: back to the drone's stream at once, its kept key decoded at once with its sets in band
      // (p2/review-bandwidth-2026-10-25.md M2), not kept as a primer
      steady.isUsable = false
      server.tick(System.nanoTime() + 1_200_000_000L)
      assertNotNull(listener.await("unit 6"))
      val key = listener.flags.last()
      assertEquals(0, key and RelayWire.UNIT_PRIMER)
      assertTrue((key and RelayWire.UNIT_KEY) != 0)
      assertTrue((key and RelayWire.UNIT_BREAK) != 0)
      assertTrue((key and RelayWire.UNIT_IN_BAND) != 0)
      assertEquals(0, key and RelayWire.UNIT_PHONE)
      val keyUnit = synchronized(listener.units) { listener.units.last().first }
      assertTrue(keyUnit.isKey)
      assertTrue(EncodedUnits.descriptionOf(keyUnit.bytes)!!.sameSetsAs(drone.description))
      assertTrue(sets().last().first.sameSetsAs(drone.description))
      server.submit(droneUnit(5), drone)
      assertNotNull(listener.await("unit 7"))
      // The live unit after it breaks too: it predicts from pictures the TV never had
      assertEquals(0, listener.flags.last() and RelayWire.UNIT_PHONE)
      assertTrue((listener.flags.last() and RelayWire.UNIT_BREAK) != 0)
      assertEquals(0L, receiver.snapshot().lostOnWifi)
      assertEquals(1L, server.report()["fallbackKeysSent"]!!.jsonPrimitive.long)
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

  /**
   * p2/review-bandwidth-2026-10-25.md M5: Automatic goes back to the drone's stream at the landing key picture, with
   * the phase read from the picture rate of the units after the key (the motors still read as running), the room from
   * the best second its path carried on the full stream, and the key unit with the units after it from a clean start.
   * A key picture before 30 s quiet is refused, and counted.
   */
  @Test
  fun automaticGoesBackAtTheLandingKeyWithTheKeyAndTheUnitsAfterIt() {
    var now = 1_000_000_000_000L
    val steady = FakeSteadySource()
    val server = RelayServer(
      clockNs = { now },
      runTicker = false,
      pingTimeoutMs = 600_000,
      writerStallNs = Long.MAX_VALUE / 4,
      steady = steady,
    )
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    // Read on the controller's 500 ms tick: still running when the landing key comes
    server.motorsOn = true
    val listener = SteadyRecordingListener()
    listenerForSets = listener
    val receiver = RelayReceiver(listener, pingIntervalMs = 50)
    try {
      receiver.connect("127.0.0.1", port, code, null, "Salon 2", "test", kind = "tv")
      assertNotNull(listener.await("connected"))
      assertTrue(eventually { server.headsetCount == 1 })
      // In flight on the full stream: a second that carried 1.2 MB, 9.8 Mbit/s
      var counter = 0
      server.submit(droneAt(counter++, 60, key = true, body = 60_000), drone)
      repeat(19) { server.submit(droneAt(counter++, 60, body = 60_000), drone) }
      assertTrue(eventually { synchronized(listener.units) { listener.units.size } == 20 })
      Thread.sleep(100)
      now += 1_000_000_000L
      server.tick(now)
      // Steady stream chosen, then Automatic: it stays steady (p2/review-bandwidth-2026-10-25.md m6)
      server.quality = RelayQuality.STEADY
      now += 100_000_000L
      server.tick(now)
      server.submitSteady(steadyUnit(0, 0), phoneDescription)
      assertTrue(eventually { receiver.snapshot().steady })
      server.quality = RelayQuality.AUTOMATIC
      now += 100_000_000L
      server.tick(now)
      assertEquals("steady", server.snapshot().headsets.single().stream)
      // A drone key picture 1 s later: not quiet for 30 s yet
      server.submit(droneAt(counter++, 60, key = true), drone)
      repeat(5) { server.submit(droneAt(counter++, 60), drone) }
      assertEquals("steady", server.snapshot().headsets.single().stream)
      // 31 s quiet
      repeat(310) {
        now += 100_000_000L
        server.tick(now)
      }
      val before = synchronized(listener.units) { listener.units.size }
      // The landing: the drone's encoder starts again at 30 a second
      counter = 0
      server.submit(droneAt(counter++, 30, key = true, base = 40_000), drone)
      repeat(5) { server.submit(droneAt(counter++, 30, base = 40_000), drone) }
      assertTrue(eventually { synchronized(listener.units) { listener.units.size } == before + 6 })
      assertTrue(eventually { !receiver.snapshot().steady })
      val flags = listener.flags.toList().takeLast(6)
      val first = flags.first()
      assertTrue((first and RelayWire.UNIT_KEY) != 0)
      assertTrue((first and RelayWire.UNIT_BREAK) != 0)
      assertTrue((first and RelayWire.UNIT_IN_BAND) != 0)
      assertEquals(0, first and (RelayWire.UNIT_PRIMER or RelayWire.UNIT_PHONE))
      val notAfterTheKey = RelayWire.UNIT_BREAK or RelayWire.UNIT_PHONE or RelayWire.UNIT_KEY
      assertTrue(flags.drop(1).all { (it and notAfterTheKey) == 0 })
      val headers = synchronized(listener.units) { listener.units.takeLast(6).map { it.second } }
      assertEquals((0..5).toList(), headers.map { it.pictureCounter })
      assertTrue(sets().last().first.sameSetsAs(drone.description))
      val tv = server.report()["receivers"]!!.jsonArray.single().jsonObject
      assertEquals("quiet", tv["streamSwitches"]!!.jsonArray.last().jsonObject["why"]!!.jsonPrimitive.content)
      val said = tv["steady"]!!.jsonObject
      assertEquals(2, said["backChecks"]!!.jsonPrimitive.int)
      assertEquals(1, said["backRefusedNotQuiet"]!!.jsonPrimitive.int)
      val check = said["lastBackCheck"]!!.jsonObject
      assertEquals("back", check["check"]!!.jsonPrimitive.content)
      assertEquals("false", check["flying"]!!.jsonPrimitive.content)
      assertEquals(30, check["perSecond"]!!.jsonPrimitive.int)
      assertEquals(4_800L, check["expectedKbps"]!!.jsonPrimitive.long)
      assertTrue(check["capacityKbps"]!!.jsonPrimitive.long >= 7_200L)
      assertEquals(0L, receiver.snapshot().lostOnWifi)
    } finally {
      receiver.disconnect()
      server.stop()
    }
  }

  /**
   * The receiver's side of a switch and a fall back (p2/review-bandwidth-2026-10-25.md M2): the records a TV of this
   * build gets go through its own pipeline as the controller wires it, and the decoder's rules then say, for each unit
   * the decoder takes, which parameter sets it is parsed with. Whether the phone's encoder codes 1080 lines like the
   * drone (case a: the same configuration, the decoder flushed at each switch) or 1088 (case b: configured again),
   * every unit is parsed with the sets it was made with.
   */
  @Test
  fun aReceiverDecodesEveryUnitWithItsOwnSetsAcrossASwitchAndAFallBack() {
    // Case a: the drone's VPS and SPS, a PPS of its own
    val pps = HevcSamples.PPS + byteArrayOf(0x44)
    val sameSize = StreamDescription(HevcSamples.VPS, HevcSamples.SPS, pps, drone.description.info)
    val phoneKeyA = { counter: Int ->
      EncodedUnits.unitOf(
        HevcSamples.annexB(HevcSamples.VPS, HevcSamples.SPS, pps, HevcSamples.slice(type = 19)),
        RelaySourceStamp(1, 2, 5_000L + counter * 33, -1),
        0,
        counter,
      )!!
    }
    val phoneP = { counter: Int ->
      EncodedUnits.unitOf(
        HevcSamples.annexB(HevcSamples.slice(type = 1)),
        RelaySourceStamp(1, 2, 5_000L + counter * 33, -1),
        0,
        counter,
      )!!
    }
    val a = acrossASwitchAndAFallBack(ResolvedDescription(sameSize, DescriptionSource.SESSION), phoneKeyA, phoneP)
    assertEquals("case a: configured once", 1, a.configurations)
    assertEquals("case a: flushed at the switch and at the fall back", 2, a.flushes)
    // Case b: the libx265 vectors code 1088 lines
    val b = acrossASwitchAndAFallBack(phoneDescription, { steadyUnit(0, it) }, { steadyUnit(1, it) })
    assertEquals("case b: configured again at each switch", 3, b.configurations)
    assertEquals(0, b.flushes)
  }

  private class Decoded(val configurations: Int, val flushes: Int)

  /** The TV's own pipeline, wired as the controller does it, into a sink that records what its decoder would take */
  private class TvPipeline : SteadyRecordingListener() {
    val store = ParameterSetStore(MemoryKeyValueStore())
    val detector = CodecDetector()
    val taken = java.util.concurrent.CopyOnWriteArrayList<Pair<AccessUnit, ResolvedDescription>>()
    val pipeline = VideoPipeline(
      store,
      object : DecoderSink {
        override fun submit(unit: AccessUnit, description: ResolvedDescription) {
          taken.add(unit to description)
        }

        override fun reset() = Unit

        override fun status(): DecoderStatus = DecoderStatus()
      },
    )

    override fun onParameters(description: StreamDescription, source: DescriptionSource, arrivalNs: Long) {
      synchronized(this) {
        detector.offer(RelayWire.annexBUnit(description.configuration(), arrivalNs))
        store.onRelayedDescription(description, source)
      }
      super.onParameters(description, source, arrivalNs)
    }

    override fun onUnit(unit: AccessUnit, header: RelayUnitHeader, flags: Int, arrivalNs: Long) {
      synchronized(this) {
        if ((flags and RelayWire.UNIT_PRIMER) != 0) {
          pipeline.onPrimer(unit, detector)
        } else {
          if ((flags and RelayWire.UNIT_BREAK) != 0) {
            pipeline.relayBreak()
          }
          val fresh = detector.offer(unit)
          pipeline.onUnit(unit, detector, fresh, arrivalNs)
        }
      }
      super.onUnit(unit, header, flags, arrivalNs)
    }
  }

  private fun acrossASwitchAndAFallBack(
    phone: ResolvedDescription,
    phoneKey: (Int) -> AccessUnit,
    phoneP: (Int) -> AccessUnit,
  ): Decoded {
    val steady = FakeSteadySource()
    val server = RelayServer(runTicker = false, steady = steady)
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    val tv = TvPipeline()
    listenerForSets = tv
    val receiver = RelayReceiver(tv, pingIntervalMs = 50)
    try {
      receiver.connect("127.0.0.1", port, code, null, "Salon 2", "test", kind = "tv")
      assertNotNull(tv.await("connected"))
      assertTrue(eventually { server.headsetCount == 1 })
      server.submit(droneUnit(1, key = true), drone)
      server.submit(droneUnit(2), drone)
      server.submit(droneUnit(3), drone)
      // Written before the switch, which would clear them as the other stream's
      assertTrue(eventually { tv.taken.size == 3 })
      // Steady stream: the phone's key picture with its sets, two pictures after it
      server.quality = RelayQuality.STEADY
      server.tick(System.nanoTime())
      server.submitSteady(phoneKey(0), phone)
      server.submitSteady(phoneP(1), phone)
      server.submitSteady(phoneP(2), phone)
      assertTrue(eventually { tv.taken.size == 6 })
      // The steady stream stops between two drone key pictures: back to the drone's stream
      steady.isUsable = false
      server.tick(System.nanoTime() + 1_000_000_000L)
      server.submit(droneUnit(4), drone)
      server.submit(droneUnit(5), drone)
      assertTrue(eventually { tv.taken.size == 9 })
    } finally {
      receiver.disconnect()
      server.stop()
    }
    // The decoder's rules over what it takes: a configuration when the size needs one, else a flush before a relayed
    // key picture with other sets; the sets a key unit brings in band become its sets
    var configured: StreamDescription? = null
    var sets: StreamDescription? = null
    var configurations = 0
    var flushes = 0
    for ((index, taken) in tv.taken.withIndex()) {
      val (unit, resolved) = taken
      val next = resolved.description
      if (configured == null || DecoderPolicy().mustReconfigure(configured, next)) {
        configured = next
        sets = next
        configurations += 1
      } else if (DecoderPolicy.flushBeforeKey(relayed = true, isKey = unit.isKey, fed = sets, next = next)) {
        sets = next
        flushes += 1
      }
      if (unit.isKey && unit.hasParameterSets) {
        sets = EncodedUnits.descriptionOf(unit.bytes)
      }
      assertTrue("unit $index parsed with the sets it was made with", next.sameSetsAs(sets))
    }
    // The units after the switch are the phone's, after the fall back the drone's, starting on a key picture each time
    assertEquals(listOf(true, false, false, true, false, false, true, false, false), tv.taken.map { it.first.isKey })
    assertTrue(tv.taken[3].second.description.sameSetsAs(phone.description))
    assertTrue(tv.taken[6].second.description.sameSetsAs(drone.description))
    return Decoded(configurations, flushes)
  }
}
