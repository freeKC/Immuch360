package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A receiver's queue on the phone when the Wi-Fi cannot keep up (p2/relay-smoothness-2026-10-25.md, 5.2): it drops
 * rarely, by the age of its kind, and only where the stream stays decodable, back to a key unit it holds or with the
 * kept key unit first; every drop is counted.
 */
class RelayQueueDropTest {
  private val ms = 1_000_000L
  private val flight = 16_667_000L
  private val keyUnit = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(type = 19, body = 200))
  private val kept = RelayPrimer(
    keyUnit,
    RelayWire.UNIT_KEY or RelayWire.UNIT_PRIMER or RelayWire.UNIT_BREAK,
  )

  private fun p(size: Int = 40) = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(body = size))

  private fun RelayQueue.drain(): List<RelayOutgoing> {
    val out = mutableListOf<RelayOutgoing>()
    while (true) {
      out += take(0) ?: return out
    }
  }

  private val RelayOutgoing.breaks: Boolean get() = (flags and RelayWire.UNIT_BREAK) != 0
  private val RelayOutgoing.key: Boolean get() = (flags and RelayWire.UNIT_KEY) != 0

  @Test
  fun aTvKeepsItsBacklogForOneAndAHalfSecondsAndAHeadsetFor500Ms() {
    assertEquals(RelayQueue.TV_MAX_AGE_NS, RelayQueue.maxAgeFor("tv"))
    assertEquals(RelayQueue.MAX_AGE_NS, RelayQueue.maxAgeFor(null))
    val tv = RelayQueue(RelayQueue.maxAgeFor("tv"))
    // 1.4 s of flight with nothing written: all kept
    for (index in 0 until 84) {
      tv.offerUnit(p(), 0, false, index * flight)
    }
    assertEquals(0L, tv.unitsDropped)
    tv.offerUnit(p(), 0, false, 1_510 * ms)
    assertEquals(84L, tv.unitsDropped)
    val headset = RelayQueue(RelayQueue.maxAgeFor(null))
    headset.offerUnit(p(), 0, false, 0)
    headset.offerUnit(p(), 0, false, 490 * ms)
    assertEquals(0L, headset.unitsDropped)
    headset.offerUnit(p(), 0, false, 510 * ms)
    assertEquals(2L, headset.unitsDropped)
    // Within the hold off a headset waits to twice the bound, 1 s, never more (review M4)
    headset.drain()
    headset.offerUnit(p(), 0, false, 600 * ms)
    headset.offerUnit(p(), 0, false, 1_590 * ms)
    assertEquals(2L, headset.unitsDropped)
    headset.offerUnit(p(), 0, false, 1_610 * ms)
    assertEquals(4L, headset.unitsDropped)
  }

  /**
   * A stall right after an encoder start (review M3): the fresh key unit is the oldest queued. It waits to twice the
   * bound, then the units after it go and it stays, sent as a live key unit (not a primer, this receiver never had it);
   * the gap shows after it and the next unit carries BREAK.
   */
  @Test
  fun aFreshKeyUnitAtTheHeadWaitsTwiceTheBoundThenStaysAndGoesLive() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    queue.offerRecord(RelayWire.PARAMETERS, 1, byteArrayOf(7), 0)
    queue.offerUnit(keyUnit, RelayWire.UNIT_KEY, true, 0, primer = { kept })
    repeat(20) { queue.offerUnit(p(), 0, false, (it + 1) * 30 * ms, primer = { kept }) }
    // 600 ms: over the bound, but the key unit is the only picture to start from
    assertEquals(0L, queue.unitsDropped)
    queue.offerUnit(p(), 0, false, 1_001 * ms, primer = { kept })
    assertEquals(20L, queue.unitsDropped)
    // A second offer does not drop again: the key unit kept at the head is not aged again
    queue.offerUnit(p(), 0, false, 1_020 * ms, primer = { kept })
    assertEquals(20L, queue.unitsDropped)
    val taken = queue.drain()
    assertEquals(listOf(RelayWire.PARAMETERS, RelayWire.UNIT, RelayWire.UNIT, RelayWire.UNIT), taken.map { it.type })
    val key = taken[1]
    assertTrue("the key unit goes live", key.unit === keyUnit && key.key && !key.primer)
    assertTrue("with the break of its new stream", key.breaks)
    assertEquals(0L, key.sequence)
    val after = taken[2]
    assertTrue("the unit after the gap breaks", after.breaks && !after.primer)
    assertEquals("the gap after the key unit", 21L, after.sequence)
    assertFalse(taken[3].breaks)
    val counters = queue.counters()
    assertEquals(1L, counters.keyFirstDrops)
    assertEquals(0L, counters.recoveryPrimers)
    assertEquals(0L, counters.cleanRestarts)
    assertEquals(1L, counters.breaksOverload)
    assertEquals(1L, counters.breaksNewStream)
  }

  /** A key unit kept at the head goes with the next restart: its gap moves before the new key unit */
  @Test
  fun aKeyUnitKeptAtTheHeadGoesWithTheNextRestart() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    queue.offerUnit(keyUnit, RelayWire.UNIT_KEY, false, 0, primer = { kept })
    repeat(5) { queue.offerUnit(p(), 0, false, (it + 1) * 100 * ms, primer = { kept }) }
    queue.offerUnit(p(), 0, false, 1_001 * ms, primer = { kept })
    assertEquals(5L, queue.unitsDropped)
    val fresh = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(type = 19, body = 100))
    queue.offerUnit(fresh, RelayWire.UNIT_KEY, false, 1_100 * ms, primer = { kept })
    queue.offerUnit(p(), 0, false, 2_000 * ms, primer = { kept })
    queue.offerUnit(p(), 0, false, 3_200 * ms, primer = { kept })
    val taken = queue.drain()
    val units = taken.filter { it.type == RelayWire.UNIT }
    assertTrue(units.first().unit === fresh && units.first().breaks && !units.first().primer)
    assertEquals("the key unit, the five after it and the one after them", 7L, units.first().sequence)
  }

  @Test
  fun afterADropNoneForTwoSecondsUnlessTheAgePassesTwiceTheBound() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    queue.offerUnit(p(), 0, false, 0)
    queue.offerUnit(p(), 0, false, 501 * ms)
    assertEquals(1L, queue.overloadCount)
    // 700 ms old one second later: over the bound, under twice, within 2 s: kept
    queue.offerUnit(p(), 0, false, 1_201 * ms)
    assertEquals(1L, queue.overloadCount)
    // Twice the bound passed: dropped whatever the hold off
    queue.offerUnit(p(), 0, false, 1_502 * ms)
    assertEquals(2L, queue.overloadCount)
    // The hold off is over 2 s after the last drop
    queue.offerUnit(p(), 0, false, 3_000 * ms)
    queue.offerUnit(p(), 0, false, 3_600 * ms)
    assertEquals(3L, queue.overloadCount)
  }

  @Test
  fun aDropGoesBackToTheNewestKeyUnitQueuedWithItsParameterSets() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    queue.offerRecord(RelayWire.PARAMETERS, 1, byteArrayOf(1), 0)
    queue.offerUnit(keyUnit, RelayWire.UNIT_KEY, false, 0)
    queue.offerUnit(p(), 0, false, 10 * ms)
    queue.offerTelemetry("{}".toByteArray(), 20 * ms)
    queue.offerRecord(RelayWire.PARAMETERS, 1, byteArrayOf(2), 300 * ms)
    queue.offerUnit(keyUnit, RelayWire.UNIT_KEY, false, 300 * ms)
    queue.offerUnit(p(), 0, false, 320 * ms)
    // The oldest is 600 ms old: back to the second key unit, nothing after it goes
    queue.offerUnit(p(), 0, false, 600 * ms, primer = { kept })
    val taken = queue.drain()
    assertEquals(
      listOf(RelayWire.TELEMETRY, RelayWire.PARAMETERS, RelayWire.UNIT, RelayWire.UNIT, RelayWire.UNIT),
      taken.map { it.type },
    )
    assertEquals(2, taken[1].body!![0].toInt())
    val key = taken[2]
    assertTrue(key.unit === keyUnit && key.breaks && !key.primer)
    assertEquals("the sequence skips the two units before it", 2L, key.sequence)
    assertFalse(taken[3].breaks)
    val counters = queue.counters()
    assertEquals(1L, counters.cleanRestarts)
    assertEquals(0L, counters.recoveryPrimers)
    assertEquals(2L, counters.unitsDropped)
    assertEquals(1L, counters.breaksOverload)
  }

  @Test
  fun aKeyUnitThatComesOnADropStartsTheStreamAgainFromItself() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    repeat(10) { queue.offerUnit(p(), 0, false, it * 50 * ms) }
    queue.offerRecord(RelayWire.PARAMETERS, 1, byteArrayOf(3), 520 * ms)
    queue.offerUnit(keyUnit, RelayWire.UNIT_KEY, false, 520 * ms, primer = { kept })
    val taken = queue.drain()
    assertEquals(listOf(RelayWire.PARAMETERS, RelayWire.UNIT), taken.map { it.type })
    assertTrue(taken[1].breaks && taken[1].key && !taken[1].primer)
    assertEquals(10L, taken[1].sequence)
    assertEquals(1L, queue.counters().cleanRestarts)
  }

  @Test
  fun withoutAKeyUnitQueuedTheKeptOneGoesFirstFlaggedKeyPrimerAndBreak() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    repeat(5) { queue.offerUnit(p(), 0, false, it * 100 * ms) }
    queue.offerUnit(p(), 0, false, 600 * ms, primer = { kept })
    assertEquals("not written yet", 0L, queue.counters().recoveryPrimers)
    val taken = queue.drain()
    assertEquals(2, taken.size)
    val primer = taken[0]
    assertTrue(primer.primer && primer.unit === keyUnit && primer.key && primer.breaks)
    assertTrue((primer.flags and RelayWire.UNIT_PRIMER) != 0)
    assertEquals("the gap shows at the primer", 5L, primer.sequence)
    val live = taken[1]
    assertTrue("the live unit after it breaks too", live.breaks && !live.primer)
    assertEquals(6L, live.sequence)
    val counters = queue.counters()
    assertEquals("counted once written", 1L, counters.recoveryPrimers)
    assertEquals(5L, counters.unitsDropped)
    assertEquals("a primer is no unit dropped nor a break of the live stream", 1L, counters.breaksOverload)
    // No kept key unit (another description): the live unit breaks alone
    val bare = RelayQueue(maxAgeNs = 500 * ms)
    bare.offerUnit(p(), 0, false, 0)
    bare.offerUnit(p(), 0, false, 600 * ms, primer = { null })
    assertEquals(listOf(false), bare.drain().map { it.primer })
  }

  @Test
  fun theBreaksAreCountedByCauseAndTheQueueByItsMaxima() {
    val queue = RelayQueue(maxAgeNs = 500 * ms)
    queue.offerUnit(p(1_000), 0, false, 0)
    queue.offerUnit(p(1_000), 0, true, 100 * ms)
    queue.offerUnit(p(1_000), 0, false, 400 * ms)
    assertEquals(400 * ms, queue.takeMaxAgeSinceSample())
    assertEquals(0L, queue.takeMaxAgeSinceSample())
    queue.drain()
    queue.offerUnit(p(), 0, false, 1_000 * ms)
    queue.offerUnit(p(), 0, false, 1_600 * ms)
    queue.drain()
    val counters = queue.counters()
    assertEquals(1L, counters.breaksNewStream)
    assertEquals(1L, counters.breaksOverload)
    assertEquals(3, counters.maxRecords)
    assertEquals(600 * ms, counters.maxAgeNs)
    assertTrue(counters.maxUnitBytes >= 3_000)
  }

  /**
   * A slow receiver simulated: the drone sends 60 units of 36 KiB a second, one key unit at the start only, the Wi-Fi
   * writes 40 a second for 20 s. Whatever the drops, every gap the receiver sees is followed first by a key unit (the
   * kept one, or a queued one), the drops are 2 s apart at least, and the units sent plus those dropped are those made.
   */
  @Test
  fun aSlowReceiverAlwaysGetsAKeyPictureAfterAGap() {
    val queue = RelayQueue(RelayQueue.maxAgeFor("tv"))
    val units = 60 * 20
    val written = mutableListOf<RelayOutgoing>()
    var lastKey: RelayPrimer? = null
    val dropTimes = mutableListOf<Long>()
    var nextWrite = 0L
    for (index in 0 until units) {
      val now = index * flight
      val unit = if (index == 0) keyUnit else p(36 * 1024)
      if (unit.isKey) {
        lastKey = RelayPrimer(unit, RelayWire.UNIT_KEY or RelayWire.UNIT_PRIMER or RelayWire.UNIT_BREAK)
      }
      val before = queue.overloadCount
      queue.offerUnit(unit, if (unit.isKey) RelayWire.UNIT_KEY else 0, false, now, primer = { lastKey })
      if (queue.overloadCount > before) {
        dropTimes += now
      }
      // The writer: one record each 25 ms
      while (nextWrite <= now) {
        queue.take(0)?.let { written += it }
        nextWrite += 25 * ms
      }
    }
    written += queue.drain()
    assertTrue("the Wi-Fi was too slow: units were dropped", queue.unitsDropped > 0)
    assertTrue(dropTimes.size >= 2)
    dropTimes.zipWithNext().forEach { (a, b) -> assertTrue("drops 2 s apart", b - a >= RelayQueue.HOLD_OFF_NS) }
    var expected = 0L
    for (record in written) {
      if (record.sequence != expected) {
        assertTrue("after a gap, a key picture first", record.key && record.breaks)
      }
      expected = record.sequence + 1
    }
    val live = written.count { !it.primer }
    assertEquals(units.toLong(), live + queue.unitsDropped)
    assertEquals(queue.counters().recoveryPrimers, written.count { it.primer }.toLong())
  }
}
