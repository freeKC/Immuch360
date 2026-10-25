package app.alextran.immich.djilink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pacing of a receiver (p2/relay-smoothness-2026-10-25.md, 5.1 and 6.2): the content clock of the stream, the
 * adaptive jitter buffer, what is shown, held or skipped, the freezes, the counters and the unit timing ring.
 */
class RelaySmoothingTest {
  private val ms = 1_000_000L
  private val flight = 16_667_000L
  private val ground = 33_333_000L

  @Test
  fun theContentClockIsReadFromSei240AndUnwrapped() {
    val unit = HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.slice(),
      HevcSamples.suffixSeiWithClock(counter = 3842, clockMs = 47_681),
    )
    assertEquals(3842, unit.pictureCounter)
    assertEquals(47_681, unit.contentClockRaw)
    // The short message of the 23 October capture has a counter and no clock
    val short = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(7))
    assertEquals(7, short.pictureCounter)
    assertNull(short.contentClockRaw)
    val clock = ContentClockUnwrapper()
    assertEquals(65_520L, clock.offer(65_520))
    assertEquals(65_537L, clock.offer(1))
    assertEquals(65_554L, clock.offer(18))
    // A step back is a step back, not a wrap forward
    assertEquals(65_504L, clock.offer(65_504))
    clock.reset()
    assertEquals(100L, clock.offer(100))
  }

  @Test
  fun thePipelineUnwrapsTheClockOfEachUnit() {
    val sink = object : DecoderSink {
      val units = mutableListOf<AccessUnit>()

      override fun submit(unit: AccessUnit, description: ResolvedDescription) {
        units += unit
      }

      override fun reset() = Unit

      override fun status(): DecoderStatus = DecoderStatus()
    }
    val store = ParameterSetStore(MemoryKeyValueStore()).apply { seed = ProfileRegistry.seed20261023 }
    val pipeline = VideoPipeline(store, sink)
    val detector = CodecDetector()
    val sets = ProfileRegistry.seed20261023!!
    detector.offer(RelayWire.annexBUnit(sets.configuration(), 0))
    store.onRelayedDescription(sets, DescriptionSource.SESSION)
    for ((index, clock) in listOf(65_500, 65_517, 2, 19).withIndex()) {
      val unit = HevcSamples.unitOf(
        HevcSamples.DELIMITER,
        HevcSamples.slice(),
        HevcSamples.suffixSeiWithClock(counter = index + 1, clockMs = clock),
        arrivalNs = index * flight,
      )
      pipeline.onUnit(unit, detector, detector.offer(unit), index * flight)
    }
    assertEquals(listOf(65_500L, 65_517L, 65_538L, 65_555L), sink.units.map { it.contentMs })
  }

  @Test
  fun aSteadyStreamWaitsTheFloorAndIsNeverLate() {
    val jitter = JitterBuffer()
    var last: JitterBuffer.Placement? = null
    for (index in 0 until 120) {
      val source = index * flight
      last = jitter.place(arrivalNs = 5_000 * ms + source, sourceNs = source, breakBefore = false, leadNs = 50 * ms)
      assertFalse(last.late)
      assertEquals(JitterBuffer.TV_FLOOR_NS, last.targetNs)
    }
    assertEquals(flight, jitter.periodNs)
    assertEquals("the floor and the lead", 200 * ms, last!!.depthNs)
    assertEquals(last.displayNs - 50 * ms, last.feedAtNs)
  }

  @Test
  fun theTargetRisesAtOnceForALateUnitAndFallsTenMillisecondsEveryTwoSeconds() {
    val jitter = JitterBuffer()
    var index = 0L
    fun next(lateNs: Long = 0L): JitterBuffer.Placement {
      val source = index * flight
      index += 1
      return jitter.place(1_000 * ms + source + lateNs, source, false, 0)
    }
    repeat(60) { next() }
    // Wi-Fi jitter under the floor changes nothing
    repeat(60) { next(lateNs = (it % 5) * 8 * ms) }
    assertEquals(JitterBuffer.TV_FLOOR_NS, jitter.targetNs)
    // A unit 250 ms late: the target takes it at once, with one picture more, and the unit is still in time
    val late = next(lateNs = 250 * ms)
    assertEquals(250 * ms + flight, late.targetNs)
    assertFalse(late.late)
    val risenAt = index
    var previous = late.targetNs
    var falls = 0
    var lastFall = risenAt
    repeat(11 * 60) {
      val placed = next()
      if (placed.targetNs != previous) {
        assertEquals("a fall is 10 ms", previous - 10 * ms, placed.targetNs)
        assertTrue("falls are 2 s apart", (index - lastFall) * flight >= 2_000 * ms - flight)
        lastFall = index
        falls += 1
        previous = placed.targetNs
      }
    }
    assertEquals(5, falls)
    assertEquals(250 * ms + flight - 50 * ms, jitter.targetNs)
  }

  @Test
  fun aStallLongerThanTheCeilingIsLateAndTheTargetStopsAtTheCeiling() {
    val jitter = JitterBuffer(JitterBuffer.HEADSET_FLOOR_NS, JitterBuffer.HEADSET_CEILING_NS)
    repeat(30) { jitter.place(it * ground, it * ground, false, 20 * ms) }
    val stalled = jitter.place(30 * ground + 1_000 * ms, 30 * ground, false, 20 * ms)
    assertTrue(stalled.late)
    assertEquals(JitterBuffer.HEADSET_CEILING_NS, stalled.targetNs)
    // The units behind it in the same burst come one picture apart on the display, never all at once
    val after = jitter.place(30 * ground + 1_001 * ms, 31 * ground, false, 20 * ms)
    assertEquals(ground, after.displayNs - stalled.displayNs)
  }

  @Test
  fun anEncoderRestartOrABreakStartsTheBaseAgainWithoutWaiting() {
    val jitter = JitterBuffer()
    repeat(150) { jitter.place(it * ground, it * ground, false, 0) }
    // The landing restart of 25 October: no video for 569 ms, the clock 489 ms on, 80 ms more transit
    val lastSource = 149 * ground
    val restart = jitter.place(149 * ground + 569 * ms, lastSource + 489 * ms, false, 0)
    assertTrue(restart.reanchored)
    assertEquals(lastSource, restart.gapFromNs)
    assertEquals("a target after its arrival, not 80 ms more", 149 * ground + 569 * ms + 150 * ms, restart.displayNs)
    assertEquals(JitterBuffer.TV_FLOOR_NS, restart.targetNs)
    val next = jitter.place(149 * ground + 569 * ms + ground, lastSource + 489 * ms + ground, false, 0)
    assertFalse(next.reanchored)
    assertEquals(ground, next.displayNs - restart.displayNs)
    // A BREAK starts it again too, a step back of the source as well
    assertTrue(jitter.place(20_000 * ms, 6_000 * ms, true, 0).reanchored)
    assertTrue(jitter.place(20_010 * ms, 5_000 * ms, false, 0).reanchored)
    assertEquals(3L, jitter.reanchors)
  }

  @Test
  fun theDisplayNeverGoesBackWhenTheBaseDrops() {
    val jitter = JitterBuffer()
    var last = 0L
    for (index in 0 until 30) {
      // Every unit 40 ms late but one that comes early: the least transit drops by 40 ms
      val early = index == 20
      val placed = jitter.place(index * flight + if (early) 0 else 40 * ms, index * flight, false, 0)
      assertTrue(placed.displayNs >= last)
      last = placed.displayNs
    }
  }

  @Test
  fun aLatePictureIsSkippedOnlyWhenANewerOneIsDue() {
    // Due within two refreshes: to the surface with its time
    assertEquals(PacedRender.Decision.Render(110 * ms), PacedRender.decide(110 * ms, 100 * ms, 126 * ms))
    // Early: held until two refreshes before its time
    assertEquals(PacedRender.Decision.Hold(167 * ms), PacedRender.decide(200 * ms, 100 * ms, null))
    // Late, and the next one is due too: not shown, but it was decoded
    assertEquals(PacedRender.Decision.Skip, PacedRender.decide(90 * ms, 100 * ms, 99 * ms))
    // Late with nothing newer due: shown at once, a late picture rather than none
    assertEquals(PacedRender.Decision.Render(100 * ms), PacedRender.decide(90 * ms, 100 * ms, 106 * ms))
    assertEquals(PacedRender.Decision.Render(100 * ms), PacedRender.decide(90 * ms, 100 * ms, null))
    // The lead follows the decode time, within its bounds
    assertEquals(PacedRender.DEFAULT_LEAD_NS, PacedRender.lead(null, 0))
    assertEquals(30 * ms + flight / 2, PacedRender.lead(30 * ms, flight))
    assertEquals(PacedRender.MIN_LEAD_NS, PacedRender.lead(1 * ms, flight))
    assertEquals(PacedRender.MAX_LEAD_NS, PacedRender.lead(900 * ms, flight))
  }

  /**
   * The feed's rules end to end on a Wi-Fi stall in flight: 600 ms with nothing, then the 36 units of it within 30 ms.
   * Every unit is decoded in order; the late ones are not shown while a newer one is due; the newest due one is shown
   * at once; from there on every picture is shown, one picture period apart.
   */
  @Test
  fun aBurstAfterAStallIsDecodedWholeAndOnlyTheNewestDuePictureShown() {
    val jitter = JitterBuffer()
    val lead = 30 * ms
    class Unit(val arrival: Long, val placed: JitterBuffer.Placement)
    val units = mutableListOf<Unit>()
    for (index in 0 until 200) {
      val source = index * flight
      val arrival = when {
        index < 60 -> source
        index < 96 -> 59 * flight + 600 * ms + (index - 60) * ms
        else -> source
      }
      units += Unit(arrival, jitter.place(arrival, source, false, lead))
    }
    // The decoder takes each unit at its time to go in (or on arrival) and gives its picture 10 ms later
    val outputs = units.map { maxOf(it.arrival, it.placed.feedAtNs) + 10 * ms }
    var decoded = 0
    val shown = mutableListOf<Pair<Int, Long>>()
    var skipped = 0
    for ((index, unit) in units.withIndex()) {
      decoded += 1
      val now = outputs[index]
      // The next picture is known once its unit arrived
      val next = units.getOrNull(index + 1)?.takeIf { it.arrival <= now }?.placed?.displayNs
      when (val decision = PacedRender.decide(unit.placed.displayNs, now, next)) {
        PacedRender.Decision.Skip -> skipped += 1
        is PacedRender.Decision.Render -> shown += index to decision.atNs
        is PacedRender.Decision.Hold -> shown += index to unit.placed.displayNs
      }
    }
    println("stall of 600 ms in flight: $decoded decoded, $skipped not shown, target ${jitter.targetNs / ms} ms after")
    assertEquals(200, decoded)
    assertTrue("some late pictures were not shown", skipped in 1 until 36)
    assertEquals(200 - skipped, shown.size)
    shown.zipWithNext().forEach { (a, b) -> assertTrue("shown in order", b.second >= a.second) }
    // Once caught up, every picture is shown one period apart
    val after = shown.filter { it.first >= 100 }
    assertEquals(100, after.size)
    after.zipWithNext().forEach { (a, b) -> assertEquals(flight, b.second - a.second) }
  }

  @Test
  fun freezesOver300MsAreCountedAndThoseOfTheStreamItselfTold() {
    val freezes = FreezeTracker()
    val gaps = listOf(5_000 * ms to 5_489 * ms)
    val inSource = { from: Long, to: Long -> gaps.any { it.first >= from && it.first < to } }
    var at = 0L
    var source = 0L
    repeat(10) {
      freezes.onShown(at, source, inSource)
      at += flight
      source += flight
    }
    assertEquals(0L, freezes.count)
    // A Wi-Fi stall: 450 ms with nothing new, the stream had no gap
    at += 450 * ms
    source += 450 * ms
    freezes.onShown(at, source, inSource)
    // The encoder restarted: the stream itself stopped
    freezes.onShown(at + 600 * ms, 5_489 * ms, inSource)
    assertEquals(2L, freezes.count)
    assertEquals(1L, freezes.inSource)
    assertEquals(600 * ms, freezes.longestNs)
    assertEquals(450 * ms + flight + 600 * ms, freezes.totalNs)
    // No view for a while: nothing counted over it
    freezes.pause()
    freezes.onShown(at + 5_000 * ms, 9_000 * ms, inSource)
    assertEquals(2L, freezes.count)
  }

  @Test
  fun theCountersOfAPacedReceptionGoInTheLongPing() {
    val stats = SmoothingStats()
    val jitter = JitterBuffer()
    var shownAt = 0L
    for (index in 0 until 60) {
      val stamp = RelayStamp(index.toLong(), 0, index * 17L, index * flight, 0, index * flight + 5 * ms)
      val placed = jitter.place(stamp.arrivalNs, index * flight, false, 30 * ms)
      stamp.sourceNs = index * flight
      stamp.displayNs = placed.displayNs
      stats.onPlaced(placed, jitter.periodNs, 30 * ms, stamp.sourceNs)
      shownAt = placed.displayNs
      // The clocks say the phone reads 1 s ahead
      stats.onShown(shownAt, stamp, stamp.phoneReceiveNs - 1_000 * ms)
    }
    stats.onSkip()
    stats.onStall()
    val numbers = stats.numbers(shownAt)
    assertTrue(numbers.paced)
    assertEquals(60L, numbers.units)
    assertEquals(60L, numbers.shown)
    assertEquals(150.0, numbers.targetMs!!, 0.01)
    assertEquals(180.0, numbers.depthNowMs!!, 0.01)
    assertEquals(1_185.0, numbers.phoneToShownMedianMs!!, 1.0)
    assertEquals(0L, numbers.freezes)
    val ping = numbers.pingNumbers(sequenceGaps = 12, roundTripNs = 9_400_000)
    assertEquals(150, ping.bufferTargetMs)
    assertEquals(1, ping.renderSkips)
    assertEquals(1, ping.decoderStalls)
    assertEquals(12, ping.sequenceGaps)
    assertEquals(9_400, ping.roundTripUs)
    assertEquals(-1, ping.longestFreezeMs)
    // A long ping carries them all, and reads back the same
    val body = RelayWire.pingBody(77, 14_000, 290, ping)
    assertEquals(RelayWire.PING_LONG_BYTES, body.size)
    assertEquals(RelayPing(77, 14_000, 290, ping), RelayWire.parsePing(body))
    assertNull(RelayWire.parsePing(RelayWire.pingBody(77, 14_000, 290)).numbers)
    // The reception record's JSON
    assertEquals(true, numbers.toJson()["paced"].toString().toBoolean())
    stats.reset()
    assertFalse(stats.numbers(0).paced)
  }

  @Test
  fun theUnitTimingRingKeepsEveryUnitWithoutItsBytes() {
    val ring = UnitTimingRing(capacity = 4)
    val stamps = (0 until 6).map { index ->
      RelayStamp(
        sequence = index.toLong() + 100,
        flags = if (index == 2) RelayWire.UNIT_BREAK else 0,
        contentMs = 47_681L + index * 17,
        phoneReceiveNs = 2_000 * ms + index * flight,
        phoneSendNs = 2_000 * ms + index * flight + 3 * ms,
        arrivalNs = 9_000 * ms + index * flight,
      ).also { it.displayNs = it.arrivalNs + 200 * ms }
    }
    val indices = stamps.map { ring.add(it, 36_000, UnitTimingRing.SOURCE_PHONE_CLOCK, it.contentMs) }
    assertEquals(listOf(0L, 1L, 2L, 3L, 4L, 5L), indices)
    assertEquals(6L, ring.total)
    // The two oldest were overwritten: a late update of theirs changes nothing
    ring.onFed(0, 1)
    val third = stamps[2]
    ring.onFed(2, third.arrivalNs + 150 * ms)
    ring.onOutput(2, third.arrivalNs + 170 * ms)
    ring.onResult(2, UnitTimingRing.SHOWN, third.displayNs)
    ring.onRendered(2, third.displayNs + 8 * ms)
    ring.onResult(3, UnitTimingRing.SKIPPED)
    val lines = ring.csv().trim().lines()
    assertEquals(UnitTimingRing.CSV_HEADER, lines.first())
    assertEquals(5, lines.size)
    assertEquals("102,4,phoneClock,shown,36000,47715,0,3000,0,200000,150000,170000,200000,208000", lines[1])
    assertEquals("103,0,phoneClock,skipped,36000,47732,16667,19667,16667,216667,,,,", lines[2])
    assertEquals(stamps[2].arrivalNs to stamps[2].phoneReceiveNs, ring.bases())
  }

  @Test
  fun theFactsOfTheStreamSayKeyPicturesRestartsAndRates() {
    val facts = StreamFacts()
    var at = 0L
    var clock = 10_230L
    fun unit(type: Int = 1, counter: Int = 1): AccessUnit = HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.slice(type = type),
      HevcSamples.suffixSei(counter),
    ).also { it.contentMs = clock }
    facts.onUnit(unit(type = 19), at, restarted = false)
    repeat(40) {
      at += ground
      clock += 33
      facts.onUnit(unit(), at, false)
    }
    // The take off: the encoder starts again at 60 pictures a second
    at += 117 * ms
    clock += 100
    facts.onUnit(unit(type = 19), at, restarted = true)
    repeat(40) {
      at += flight
      clock += 17
      facts.onUnit(unit(), at, false)
    }
    val events = facts.events()
    assertEquals(listOf("key", "rate", "key", "restart", "rate"), events.map { it.kind })
    assertEquals(30L, events[1].value)
    assertEquals(59L, events[4].value)
    assertEquals(2L, facts.keyPictures)
    assertEquals(1L, facts.restarts)
  }

  @Test
  fun aBreakArmsTheKeptKeyPictureAfter250MsWithoutAPicture() {
    val seed = ProfileRegistry.seed20261023!!
    val key = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(type = 19))
    fun p(atMs: Long) = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), arrivalNs = atMs * ms)
    val primer = KeyPrimer()
    primer.keep(key, seed)
    primer.onCodecStarted()
    primer.onQueued(isKey = true)
    primer.onOutput()
    // A refusing decoder: nothing comes out after the BREAK
    primer.onBreak(1_000 * ms)
    assertNull(primer.before(p(1_100), seed))
    assertTrue(primer.before(p(1_250), seed) === key)
    assertTrue(primer.lastWasAfterBreak)
    assertNull(primer.before(p(1_300), seed))
    // A concealing decoder shows a picture first: the old key picture never goes in
    primer.onBreak(2_000 * ms)
    primer.onOutput()
    assertNull(primer.before(p(2_400), seed))
    // A live key picture after the BREAK: nothing to add
    primer.onBreak(3_000 * ms)
    primer.onQueued(isKey = true)
    assertNull(primer.before(p(3_400), seed))
  }

  @Test
  fun aDurationHistogramGivesItsMedianP95AndMaximum() {
    val histogram = DurationHistogram()
    assertNull(histogram.percentileMs(0.5))
    (1..100).forEach { histogram.add(it * ms + 300_000) }
    assertEquals(50.0, histogram.percentileMs(0.5)!!, 0.001)
    assertEquals(95.0, histogram.percentileMs(0.95)!!, 0.001)
    assertEquals(100.3, histogram.maxMs!!, 0.001)
    assertEquals(1.3, histogram.minMs!!, 0.001)
    histogram.add(5_000 * ms)
    assertEquals(5_000.0, histogram.maxMs!!, 0.001)
    assertTrue(histogram.percentileMs(1.0)!! >= 4_992.0)
    val fine = DurationHistogram(100_000L)
    fine.add(250_000)
    fine.add(260_000)
    assertArrayEquals(doubleArrayOf(0.25, 0.26), doubleArrayOf(fine.minMs!!, fine.maxMs!!), 0.0001)
  }
}
