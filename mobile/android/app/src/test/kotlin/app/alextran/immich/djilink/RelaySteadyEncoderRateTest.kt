package app.alextran.immich.djilink

import java.net.InetAddress
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rate of the phone's encoder across receivers, with the real server, the real transcoder on fake codecs and TVs
 * on loopback (p2/noon-test-check-2026-10-26.md C9 and item 3 of its section 4): a TV on the steady stream falls to
 * 1.5 Mbit/s and leaves, the codecs go; the next TV's encoder starts at 8 Mbit/s, the rate of a receiver nothing is
 * known of, not at the 1.5 Mbit/s the first one left.
 */
class RelaySteadyEncoderRateTest {
  private val code = "K7M2Q9XRTH"
  private val ms = 1_000_000L
  private val second = 1_000_000_000L
  private val drone = ResolvedDescription(ProfileRegistry.seed20261023!!, DescriptionSource.SESSION)
  private val vectors: JsonObject by lazy {
    val stream = javaClass.classLoader!!.getResourceAsStream("djilink/relay-encoder-vectors.json")!!
    Json.parseToJsonElement(stream.bufferedReader().readText()).jsonObject
  }

  private fun encoded(index: Int): ByteArray =
    StreamDescription.hexBytes(vectors["a1080"]!!.jsonObject["units"]!!.jsonArray[index].jsonPrimitive.content)!!

  private val phone: ResolvedDescription by lazy {
    ResolvedDescription(EncodedUnits.descriptionOf(encoded(0))!!, DescriptionSource.SESSION)
  }

  @Volatile
  private var now = 1_000_000_000_000L

  /** A TV of this build: it takes the steady stream and sends the longer ping */
  private fun steadyTv(port: Int): TestHeadset = TestHeadset(port, timeoutMs = 20_000).also { tv ->
    val welcome = tv.join(code, "Salon 2", kind = "tv", extra = "\"steady\":1,\"pingBytes\":96")
    assertEquals(RelayWire.WELCOME, welcome.type)
  }

  /** The encoder's next output as a key picture with its sets, from what decoder 2 was given */
  private fun encodeKey(core: RelayTranscoder, codecs: FakeRelayCodecs) {
    for (input in (codecs.decoders.last()).pull(now)) {
      if (core.onDecoded(input.ptsUs, now)) {
        core.onDrawn(input.ptsUs, now)
        core.onEncoded(encoded(0), input.ptsUs, config = false, key = true, nowNs = now)
      }
    }
  }

  @Test
  fun aNewSteadyEncoderStartsAtEightMegabitsNotAtTheRateTheLastReceiverLeft() {
    val codecs = FakeRelayCodecs()
    lateinit var server: RelayServer
    val core = RelayTranscoder(
      codecs,
      clockNs = { now },
      emit = { unit, description -> server.submitSteady(unit, description) },
      worker = { it.run() },
    )
    server = RelayServer(
      clockNs = { now },
      runTicker = false,
      pingTimeoutMs = 600_000,
      writerStallNs = Long.MAX_VALUE / 4,
      // A small send buffer: a TV that reads nothing holds the writer, and the units wait in the phone's queue
      socketTuning = { socket ->
        socket.sendBufferSize = 16 * 1024
        RelaySocketFacts(socket.sendBufferSize, null)
      },
      steady = core,
    )
    val router = RelayRouter(server, core)
    core.start(now)
    server.quality = RelayQuality.STEADY
    val port = server.start(code, 0, InetAddress.getLoopbackAddress())
    server.source = RelaySource.CABLE
    router.submit(HevcSamples.unitOf(HevcSamples.slice(type = 19)).also { it.contentMs = 0 }, drone)
    try {
      // TV 1 joins on the steady stream; the encoder is made at the first need, at 8 Mbit/s
      val first = steadyTv(port)
      assertTrue(eventually { server.headsetCount == 1 })
      now += 100 * ms
      server.tick(now)
      assertEquals(1, codecs.encoders.size)
      assertEquals(8_000_000, codecs.encoders[0].madeAtBps)
      encodeKey(core, codecs)
      assertEquals("steady", server.snapshot().headsets.single().stream)
      // Written before the clock moves on: the tick reads the age of what is still queued
      assertTrue(eventually { server.queuedRecords() == 0 })
      // Its path stalls: 4 MB of the steady stream wait behind a writer the TV no longer reads, 2 s pass, the tick
      // drops them and lowers its rate to the floor (nothing carried in the last second)
      repeat(20) { server.submitSteady(HevcSamples.unitOf(HevcSamples.slice(type = 1, body = 200_000)), phone) }
      Thread.sleep(200)
      now += 2 * second
      server.tick(now)
      assertEquals(1.5, server.snapshot().headsets.single().allowedMegabits!!, 0.001)
      assertEquals(listOf(1_500_000), codecs.encoders[0].bitrates)
      // It leaves: no receiver takes the steady stream any more, the codecs go
      first.close()
      assertTrue(eventually { server.headsetCount == 0 })
      now += 100 * ms
      server.tick(now)
      assertTrue(codecs.encoders[0].released)
      // TV 2 joins: its encoder starts at 8 Mbit/s and is not corrected once its stream runs
      steadyTv(port).use {
        assertTrue(eventually { server.headsetCount == 1 })
        now += 100 * ms
        server.tick(now)
        assertEquals(2, codecs.encoders.size)
        val made = codecs.encoders[1]
        assertEquals(8_000_000, made.madeAtBps)
        encodeKey(core, codecs)
        assertEquals("steady", server.snapshot().headsets.single().stream)
        assertTrue(eventually { server.queuedRecords() == 0 })
        repeat(10) {
          now += 100 * ms
          server.tick(now)
        }
        assertEquals(emptyList<Int>(), made.bitrates)
        val report = server.report(now)["transcoder"]!!.jsonObject
        // The one change is the first TV's fall to the floor
        assertEquals(1L, report["bitrateChanges"]!!.jsonPrimitive.long)
        assertEquals(8_000L, report["bitrateNowKbps"]!!.jsonPrimitive.long)
      }
    } finally {
      server.stop()
      core.stop()
    }
  }
}
