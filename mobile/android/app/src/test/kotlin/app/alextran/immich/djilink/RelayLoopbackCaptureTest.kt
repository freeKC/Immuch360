package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong

/**
 * The whole chain on the capture of 23 October 2026 (design 12.2): the capture through the phone side (envelope
 * decoder, router, pipeline with a recording sink teed to a relay on 127.0.0.1) into a receiver with its own pipeline.
 * The relay's clock is the capture's own, so the run takes seconds. Skipped where the capture is absent, as the other
 * capture tests are.
 *
 * Expected, from the numbers of stage 2 (the first unit with a description is the key picture, unit 29 of 336): 307
 * units relayed, in order and byte for byte; one key unit, the first, after one PARAMETERS record of this session
 * equal to the seed; 307 picture counters without a loss on the headset; telemetry at 10 Hz with the capture's values.
 */
class RelayLoopbackCaptureTest {
  private val code = "K7M2Q9XRTH"

  private class RecordingSink : DecoderSink {
    val units = CopyOnWriteArrayList<Pair<AccessUnit, ResolvedDescription>>()
    var resets = 0

    override fun submit(unit: AccessUnit, description: ResolvedDescription) {
      units.add(unit to description)
    }

    override fun reset() {
      resets += 1
    }

    override fun status(): DecoderStatus = DecoderStatus()
  }

  /** The phone side of a run: the pipeline teed to a relay whose clock is the capture's */
  private class Phone(maxAgeNs: Long) {
    val clock = AtomicLong(0)
    val telemetry = TelemetryDecoder()
    val built = ConcurrentHashMap<Long, TelemetryValues>()
    val server = RelayServer(
      clockNs = { clock.get() },
      runTicker = false,
      pingTimeoutMs = 600_000,
      writerStallNs = Long.MAX_VALUE / 4,
      queueMaxAgeNs = maxAgeNs,
      telemetry = { sequence ->
        val values = telemetry.values(clock.get() / 1_000_000)
        built[sequence] = values
        val json = RelayTelemetry.build(
          clock.get(),
          sequence,
          RelayLinkFacts("replay", "absent", true, true, CaptureVideoReplayTest.NAME, null, "h265"),
          values,
          null,
          1,
          0,
        )
        RelayWire.jsonBody(json)
      },
    )
    val sink = RecordingSink()
    val store = ParameterSetStore(MemoryKeyValueStore()).apply { seed = ProfileRegistry.seed20261023 }
    val pipeline = VideoPipeline(store, TeeSink(sink, server))

    fun advance(nowNs: Long) {
      clock.accumulateAndGet(nowNs) { a, b -> maxOf(a, b) }
      server.tick(clock.get())
    }

    fun play(bytes: ByteArray, index: List<CaptureEntry>) {
      CaptureReplay.replay(
        bytes,
        index,
        onVideoUnit = { unit, detector, fresh, nowNs ->
          advance(nowNs)
          pipeline.onUnit(unit, detector, fresh, nowNs)
        },
        onControlFrame = { frame, nowMs ->
          telemetry.offer(frame, nowMs)
          advance(nowMs * 1_000_000)
        },
        onNewStream = { pipeline.newStream() },
      )
    }
  }

  /** The headset side: the receiver into a pipeline of its own, as the controller wires it */
  private class Headset : RelayReceiver.Listener {
    val store = ParameterSetStore(MemoryKeyValueStore())
    val sink = RecordingSink()
    val pipeline = VideoPipeline(store, sink)
    val detector = CodecDetector()
    val received = CopyOnWriteArrayList<Triple<AccessUnit, RelayUnitHeader, Int>>()
    val parameters = CopyOnWriteArrayList<Pair<StreamDescription, DescriptionSource>>()
    val telemetry = CopyOnWriteArrayList<RelayTelemetryRecord>()
    val order = CopyOnWriteArrayList<String>()

    @Volatile
    var resets = 0

    override fun onConnected(welcome: RelayWelcome) = synchronized(this) { pipeline.newSource() }

    override fun onParameters(description: StreamDescription, source: DescriptionSource, arrivalNs: Long) =
      synchronized(this) {
        order.add("parameters")
        parameters.add(description to source)
        detector.offer(RelayWire.annexBUnit(description.configuration(), arrivalNs))
        store.onRelayedDescription(description, source)
      }

    override fun onUnit(unit: AccessUnit, header: RelayUnitHeader, flags: Int, arrivalNs: Long) = synchronized(this) {
      order.add(if ((flags and RelayWire.UNIT_KEY) != 0) "key" else "unit")
      received.add(Triple(unit, header, flags))
      val fresh = detector.offer(unit)
      pipeline.onUnit(unit, detector, fresh, arrivalNs)
    }

    override fun onReset() {
      resets += 1
    }

    override fun onDisconnected() = Unit

    override fun onChanged() = Unit

    override fun onTelemetry(record: RelayTelemetryRecord) {
      telemetry.add(record)
    }
  }

  private fun sha256(units: List<AccessUnit>): String {
    val digest = MessageDigest.getInstance("SHA-256")
    units.forEach { digest.update(it.bytes) }
    return digest.digest().joinToString("") { "%02x".format(it) }
  }

  @Test
  fun theWholeChainRelaysTheCaptureByteForByte() {
    val (bytes, index) = CaptureVideoReplayTest.load()
    val phone = Phone(maxAgeNs = Long.MAX_VALUE / 4)
    phone.clock.set(index.first { it.direction == CaptureDirection.IN }.monotonicNs)
    phone.server.source = RelaySource.REPLAY
    val port = phone.server.start(code, 0, InetAddress.getLoopbackAddress())
    val headset = Headset()
    val receiver = RelayReceiver(headset)
    try {
      receiver.connect("127.0.0.1", port, code, null, "Test headset", "test")
      assertTrue(eventually { receiver.state == RelayReceiveState.RECEIVING && phone.server.headsetCount == 1 })

      phone.play(bytes, index)
      val sent = phone.sink.units.map { it.first }
      assertEquals(307, sent.size)
      assertTrue("every relayed unit arrives", eventually(20_000) { headset.received.size == sent.size })

      // 1. 307 units, sequence 0 to 306, no BREAK, the same bytes in the same order
      val headers = headset.received.map { it.second }
      assertEquals((0L until 307L).toList(), headers.map { it.sequence })
      assertTrue(headset.received.none { (it.third and RelayWire.UNIT_BREAK) != 0 })
      assertTrue(headset.received.all { (it.third and RelayWire.UNIT_REPLAY) != 0 })
      assertEquals(sha256(sent), sha256(headset.received.map { it.first }))

      // 2. One key unit, the first, with its sets in band, after one PARAMETERS of this session equal to the seed
      assertEquals("parameters", headset.order.first())
      assertEquals("key", headset.order[1])
      assertEquals(1, headset.order.count { it == "key" })
      assertEquals(1, headset.parameters.size)
      assertEquals(DescriptionSource.SESSION, headset.parameters.single().second)
      assertTrue(headset.parameters.single().first.sameSetsAs(ProfileRegistry.seed20261023))
      assertTrue((headset.received.first().third and RelayWire.UNIT_IN_BAND) != 0)

      // 3. H.265 by its parameter sets on the headset; 307 picture counters, 306 steps of one, nothing lost
      val stats = headset.pipeline.stats(System.nanoTime(), 0)
      assertEquals(VideoCodec.H265, stats.codec)
      assertEquals(CodecEvidence.PARAMETER_SETS, stats.codecEvidence)
      assertEquals(DescriptionSource.SESSION, stats.descriptionSource)
      assertEquals(307L, stats.pictureCounters)
      assertEquals(0L, stats.lostPictures)
      assertEquals(0L, stats.encoderRestarts)
      assertEquals(307, headset.sink.units.size)
      val counters = headers.map { it.pictureCounter }
      assertTrue(counters.zipWithNext().all { (a, b) -> b == a + 1 })

      // 4. Telemetry at 10 Hz over the 11.2 s, with the values of the phone's decoder at each tick
      val durationMs = (index.last { it.direction == CaptureDirection.IN }.monotonicNs -
        index.first { it.direction == CaptureDirection.IN }.monotonicNs) / 1_000_000
      assertTrue("${phone.built.size} ticks in $durationMs ms", phone.built.size.toLong() in (durationMs / 100 - 8)..(durationMs / 100 + 2))
      assertTrue(eventually { headset.telemetry.isNotEmpty() })
      assertTrue("${headset.telemetry.size} of ${phone.built.size}", headset.telemetry.size >= phone.built.size * 3 / 4)
      for (record in headset.telemetry) {
        val expected = phone.built[record.sequence]!!
        assertEquals(expected.flight?.value?.copy(flags = 0), record.values.flight?.value)
        assertEquals(expected.battery, record.values.battery)
        assertEquals(expected.gimbal, record.values.gimbal)
        assertEquals(expected.link, record.values.link)
      }
      val modes = headset.telemetry.mapNotNull { it.values.flight?.value?.mode }.distinct()
      assertEquals(listOf(12, 6), modes)
      val batteries = headset.telemetry.mapNotNull { it.values.battery?.value }
      assertTrue(batteries.isNotEmpty())
      assertTrue(batteries.all { it.percent == 38 })
      assertEquals(6.180, batteries.minOf { it.voltageV }, 1e-9)
      assertEquals(6.756, batteries.maxOf { it.voltageV }, 1e-9)

      // 5. The phone's stamps: the last fragment never before the first, the write never before the last, all rising
      assertTrue(headers.all { it.lastArrivalNs >= it.firstArrivalNs && it.sendNs >= it.lastArrivalNs })
      assertTrue(headers.zipWithNext().all { (a, b) -> b.lastArrivalNs >= a.lastArrivalNs && b.sendNs >= a.sendNs })

      // 6. The end of the playback is a new source: RESET
      phone.pipeline.newSource()
      assertTrue(eventually { headset.resets == 1 })
      println(
        "loopback: ${sent.size} units relayed, ${phone.built.size} telemetry ticks over $durationMs ms, " +
          "${headset.telemetry.size} received, sha256 ${sha256(sent)}",
      )
    } finally {
      receiver.disconnect()
      phone.server.stop()
    }
  }

  @Test
  fun aSlowHeadsetGetsBreaksAndTheGapsEqualTheDrops() {
    val (bytes, index) = CaptureVideoReplayTest.load()
    val phone = Phone(maxAgeNs = RelayQueue.MAX_AGE_NS)
    phone.clock.set(index.first { it.direction == CaptureDirection.IN }.monotonicNs)
    phone.server.source = RelaySource.REPLAY
    val port = phone.server.start(code, 0, InetAddress.getLoopbackAddress())
    // A headset that reads one record every 100 ms for its first 40 records, with a small socket buffer
    val socket = Socket().apply {
      receiveBufferSize = 4096
      connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), 5_000)
      soTimeout = 30_000
    }
    val records = CopyOnWriteArrayList<RelayRecord>()
    try {
      val input = java.io.DataInputStream(java.io.BufferedInputStream(socket.getInputStream(), 4096))
      val output = java.io.BufferedOutputStream(socket.getOutputStream())
      val challenge = RelayWire.read(input, true)
      val server = RelayWire.parseChallenge(challenge.body).second
      val client = ByteArray(16) { 5 }
      RelayWire.write(output, RelayWire.HELLO, 0, RelayWire.helloBody(client, RelayWire.proof(code, 1, server, client), "{}"))
      output.flush()
      assertEquals(RelayWire.WELCOME, RelayWire.read(input, true).type)
      assertTrue(eventually { phone.server.headsetCount == 1 })
      val started = System.nanoTime()
      val reader = Thread {
        runCatching {
          while (true) {
            val record = RelayWire.read(input, true)
            records.add(record)
            if (record.type == RelayWire.RESET) {
              break
            }
            if (records.size < 40) {
              Thread.sleep(100)
            }
          }
        }
      }.apply { start() }

      phone.play(bytes, index)
      assertTrue("the queue drains", eventually(30_000) { phone.server.queuedRecords() == 0 })
      Thread.sleep(200)
      phone.server.reset()
      reader.join(30_000)
      println("slow headset read for ${(System.nanoTime() - started) / 1_000_000} ms")

      val units = records.filter { it.type == RelayWire.UNIT }
      val headers = units.map { RelayWire.parseUnitHeader(it.body) }
      // After a drop that left no key unit queued, the phone's kept key unit goes first, flagged KEY, PRIMER and BREAK
      val live = units.filter { (it.flags and RelayWire.UNIT_PRIMER) == 0 }
      val primers = units.size - live.size
      val breaks = live.count { (it.flags and RelayWire.UNIT_BREAK) != 0 }
      var gaps = headers.first().sequence
      headers.zipWithNext().forEach { (a, b) -> gaps += b.sequence - a.sequence - 1 }
      val dropped = phone.server.snapshot().unitsDropped
      assertTrue("units were dropped for the slow headset", dropped > 0)
      assertTrue(breaks >= 1)
      assertTrue(units.filter { (it.flags and RelayWire.UNIT_PRIMER) != 0 }.all {
        (it.flags and RelayWire.UNIT_KEY) != 0 && (it.flags and RelayWire.UNIT_BREAK) != 0
      })
      assertEquals("the drops on the phone are the gaps on the headset", dropped, gaps)
      assertEquals(307L, live.size + dropped)
      // Parsing goes on after each break: every unit after it reads as whole NAL units with a picture counter
      assertTrue(units.all { RelayWire.accessUnitOf(it.body, 0).pictureCounter != null })
      assertEquals(RelayWire.RESET, records.last().type)
      println(
        "slow headset: ${live.size} units received, $dropped dropped in ${phone.server.snapshot().headsets.size} " +
          "headset, $breaks breaks, $primers primers, sequence gaps $gaps, ${records.size} records",
      )
    } finally {
      socket.close()
      phone.server.stop()
    }
  }
}
