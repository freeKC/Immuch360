package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong

/** One headset's queue (design 4.8): units are never dropped one by one, only the newest telemetry waits, pongs first */
class RelayHeadsetQueueTest {
  private val ms = 1_000_000L

  private fun unit(size: Int = 40) = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(body = size))

  private fun RelayQueue.drain(): List<RelayOutgoing> {
    val out = mutableListOf<RelayOutgoing>()
    while (true) {
      out += take(0) ?: return out
    }
  }

  @Test
  fun noUnitIsDroppedUnder500Ms() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    for (index in 0 until 15) {
      assertTrue(queue.offerUnit(unit(), 0, false, index * 33 * ms))
    }
    val taken = queue.drain()
    assertEquals((0L until 15L).toList(), taken.map { it.sequence })
    assertTrue(taken.none { (it.flags and RelayWire.UNIT_BREAK) != 0 })
    assertEquals(0L, queue.unitsDropped)
  }

  @Test
  fun aBacklogOlderThan500MsIsDroppedWholeAndTheNextUnitBreaks() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    queue.offerUnit(unit(), 0, false, 0)
    queue.offerUnit(unit(), 0, false, 300 * ms)
    queue.offerTelemetry("{}".toByteArray(), 300 * ms)
    // The oldest unit is 501 ms old when the next one comes: both queued units go, the telemetry stays
    queue.offerUnit(unit(), RelayWire.UNIT_KEY, false, 501 * ms)
    val taken = queue.drain()
    assertEquals(listOf(RelayWire.TELEMETRY, RelayWire.UNIT), taken.map { it.type })
    val next = taken.last()
    assertEquals("the sequence skips the two dropped units", 2L, next.sequence)
    assertEquals(RelayWire.UNIT_KEY or RelayWire.UNIT_BREAK, next.flags)
    assertEquals(2L, queue.unitsDropped)
    assertEquals(1L, queue.overloadCount)
    // The following one continues
    queue.offerUnit(unit(), 0, false, 520 * ms)
    val after = queue.take(0)!!
    assertEquals(3L, after.sequence)
    assertEquals(0, after.flags)
  }

  @Test
  fun moreThanTheBytesBoundIsDroppedWhole() {
    val queue = RelayQueue(maxBytes = 200)
    val size = unit().size
    val fit = 200 / size
    repeat(fit) { queue.offerUnit(unit(), 0, false, it.toLong()) }
    queue.offerUnit(unit(), 0, false, fit.toLong())
    val taken = queue.drain()
    assertEquals(1, taken.size)
    assertEquals(fit.toLong(), taken.single().sequence)
    assertTrue((taken.single().flags and RelayWire.UNIT_BREAK) != 0)
    assertEquals(fit.toLong(), queue.unitsDropped)
  }

  @Test
  fun onlyTheNewestTelemetryWaitsAndAPongGoesFirst() {
    val queue = RelayQueue()
    queue.offerUnit(unit(), 0, false, 0)
    queue.offerTelemetry("{\"seq\":1}".toByteArray(), 0)
    queue.offerTelemetry("{\"seq\":2}".toByteArray(), 0)
    queue.offerPong(RelayWire.pongBody(1, 2, 0), 0)
    queue.offerPong(RelayWire.pongBody(3, 4, 0), 0)
    val taken = queue.drain()
    assertEquals(listOf(RelayWire.PONG, RelayWire.PONG, RelayWire.UNIT, RelayWire.TELEMETRY), taken.map { it.type })
    assertEquals(1L, RelayWire.parsePong(taken[0].body!!).pingSendNs)
    assertEquals("{\"seq\":2}", String(taken[3].body!!))
  }

  @Test
  fun aNewSourceDropsTheOldUnitsWithoutAGapOrABreak() {
    val queue = RelayQueue()
    queue.offerUnit(unit(), 0, false, 0)
    queue.offerRecord(RelayWire.PARAMETERS, 1, ByteArray(4), 0)
    queue.offerUnit(unit(), 0, false, 0)
    queue.clearForReset()
    queue.offerRecord(RelayWire.RESET, 0, "{}".toByteArray(), 0)
    queue.offerUnit(unit(), 0, false, 0)
    val taken = queue.drain()
    assertEquals(listOf(RelayWire.RESET, RelayWire.UNIT), taken.map { it.type })
    assertEquals(0L, taken.last().sequence)
    assertEquals(0, taken.last().flags)
    assertEquals(0L, queue.unitsDropped)
  }

  @Test
  fun aBreakAskedBeforeAUnitStaysWithItAndSurvivesADrop() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    queue.offerUnit(unit(), 0, false, 0)
    queue.offerUnit(unit(), 0, true, 10 * ms)
    assertEquals(0, queue.take(0)!!.flags)
    assertEquals(RelayWire.UNIT_BREAK, queue.take(0)!!.flags)
    queue.offerUnit(unit(), 0, true, 20 * ms)
    queue.offerUnit(unit(), 0, false, 600 * ms)
    val next = queue.take(0)!!
    assertEquals(RelayWire.UNIT_BREAK, next.flags)
  }

  @Test
  fun aFinishWritesItsRecordThenNothingMore() {
    val queue = RelayQueue()
    queue.offerUnit(unit(), 0, false, 0)
    queue.finish(RelayWire.BYE, "{\"why\":\"stopped\"}".toByteArray(), 0)
    assertFalse(queue.offerUnit(unit(), 0, false, 0))
    assertFalse(queue.offerTelemetry(ByteArray(2), 0))
    val taken = queue.take(0)
    assertNotNull(taken)
    assertEquals(RelayWire.BYE, taken!!.type)
    assertNull(queue.take(10))
    assertTrue(queue.done)
  }

  @Test
  fun aWriterStalledFor3SecondsIsClosed() {
    val now = AtomicLong(1_000 * ms)
    val server = RelayServer(clockNs = { now.get() }, runTicker = false)
    val port = server.start("K7M2Q9XRTH", 0, InetAddress.getLoopbackAddress())
    // A headset that never reads, with a receive buffer as small as the system allows
    val socket = Socket().apply {
      receiveBufferSize = 2048
      connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), 2_000)
      soTimeout = 2_000
    }
    try {
      val headset = TestHeadsetOver(socket)
      assertEquals(RelayWire.WELCOME, headset.join("K7M2Q9XRTH").type)
      assertTrue(eventually { server.headsetCount == 1 })
      server.source = RelaySource.CABLE
      val description = ResolvedDescription(ProfileRegistry.seed20261023!!, DescriptionSource.SESSION)
      // Far more than the socket buffers hold, in units the queue keeps (fresh, under 4 MiB in all)
      repeat(30) { server.submit(unit(100_000), description) }
      assertTrue("the writer blocks on the full socket", eventually(5_000) { server.writersInARecord() == 1 })
      Thread.sleep(300)
      assertEquals("and stays blocked", 1, server.writersInARecord())
      now.addAndGet(2_900 * ms)
      server.tick(now.get())
      assertEquals("not yet", 1, server.headsetCount)
      now.addAndGet(200 * ms)
      server.tick(now.get())
      assertTrue(eventually { server.headsetCount == 0 })
    } finally {
      socket.close()
      server.stop()
    }
  }

  /** The hand written headset over a socket already connected */
  private class TestHeadsetOver(private val socket: Socket) {
    val input = java.io.DataInputStream(java.io.BufferedInputStream(socket.getInputStream()))
    val output = java.io.BufferedOutputStream(socket.getOutputStream())

    fun join(code: String): RelayRecord {
      val challenge = RelayWire.read(input, true)
      val server = RelayWire.parseChallenge(challenge.body).second
      val client = ByteArray(16) { 1 }
      val proof = RelayWire.proof(code, RelayWire.ROLE_HEADSET, server, client)
      RelayWire.write(output, RelayWire.HELLO, 0, RelayWire.helloBody(client, proof, "{}"))
      output.flush()
      return RelayWire.read(input, true)
    }
  }
}
