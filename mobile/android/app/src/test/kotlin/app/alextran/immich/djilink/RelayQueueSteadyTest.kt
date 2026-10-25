package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The queue of a receiver on the phone's steady stream (p2/relay-bandwidth-2026-10-25.md, 7.5): a drop empties it, asks
 * for one key picture and skips units until that key, which goes with BREAK and its parameter sets; no primer ever; a
 * switch takes the other stream's backlog away without counting it as a drop; and the key requests of the encoder are
 * coalesced 300 ms apart.
 */
class RelayQueueSteadyTest {
  private val ms = 1_000_000L
  private val parameters = byteArrayOf(0, 0, 0, 1, 0x40, 0x01, 0x0C)

  private fun picture(): AccessUnit = HevcSamples.unitOf(HevcSamples.slice(type = 1, body = 400))

  private fun key(): AccessUnit = HevcSamples.unitOf(HevcSamples.slice(type = 19, body = 800))

  private fun flags(unit: AccessUnit): Int =
    RelayWire.UNIT_PHONE or (if (unit.isKey) RelayWire.UNIT_KEY else 0)

  private fun steadyQueue(): RelayQueue = RelayQueue(maxAgeNs = RelayQueue.TV_MAX_AGE_NS).apply {
    switchStream(toSteady = true, RelayQueue.STEADY_TV_MAX_AGE_NS, breakNext = false)
  }

  private fun offer(queue: RelayQueue, unit: AccessUnit, atNs: Long): RelayQueue.SteadyOffer {
    val sets = if (unit.isKey) parameters else null
    return queue.offerSteadyUnit(unit, flags(unit), sets, RelayWire.PARAMETERS_PHONE_ENCODER, atNs)
  }

  private fun drain(queue: RelayQueue): List<RelayOutgoing> {
    val out = mutableListOf<RelayOutgoing>()
    while (true) {
      out += queue.take(0) ?: return out
    }
  }

  @Test
  fun aSteadyQueueWaitsForAKeyUnitFirst() {
    val queue = steadyQueue()
    assertTrue(queue.isSteady)
    assertTrue(queue.waitsForKey)
    assertFalse(offer(queue, picture(), 0).queued)
    val first = offer(queue, key(), 33 * ms)
    assertTrue(first.queued)
    assertFalse(first.dropped)
    assertFalse(queue.waitsForKey)
    val out = drain(queue)
    assertEquals(listOf(RelayWire.PARAMETERS, RelayWire.UNIT), out.map { it.type })
    assertEquals(RelayWire.PARAMETERS_PHONE_ENCODER, out[0].flags)
    val unit = out[1]
    assertTrue(unit.unit!!.isKey)
    // A join: no BREAK, no primer; the picture skipped before it shows as a gap of one
    assertEquals(0, unit.flags and RelayWire.UNIT_BREAK)
    assertEquals(0, unit.flags and RelayWire.UNIT_PRIMER)
    assertEquals(1L, unit.sequence)
    assertEquals(1L, queue.counters().unitsSkipped)
  }

  @Test
  fun aDropEmptiesTheQueueAndSkipsUnitsUntilTheKeyWhichGoesWithBreakAndItsSets() {
    val queue = steadyQueue()
    offer(queue, key(), 0)
    drain(queue)
    // Nothing leaves for a while: the oldest unit ages
    var now = 0L
    repeat(15) {
      now += 33 * ms
      assertFalse(offer(queue, picture(), now).dropped)
    }
    // 495 ms: still under the bound; then over it
    now += 40 * ms
    val drop = offer(queue, picture(), now)
    assertTrue(drop.dropped)
    assertFalse(drop.queued)
    assertTrue(queue.waitsForKey)
    assertEquals(1L, queue.counters().steadyDrops)
    assertEquals(15L, queue.counters().unitsDropped)
    // Units are skipped until the key made for it
    repeat(3) {
      now += 33 * ms
      val skipped = offer(queue, picture(), now)
      assertFalse(skipped.queued)
      assertFalse(skipped.dropped)
    }
    now += 33 * ms
    val keyOffer = offer(queue, key(), now)
    assertTrue(keyOffer.queued)
    val dropAt = now - 4 * 33 * ms
    val out = drain(queue)
    assertEquals(listOf(RelayWire.PARAMETERS, RelayWire.UNIT), out.map { it.type })
    val unit = out[1]
    assertTrue(unit.unit!!.isKey)
    assertTrue("BREAK on the key", (unit.flags and RelayWire.UNIT_BREAK) != 0)
    assertEquals(0, unit.flags and RelayWire.UNIT_PRIMER)
    assertEquals(dropAt, unit.afterDropNs)
    // The sequence skips the 15 dropped, the one that found the queue too old and the 3 skipped
    assertEquals(1L + 15 + 1 + 3, unit.sequence)
    val counters = queue.counters()
    assertEquals(4L, counters.unitsSkipped)
    assertEquals(0L, counters.recoveryPrimers)
    assertEquals(0L, counters.dropEvents)
    assertEquals(1L, counters.breaksOverload)
  }

  @Test
  fun theTickSeesADropWhenNoUnitComes() {
    val queue = steadyQueue()
    offer(queue, key(), 0)
    offer(queue, picture(), 10 * ms)
    assertFalse(queue.checkSteadyAge(400 * ms))
    assertTrue(queue.checkSteadyAge(600 * ms))
    assertTrue(queue.waitsForKey)
    assertFalse(queue.checkSteadyAge(700 * ms))
  }

  @Test
  fun unitsSentDroppedAndSkippedAddUpToThoseMade() {
    val queue = steadyQueue()
    var now = 0L
    var made = 0L
    var sent = 0L
    val random = java.util.Random(7)
    var stall = 0
    repeat(2_000) { index ->
      now += 33 * ms
      val unit = if (index % 60 == 0) key() else picture()
      made += 1
      offer(queue, unit, now)
      // A path that stalls now and then, from a tenth of a second to a second
      if (stall == 0 && random.nextInt(20) == 0) {
        stall = 3 + random.nextInt(28)
      }
      if (stall > 0) {
        stall -= 1
      } else {
        sent += drain(queue).count { it.unit != null }
      }
    }
    sent += drain(queue).count { it.unit != null }
    val counters = queue.counters()
    assertTrue("some drops", counters.steadyDrops > 0)
    assertEquals(made, counters.steadyOffered)
    assertEquals(made, sent + counters.unitsDropped + counters.unitsSkipped)
  }

  @Test
  fun aSwitchTakesTheOtherStreamsBacklogWithoutADropOrAGap() {
    val queue = RelayQueue(maxAgeNs = RelayQueue.TV_MAX_AGE_NS)
    queue.offerRecord(RelayWire.PARAMETERS, 1, parameters, 0)
    queue.offerUnit(key(), RelayWire.UNIT_KEY, breakBefore = false, nowNs = 0)
    assertNotNull(queue.take(0))
    assertNotNull(queue.take(0))
    repeat(10) { queue.offerUnit(picture(), 0, breakBefore = false, nowNs = it * 16 * ms) }
    queue.offerTelemetry(byteArrayOf(1), 170 * ms)
    val cleared = queue.switchStream(toSteady = true, RelayQueue.STEADY_TV_MAX_AGE_NS, breakNext = true)
    assertEquals(10, cleared)
    // The telemetry stays
    assertEquals(1, queue.size)
    offer(queue, key(), 200 * ms)
    val out = drain(queue)
    assertEquals(listOf(RelayWire.TELEMETRY, RelayWire.PARAMETERS, RelayWire.UNIT), out.map { it.type })
    val unit = out[2]
    assertTrue((unit.flags and RelayWire.UNIT_BREAK) != 0)
    assertTrue((unit.flags and RelayWire.UNIT_PHONE) != 0)
    // No gap: the receiver does not count the backlog as lost on the Wi-Fi
    assertEquals(1L, unit.sequence)
    val counters = queue.counters()
    assertEquals(10L, counters.switchCleared)
    assertEquals(0L, counters.unitsDropped)
    assertEquals(0L, counters.dropEvents)
    assertEquals(1L, counters.breaksSwitch)
  }

  @Test
  fun backToTheFullStreamTheNextUnitBreaksAndTheFullRulesApplyAgain() {
    val queue = steadyQueue()
    offer(queue, key(), 0)
    offer(queue, picture(), 33 * ms)
    queue.switchStream(toSteady = false, breakNext = true)
    assertFalse(queue.isSteady)
    assertFalse(queue.waitsForKey)
    // A unit of the steady stream is no longer taken
    assertFalse(offer(queue, picture(), 50 * ms).queued)
    queue.offerRecord(RelayWire.PARAMETERS, 1, parameters, 60 * ms)
    queue.offerUnit(key(), RelayWire.UNIT_KEY, breakBefore = false, nowNs = 60 * ms)
    val out = drain(queue)
    assertEquals(listOf(RelayWire.PARAMETERS, RelayWire.UNIT), out.map { it.type })
    assertTrue((out[1].flags and RelayWire.UNIT_BREAK) != 0)
    assertEquals(0, out[1].flags and RelayWire.UNIT_PHONE)
  }

  @Test
  fun keyRequestsAreCoalescedThreeHundredMillisecondsApart() {
    val keys = RelayKeyRequests()
    // The encoder's first output is a key picture
    keys.onKey(0)
    // 100 ms after a key: waits until 300 ms after it
    assertFalse(keys.request(RelayKeyCause.DROP, 100 * ms))
    assertFalse(keys.request(RelayKeyCause.JOIN, 150 * ms))
    assertFalse(keys.due(250 * ms))
    assertTrue(keys.due(300 * ms))
    assertFalse(keys.due(310 * ms))
    // Asked and not out yet: a new request is served by it
    assertFalse(keys.request(RelayKeyCause.SWITCH, 320 * ms))
    assertTrue(keys.onKey(340 * ms))
    // 700 ms after the key: asked at once
    assertTrue(keys.request(RelayKeyCause.DROP, 1_040 * ms))
    keys.onKey(1_070 * ms)
    // Within 300 ms of the next periodic key (2 s after the last): it waits for that one
    assertFalse(keys.request(RelayKeyCause.DROP, 2_900 * ms))
    assertFalse(keys.onKey(3_070 * ms))
    assertEquals(mapOf(RelayKeyCause.JOIN to 1L, RelayKeyCause.DROP to 3L, RelayKeyCause.SWITCH to 1L), keys.byCause)
    assertEquals(2L, keys.sent)
    assertEquals(4L, keys.coalesced)
    assertEquals(2L, keys.keysAsked)
    assertEquals(2L, keys.keysPeriodic)
  }

  /** p2/review-bandwidth-2026-10-25.md m1: an encoder whose periodic key does not come when expected */
  @Test
  fun aRequestLeftToThePeriodicKeyIsAskedAnywayWhenThatKeyIsLate() {
    val keys = RelayKeyRequests()
    keys.onKey(0)
    // 1.8 s after the key: left to the periodic one, due at 2 s
    assertFalse(keys.request(RelayKeyCause.DROP, 1_800 * ms))
    assertFalse(keys.due(2_000 * ms))
    // Not there at 2.1 s (an encoder counting its interval in pictures at 15 a second): asked now
    assertTrue(keys.due(2_100 * ms))
    assertFalse(keys.due(2_200 * ms))
    assertEquals(1L, keys.sent)
    assertTrue(keys.onKey(2_150 * ms))
    // The periodic key in time: nothing more is asked
    assertFalse(keys.request(RelayKeyCause.DROP, 3_900 * ms))
    keys.onKey(4_150 * ms)
    assertFalse(keys.due(4_300 * ms))
    assertEquals(1L, keys.sent)
  }

  @Test
  fun aRequestTheEncoderDidNotAnswerWithinASecondIsMadeAgain() {
    val keys = RelayKeyRequests()
    keys.onKey(0)
    assertTrue(keys.request(RelayKeyCause.DROP, 500 * ms))
    assertFalse(keys.request(RelayKeyCause.DROP, 900 * ms))
    assertTrue(keys.request(RelayKeyCause.DROP, 1_600 * ms))
  }
}
