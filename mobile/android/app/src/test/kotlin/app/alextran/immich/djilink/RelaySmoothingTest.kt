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
  fun aLatePictureIsSkippedOnlyWhenANewerDecodedOneIsDue() {
    val steps = mutableListOf<PacedRelease.Step<String>>()
    fun PacedRelease<String>.at(nowNs: Long): Long? {
      steps.clear()
      return release(nowNs, flight, steps)
    }
    val release = PacedRelease<String>()
    // Due within two refreshes: to the surface with its time
    release.add("a", 110 * ms)
    assertNull(release.at(100 * ms))
    assertEquals(listOf<PacedRelease.Step<String>>(PacedRelease.Step.Render("a", 110 * ms)), steps)
    // Early: held until two refreshes before its time
    release.add("b", 200 * ms)
    assertEquals(167 * ms, release.at(100 * ms))
    assertTrue(steps.isEmpty())
    assertEquals(listOf<PacedRelease.Step<String>>(PacedRelease.Step.Render("b", 200 * ms)).size, 1)
    release.at(167 * ms)
    assertEquals(listOf<PacedRelease.Step<String>>(PacedRelease.Step.Render("b", 200 * ms)), steps)
    // Late, and the next decoded one is due too: not shown, but it was decoded
    release.add("c", 300 * ms)
    release.add("d", 316 * ms)
    release.at(330 * ms)
    assertEquals(
      listOf<PacedRelease.Step<String>>(PacedRelease.Step.Skip("c"), PacedRelease.Step.Render("d", 330 * ms)),
      steps,
    )
    // Late with the next decoded one not due yet: shown now, the next one at its time
    release.add("e", 340 * ms)
    release.add("f", 400 * ms)
    release.at(350 * ms)
    assertEquals(listOf<PacedRelease.Step<String>>(PacedRelease.Step.Render("e", 350 * ms)), steps)
    release.at(370 * ms)
    assertEquals(listOf<PacedRelease.Step<String>>(PacedRelease.Step.Render("f", 400 * ms)), steps)
    // Late with nothing newer decoded: shown, whatever is still in the decoder or the queue; but a late picture waits
    // its turn, one picture after the one before
    val late = PacedRelease<String>()
    late.add("g", 500 * ms)
    late.at(600 * ms)
    assertEquals(listOf<PacedRelease.Step<String>>(PacedRelease.Step.Render("g", 600 * ms)), steps)
    late.add("h", 516 * ms)
    assertEquals(600 * ms + flight, late.at(605 * ms))
    assertTrue(steps.isEmpty())
    // A newer decoded picture came meanwhile: it takes the turn, the older one is not shown
    late.add("i", 533 * ms)
    late.at(600 * ms + flight)
    assertEquals(
      listOf<PacedRelease.Step<String>>(PacedRelease.Step.Skip("h"), PacedRelease.Step.Render("i", 600 * ms + flight)),
      steps,
    )
    // The turn comes every 50 ms at least, whatever the period
    late.add("j", 540 * ms)
    steps.clear()
    assertEquals(600 * ms + flight + 50 * ms, late.release(620 * ms, 200 * ms, steps))
    assertEquals(listOf("i", "j"), listOf("i") + late.clear())
    // The lead follows the decode time, within its bounds
    assertEquals(PacedRender.DEFAULT_LEAD_NS, PacedRender.lead(null, 0))
    assertEquals(30 * ms + flight / 2, PacedRender.lead(30 * ms, flight))
    assertEquals(PacedRender.MIN_LEAD_NS, PacedRender.lead(1 * ms, flight))
    assertEquals(PacedRender.MAX_LEAD_NS, PacedRender.lead(900 * ms, flight))
  }

  /** What a paced reception showed in [paced]: the unit and its render time for each picture shown, and the skips */
  private class Shown(val shown: List<Pair<Int, Long>>, val skipped: List<Int>, val display: List<Long>) {
    /** The longest time between two pictures shown from [fromNs] on */
    fun longestGapFrom(fromNs: Long): Long =
      shown.map { it.second }.filter { it >= fromNs }.zipWithNext().maxOfOrNull { (a, b) -> b - a } ?: 0L
  }

  /**
   * A paced reception end to end with a decoder of finite throughput: each unit is placed by the real [JitterBuffer] on
   * arrival, goes to the decoder at its time to feed (or on arrival), starts once the decoder finished the one before
   * ([serviceNs] each, its throughput), and comes out [latencyNs] after it started at the earliest, so that several
   * pictures may be in flight; the real [PacedRelease] takes each output when it comes and wakes when it asks.
   */
  private fun paced(
    arrivals: List<Long>,
    sources: List<Long>,
    serviceNs: Long,
    latencyNs: Long = serviceNs,
    leadNs: Long = 30 * ms,
  ): Shown {
    val jitter = JitterBuffer()
    val placed = arrivals.indices.map { jitter.place(arrivals[it], sources[it], false, leadNs) }
    val outputs = LongArray(arrivals.size)
    var free = Long.MIN_VALUE
    for (index in arrivals.indices) {
      val start = maxOf(arrivals[index], placed[index].feedAtNs, free)
      free = start + serviceNs
      outputs[index] = maxOf(start + latencyNs, if (index > 0) outputs[index - 1] else Long.MIN_VALUE)
    }
    val release = PacedRelease<Int>()
    val steps = mutableListOf<PacedRelease.Step<Int>>()
    val shown = mutableListOf<Pair<Int, Long>>()
    val skipped = mutableListOf<Int>()
    var next = 0
    var wake: Long? = null
    while (next < outputs.size || release.size > 0) {
      val output = if (next < outputs.size) outputs[next] else Long.MAX_VALUE
      val now = if (wake != null && wake < output) wake else output
      while (next < outputs.size && outputs[next] <= now) {
        release.add(next, placed[next].displayNs)
        next += 1
      }
      steps.clear()
      wake = release.release(now, jitter.periodNs, steps)
      for (step in steps) {
        when (step) {
          is PacedRelease.Step.Render -> shown += step.item to step.atNs
          is PacedRelease.Step.Skip -> skipped += step.item
        }
      }
    }
    shown.zipWithNext().forEach { (a, b) -> assertTrue("shown in order", b.first > a.first && b.second >= a.second) }
    return Shown(shown, skipped, placed.map { it.displayNs })
  }

  /**
   * A decoder of 45 pictures a second on the 60 a second of a flight, 10 s (p2/review-relay-2026-10-25.md B1.1): it
   * cannot keep up, and every picture it makes is shown, never one picture held for seconds.
   */
  @Test
  fun aDecoderSlowerThanTheStreamShowsEveryPictureItMakes() {
    val sources = (0 until 600).map { it * flight }
    val run = paced(arrivals = sources.map { it + 5 * ms }, sources = sources, serviceNs = 1_000 * ms / 45)
    val inTenSeconds = run.shown.count { it.second <= 10_000 * ms }
    println("a decoder at 45 a second on a 60 a second stream: ${run.shown.size} shown, ${run.skipped.size} skipped")
    assertEquals(0, run.skipped.size)
    assertTrue("about 45 a second shown, $inTenSeconds in 10 s", inTenSeconds >= 430)
    assertTrue("never a picture held for long", run.longestGapFrom(0) <= 1_000 * ms / 45 + ms)
  }

  /**
   * A stall of 1 s in flight, then a decoder at 1.2 times real time (B1.2): it needs about 5 s to catch up, during
   * which the screen gets a new picture at least every picture period or as fast as the decoder makes them, and then
   * every picture is on time again.
   */
  @Test
  fun afterAOneSecondStallASlowDecoderCatchesUpWithoutAFreeze() {
    val sources = (0 until 900).map { it * flight }
    val arrivals = sources.mapIndexed { index, source ->
      if (index in 120 until 180) 180 * flight + 5 * ms + (index - 120) * ms / 2 else source + 5 * ms
    }
    val run = paced(arrivals, sources, serviceNs = 1_000 * ms / 72)
    val stallEnds = 180 * flight + 5 * ms
    val longest = run.longestGapFrom(stallEnds + 200 * ms)
    println("1 s stall, decoder at 1.2 times real time: longest wait ${longest / ms} ms, ${run.skipped.size} skipped")
    assertTrue("no freeze while it catches up: ${longest / ms} ms", longest <= flight + ms)
    // Caught up: the last second is shown on time, each picture at its display time
    val last = run.shown.filter { it.first >= 840 }
    assertEquals(60, last.size)
    last.forEach { (index, at) -> assertEquals(run.display[index], at) }
  }

  /**
   * The feed's rules end to end on a Wi-Fi stall in flight: 600 ms with nothing, then the 36 units of it within 30 ms,
   * on a fast decoder with several pictures in flight. Every unit is decoded in order; the late pictures overtaken by a
   * newer decoded one are not shown; the screen gets a new picture at least every picture period; from there on every
   * picture is shown, one picture period apart.
   */
  @Test
  fun aBurstAfterAStallIsDecodedWholeAndOnlyTheNewestDuePictureShown() {
    val sources = (0 until 200).map { it * flight }
    val arrivals = sources.mapIndexed { index, source ->
      when {
        index < 60 -> source
        index < 96 -> 59 * flight + 600 * ms + (index - 60) * ms
        else -> source
      }
    }
    val run = paced(arrivals, sources, serviceNs = 3 * ms, latencyNs = 12 * ms)
    println("stall of 600 ms in flight: ${run.shown.size} shown, ${run.skipped.size} not shown")
    assertEquals(200, run.shown.size + run.skipped.size)
    assertTrue("some late pictures were not shown", run.skipped.size in 1 until 36)
    assertTrue("a picture at least each period", run.longestGapFrom(59 * flight + 600 * ms) <= flight + ms)
    // Once caught up, every picture is shown one period apart
    val after = run.shown.filter { it.first >= 100 }
    assertEquals(100, after.size)
    after.zipWithNext().forEach { (a, b) -> assertEquals(flight, b.second - a.second) }
  }

  /** A decoder with five pictures in flight on a steady stream: every picture shown at its time, none skipped */
  @Test
  fun picturesStillInTheDecoderNeverMakeOneSkipped() {
    val sources = (0 until 300).map { it * flight }
    val run = paced(sources.map { it + 3 * ms }, sources, serviceNs = 4 * ms, latencyNs = 5 * flight, leadNs = 100 * ms)
    assertEquals(0, run.skipped.size)
    run.shown.forEach { (index, at) -> assertEquals(run.display[index], at) }
  }

  /** A new base, lower or higher, moves the display times by a millisecond a picture at most (review m2) */
  @Test
  fun aNewBaseIsTakenAMillisecondAPicture() {
    val jitter = JitterBuffer()
    val displays = mutableListOf<Long>()
    for (index in 0 until 120) {
      val source = index * flight
      // Every unit 40 ms of transit but one with none at 60: the least transit drops by 40 ms at once
      val transit = if (index == 60) 0L else 40 * ms
      displays += jitter.place(source + transit, source, false, 0).displayNs
    }
    displays.zipWithNext().drop(1).forEach { (a, b) ->
      assertTrue("a step of ${(b - a) / 1e6} ms", b - a in flight - ms..flight + ms)
    }
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
  fun aGapArmsTheKeptKeyPictureAfter250MsWithoutAPicture() {
    val seed = ProfileRegistry.seed20261023!!
    val key = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(type = 19))
    fun p(atMs: Long) = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), arrivalNs = atMs * ms)
    val primer = KeyPrimer()
    primer.keep(key, seed)
    primer.onCodecStarted()
    primer.onQueued(isKey = true)
    primer.onOutput(0)
    // A refusing decoder: nothing comes out after the gap
    primer.onGap(1_000 * ms, pts = 1_000_000)
    assertNull(primer.before(p(1_100), seed))
    assertTrue(primer.before(p(1_250), seed) === key)
    assertTrue(primer.lastWasAfterBreak)
    assertNull(primer.before(p(1_300), seed))
    // A concealing decoder shows a picture of the unit after the gap: the old key picture never goes in
    primer.onGap(2_000 * ms, pts = 2_000_000)
    primer.onOutput(2_000_000)
    assertNull(primer.before(p(2_400), seed))
    // A live key picture after the gap: nothing to add
    primer.onGap(3_000 * ms, pts = 3_000_000)
    primer.onQueued(isKey = true)
    assertNull(primer.before(p(3_400), seed))
    // A picture of a unit fed before the gap, out after it, does not end the wait (review m1)
    primer.onGap(4_000 * ms, pts = 4_000_000)
    primer.onOutput(3_990_000)
    assertTrue(primer.before(p(4_300), seed) === key)
  }

  /**
   * A picture lost on the radio is forwarded as is: the step of the picture counter arms the kept key picture as a
   * BREAK does (review M5); a key unit, even with BREAK, arms nothing (review m1)
   */
  @Test
  fun aStepOfThePictureCounterArmsTheKeptKeyPicture() {
    val seed = ProfileRegistry.seed20261023!!
    val key = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(type = 19), HevcSamples.suffixSei(10))
    fun p(counter: Int, atMs: Long) = HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.slice(),
      HevcSamples.suffixSei(counter),
      arrivalNs = atMs * ms,
    )
    val primer = KeyPrimer()
    primer.keep(key, seed)
    primer.onCodecStarted()
    primer.onQueuedUnit(key, 0, pts = 0, gapBefore = true)
    primer.onOutput(0)
    var pts = 1L
    for (counter in 11..20) {
      val unit = p(counter, counter * 17L)
      assertNull(primer.before(unit, seed))
      primer.onQueuedUnit(unit, unit.lastArrivalNs, pts++, gapBefore = false)
      primer.onOutput(pts - 1)
    }
    // Pictures 21 and 22 lost on the radio: 23 comes, then nothing out of a refusing decoder
    val after = p(23, 400)
    primer.onQueuedUnit(after, after.lastArrivalNs, pts++, gapBefore = false)
    assertNull(primer.before(p(24, 600), seed))
    assertTrue(primer.before(p(25, 660), seed) === key)
    // A key unit with BREAK (a clean restart on the phone) is no gap
    val other = KeyPrimer()
    other.keep(key, seed)
    other.onCodecStarted()
    other.onQueuedUnit(key, 0, pts = 0, gapBefore = true)
    assertNull(other.before(p(11, 400), seed))
  }

  /**
   * The safety net no longer erases the freeze it ends (review M2): 3 s with nothing shown, the net, then a picture:
   * one freeze of 3 s and more. The age of the last picture shown says the screen stood still meanwhile (review M1).
   */
  @Test
  fun aFreezeEndedAfterTheSafetyNetCountsWholeAndTheAgeOfThePictureSaysIt() {
    val stats = SmoothingStats()
    fun stamp(index: Int) = RelayStamp(index.toLong(), 0, -1, index * flight, index * flight, index * flight + 5 * ms)
      .also { it.sourceNs = index * flight }
    for (index in 0 until 30) {
      stats.onShown(index * flight + 200 * ms, stamp(index), index * flight)
    }
    val lastShown = 29 * flight + 200 * ms
    assertEquals(0.0, stats.numbers(lastShown).lastPictureAgoMs!!, 0.01)
    stats.onSafetyNet(lastShown + 3_000 * ms)
    val during = stats.numbers(lastShown + 3_100 * ms)
    assertEquals(3_100.0, during.lastPictureAgoMs!!, 0.01)
    assertEquals(100.0, during.safetyNetAgoMs!!, 0.01)
    assertEquals(1L, during.safetyFlushes)
    stats.onShown(lastShown + 3_200 * ms, stamp(400), 400 * flight)
    val after = stats.numbers(lastShown + 3_200 * ms)
    assertEquals(1L, after.freezes)
    assertEquals(3_200.0, after.longestFreezeMs!!, 0.01)
    // Both trackers go to the export, whichever the counts come from (review m6)
    assertEquals("1", after.freezesAsked!!["count"].toString())
    assertEquals("0", after.freezesRendered!!["count"].toString())
    // A picture decoded while no view shows it keeps the age low, and the view going closes a freeze under way
    stats.onParked(lastShown + 3_300 * ms)
    assertEquals(0.0, stats.numbers(lastShown + 3_300 * ms).lastPictureAgoMs!!, 0.01)
    stats.onShown(lastShown + 3_400 * ms, stamp(401), 401 * flight)
    stats.closeView(lastShown + 4_000 * ms)
    assertEquals(2L, stats.numbers(lastShown + 4_000 * ms).freezes)
  }

  /** The delay now is the most of the last 2 s, so that a spike shows; the median stays over 10 s */
  @Test
  fun theDelayNowIsTheMostOfTheLastTwoSeconds() {
    val stats = SmoothingStats()
    for (index in 0 until 600) {
      val at = index * flight
      val stamp = RelayStamp(index.toLong(), 0, -1, at, at, at).also { it.sourceNs = at }
      // 200 ms behind the phone, but 1 s for a moment 9.5 s in
      val behind = if (index in 570 until 575) 1_000 * ms else 200 * ms
      stats.onShown(at, stamp, at - behind)
    }
    val numbers = stats.numbers(599 * flight)
    assertEquals(200.0, numbers.phoneToShownMedianMs!!, 0.01)
    assertEquals(1_000.0, numbers.phoneToShownNowMs!!, 0.01)
    assertEquals(200.0, stats.numbers(599 * flight + 2_500 * ms).let { it.phoneToShownMedianMs!! }, 0.01)
    assertNull(stats.numbers(599 * flight + 2_500 * ms).phoneToShownNowMs)
  }

  /**
   * What the delay lines say (review M1): measured when it can be, an estimate apart while the clocks are not aligned,
   * and no number while no picture was shown for half a second
   */
  @Test
  fun theDelayShownIsMeasuredOrAnEstimateApartOrNothingWhileThePictureStands() {
    val stats = SmoothingStats()
    val stamp = RelayStamp(1, 0, -1, 0, 0, 0).also { it.sourceNs = 0 }
    stats.onPlaced(JitterBuffer().place(0, 0, false, 0), flight, 0, 0)
    // Clocks not aligned yet: no phone time here, the estimate goes apart
    stats.onShown(250 * ms, stamp, null)
    val estimate = ShownDelay.of(stats.numbers(300 * ms), 40.0, 5.0, 12.0)
    assertEquals(ShownDelay(null, null, 57.0), estimate)
    // Measured
    stats.onShown(300 * ms, stamp, 0)
    assertEquals(ShownDelay(300.0, 300.0, null), ShownDelay.of(stats.numbers(400 * ms), 40.0, 5.0, 12.0))
    // Nothing shown for 0.6 s: no number at all
    assertEquals(ShownDelay.NONE, ShownDelay.of(stats.numbers(900 * ms), 40.0, 5.0, 12.0))
    // A reception not paced yet keeps the estimate
    assertEquals(ShownDelay(null, null, 57.0), ShownDelay.of(SmoothingStats().numbers(0), 40.0, 5.0, 12.0))
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
