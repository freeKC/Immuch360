package app.alextran.immich.djilink

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Durations over a whole session, for the medians, 95th percentiles and maxima of the exports and Diagnostics: one
 * bucket per [unitNs] up to 1024 of them, then one per 16 up to 10240, anything longer in the last bucket. The minimum
 * and the maximum are exact. Not thread safe: its owner holds the lock.
 */
class DurationHistogram(private val unitNs: Long = 1_000_000L) {
  companion object {
    private const val LINEAR = 1024
    private const val STEP = 16
    private const val COARSE = 576
  }

  private val counts = LongArray(LINEAR + COARSE)

  var count = 0L
    private set
  private var minNs = Long.MAX_VALUE
  private var maxNs = 0L

  fun add(ns: Long) {
    val value = ns.coerceAtLeast(0)
    val units = value / unitNs
    val bucket = if (units < LINEAR) {
      units.toInt()
    } else {
      (LINEAR + (units - LINEAR) / STEP).coerceAtMost((LINEAR + COARSE - 1).toLong()).toInt()
    }
    counts[bucket] += 1
    count += 1
    minNs = minOf(minNs, value)
    maxNs = maxOf(maxNs, value)
  }

  /** The value at [fraction] of the sorted values (the lower bound of its bucket, within the extremes); null if none */
  fun percentileMs(fraction: Double): Double? {
    if (count == 0L) {
      return null
    }
    val rank = ((count - 1) * fraction).toLong()
    var seen = 0L
    for (bucket in counts.indices) {
      seen += counts[bucket]
      if (seen > rank) {
        val units = if (bucket < LINEAR) bucket.toLong() else LINEAR + (bucket - LINEAR).toLong() * STEP
        return (units * unitNs).coerceIn(minNs, maxNs) / 1e6
      }
    }
    return maxNs / 1e6
  }

  val minMs: Double? get() = if (count == 0L) null else minNs / 1e6
  val maxMs: Double? get() = if (count == 0L) null else maxNs / 1e6

  fun reset() {
    counts.fill(0)
    count = 0
    minNs = Long.MAX_VALUE
    maxNs = 0
  }
}

/**
 * The adaptive jitter buffer of a receiver (p2/relay-smoothness-2026-10-25.md, 5.1 item 3). Each unit has a source
 * time: the stream's millisecond content clock, or the phone receive time when there is none. Its transit is its
 * arrival here minus its source time; the base is the least transit of the last [windowNs]; a unit's lateness is its
 * transit minus the base. The target is the 95th percentile of the lateness over the window plus one picture period,
 * kept between [floorNs] and [ceilingNs]; it rises at once when a unit comes later than the target and falls by at
 * most [fallNs] every [fallEveryNs]. A unit is shown at its source time plus the base, the target and the lead the
 * decoder needs, never before the unit before it.
 *
 * A BREAK, a step of the source back, or a step forward over [gapNs] (an encoder restart, a new loop of a capture)
 * starts the base again from the unit itself: that gap is not filled with waiting. Otherwise a new base (the least
 * transit left the window, or a lower one came) is taken by [slewNs] a unit at most, so that the display times never
 * jump by the difference. Pure, with the times given, so that it is unit tested; the decoder feed holds one per
 * reception.
 */
class JitterBuffer(
  private val floorNs: Long = TV_FLOOR_NS,
  private val ceilingNs: Long = TV_CEILING_NS,
  private val windowNs: Long = 10_000_000_000L,
  private val fallNs: Long = 10_000_000L,
  private val fallEveryNs: Long = 2_000_000_000L,
  private val gapNs: Long = 300_000_000L,
  private val slewNs: Long = 1_000_000L,
) {
  companion object {
    /** A TV is a spectator screen: it can afford up to 300 ms */
    const val TV_FLOOR_NS = 150_000_000L
    const val TV_CEILING_NS = 300_000_000L

    /** A headset's window and flight view are the pilot's view: a lower floor and ceiling */
    const val HEADSET_FLOOR_NS = 100_000_000L
    const val HEADSET_CEILING_NS = 250_000_000L

    /**
     * A headset set to the lowest delay in Options: no floor, so the target is the 95th percentile of the lateness and
     * one picture; it still rises at once when a unit comes late
     */
    const val LOWEST_FLOOR_NS = 0L
    const val DEFAULT_PERIOD_NS = 33_333_333L
    private const val PERCENTILE_EVERY_NS = 500_000_000L
    private const val STEPS_KEPT = 32
  }

  class Placement(
    val displayNs: Long,
    /** When the unit should go to the decoder: [displayNs] minus the lead given */
    val feedAtNs: Long,
    /** The unit came after its time to go to the decoder */
    val late: Boolean,
    /** The base started again from this unit */
    val reanchored: Boolean,
    /** A step of the source over the gap before this unit: the previous source time, or null */
    val gapFromNs: Long?,
    val targetNs: Long,
    /** How long the unit waits here: [displayNs] minus its arrival */
    val depthNs: Long,
  )

  private val transits = ArrayDeque<LongArray>()
  private val minimums = ArrayDeque<LongArray>()
  private val steps = ArrayDeque<Long>()
  private var lastSourceNs: Long? = null
  private var lastDisplayNs = Long.MIN_VALUE
  private var lastFallNs = 0L
  private var nextPercentileNs = Long.MIN_VALUE
  private var p95LatenessNs = 0L
  private var appliedBaseNs: Long? = null

  var targetNs: Long = floorNs
    private set

  /** The picture period measured on the source steps; 33.3 ms until measured */
  var periodNs: Long = DEFAULT_PERIOD_NS
    private set

  /** Times the base started again, after the first unit */
  var reanchors = 0L
    private set

  /** One unit that arrived at [arrivalNs] with [sourceNs]; [leadNs] is the time the decoder needs before the display */
  fun place(arrivalNs: Long, sourceNs: Long, breakBefore: Boolean, leadNs: Long = 0L): Placement {
    val previous = lastSourceNs
    val step = if (previous == null) null else sourceNs - previous
    val reanchor = step == null || breakBefore || step < 0 || step > gapNs
    if (reanchor) {
      transits.clear()
      minimums.clear()
      nextPercentileNs = Long.MIN_VALUE
      if (previous != null) {
        reanchors += 1
      }
    } else if (step in 1..200_000_000L) {
      steps.addLast(step)
      while (steps.size > STEPS_KEPT) {
        steps.removeFirst()
      }
      periodNs = steps.sorted()[steps.size / 2]
    }
    lastSourceNs = sourceNs
    val transit = arrivalNs - sourceNs
    transits.addLast(longArrayOf(arrivalNs, transit))
    while (arrivalNs - transits.first()[0] > windowNs) {
      transits.removeFirst()
    }
    while (minimums.isNotEmpty() && minimums.last()[1] >= transit) {
      minimums.removeLast()
    }
    minimums.addLast(longArrayOf(arrivalNs, transit))
    while (arrivalNs - minimums.first()[0] > windowNs) {
      minimums.removeFirst()
    }
    val base = minimums.first()[1]
    val lateness = transit - base
    val applied = appliedBaseNs
    val shownBase = if (reanchor || applied == null) base else applied + (base - applied).coerceIn(-slewNs, slewNs)
    appliedBaseNs = shownBase
    if (arrivalNs >= nextPercentileNs) {
      val sorted = transits.map { it[1] - base }.sorted()
      p95LatenessNs = sorted[((sorted.size - 1) * 0.95).toInt()]
      nextPercentileNs = arrivalNs + PERCENTILE_EVERY_NS
    }
    val wanted = (p95LatenessNs + periodNs).coerceIn(floorNs, ceilingNs)
    when {
      lateness > targetNs -> {
        // A unit later than the target: the target rises at once, and waits before it falls
        targetNs = (lateness + periodNs).coerceAtMost(ceilingNs)
        lastFallNs = arrivalNs
      }
      wanted > targetNs -> {
        targetNs = wanted
        lastFallNs = arrivalNs
      }
      wanted < targetNs && arrivalNs - lastFallNs >= fallEveryNs -> {
        targetNs = maxOf(wanted, targetNs - fallNs)
        lastFallNs = arrivalNs
      }
    }
    val display = maxOf(sourceNs + shownBase + targetNs + leadNs, lastDisplayNs)
    lastDisplayNs = display
    val feedAt = display - leadNs
    return Placement(
      displayNs = display,
      feedAtNs = feedAt,
      late = arrivalNs > feedAt,
      reanchored = reanchor,
      gapFromNs = if (step != null && step > gapNs) previous else null,
      targetNs = targetNs,
      depthNs = display - arrivalNs,
    )
  }

  fun reset() {
    transits.clear()
    minimums.clear()
    steps.clear()
    lastSourceNs = null
    lastDisplayNs = Long.MIN_VALUE
    lastFallNs = 0
    nextPercentileNs = Long.MIN_VALUE
    p95LatenessNs = 0
    appliedBaseNs = null
    targetNs = floorNs
    periodNs = DEFAULT_PERIOD_NS
    reanchors = 0
  }
}

/** The times of a paced display (p2/relay-smoothness-2026-10-25.md, 5.1 items 4 and 5) */
object PacedRender {
  /** Two refreshes at 60 Hz */
  const val RELEASE_LEAD_NS = 33_000_000L

  /** The time the decoder is given before the display while it has not been measured, and its bounds */
  const val DEFAULT_LEAD_NS = 50_000_000L
  const val MIN_LEAD_NS = 15_000_000L
  const val MAX_LEAD_NS = 200_000_000L

  /** No picture out of a decoder for this long while a unit waited in it is a stall */
  const val STALL_NS = 200_000_000L

  /** Late pictures go to the screen at least this often, whatever the picture period says */
  const val MAX_SPACING_NS = 50_000_000L

  /** The time the decoder needs before the display: the 95th percentile of the decode time and half a picture */
  fun lead(decodeP95Ns: Long?, periodNs: Long): Long =
    ((decodeP95Ns ?: (DEFAULT_LEAD_NS - periodNs / 2)) + periodNs / 2).coerceIn(MIN_LEAD_NS, MAX_LEAD_NS)
}

/**
 * Which decoded pictures of a paced reception go to the screen, and when (p2/relay-smoothness-2026-10-25.md, 5.1 item
 * 5, as p2/review-relay-2026-10-25.md B1 corrected it). Only pictures already out of the decoder count:
 *
 * 1. a picture more than two refreshes ahead of its display time is held until then, as the MediaCodec documentation
 *    advises; one within that goes to the surface with its own display time;
 * 2. a picture whose time has passed is released unseen only when the next decoded one is due too, never because of a
 *    unit still in the decoder or in the queue, so a decoder slower than the stream shows every picture it makes;
 * 3. late pictures go to the screen one picture period apart (50 ms at most): after a stall the newest decoded picture
 *    replaces those it overtook, and the screen gets a new picture at least that often while the decoder catches up.
 *
 * Pure, with the times given, so that it is unit tested with a decoder model; the decoder thread owns one.
 */
class PacedRelease<T : Any> {
  sealed class Step<T> {
    data class Skip<T>(val item: T) : Step<T>()

    data class Render<T>(val item: T, val atNs: Long) : Step<T>()
  }

  private class Entry<T>(val item: T, val displayNs: Long)

  private val held = ArrayDeque<Entry<T>>()
  private var lastRenderNs: Long? = null

  /** Decoded pictures not released yet */
  val size: Int get() = held.size

  /** A picture out of the decoder, to show at [displayNs] */
  fun add(item: T, displayNs: Long) {
    held.addLast(Entry(item, displayNs))
  }

  /**
   * What to do at [nowNs] with the pictures held, in decoding order, into [steps]; returns when to look again (a
   * picture early or waiting for its turn), null when none is held
   */
  fun release(nowNs: Long, periodNs: Long, steps: MutableList<Step<T>>): Long? {
    val spacing = periodNs.coerceIn(1L, PacedRender.MAX_SPACING_NS)
    while (held.isNotEmpty()) {
      val head = held.first()
      if (head.displayNs - nowNs > PacedRender.RELEASE_LEAD_NS) {
        return head.displayNs - PacedRender.RELEASE_LEAD_NS
      }
      if (head.displayNs >= nowNs) {
        held.removeFirst()
        steps += Step.Render(head.item, head.displayNs)
        lastRenderNs = maxOf(lastRenderNs ?: head.displayNs, head.displayNs)
        continue
      }
      val newer = held.getOrNull(1)
      if (newer != null && newer.displayNs <= nowNs) {
        // A newer picture is decoded and due: this one is overtaken
        held.removeFirst()
        steps += Step.Skip(head.item)
        continue
      }
      val turn = lastRenderNs?.let { it + spacing }
      if (turn != null && turn > nowNs) {
        return if (newer == null) turn else minOf(turn, newer.displayNs)
      }
      held.removeFirst()
      steps += Step.Render(head.item, nowNs)
      lastRenderNs = nowNs
    }
    return null
  }

  /** The pictures held, which the caller releases unseen; what was rendered before is forgotten */
  fun clear(): List<T> {
    val items = held.map { it.item }
    held.clear()
    lastRenderNs = null
    return items
  }
}

/**
 * Pictures that stayed on the screen longer than [freezeNs]: their count, the longest, their total, and how many came
 * with a gap in the stream itself (a source gap the phone saw too, such as an encoder restart), which a receiver cannot
 * fill. Not thread safe: its owner holds the lock.
 */
class FreezeTracker(private val freezeNs: Long = FREEZE_NS) {
  companion object {
    const val FREEZE_NS = 300_000_000L
  }

  var count = 0L
    private set
  var longestNs = 0L
    private set
  var totalNs = 0L
    private set
  var inSource = 0L
    private set
  private var lastNs: Long? = null
  private var lastSourceNs = Long.MIN_VALUE

  /** A picture shown at [atNs], of source time [sourceNs]; [gapInSource] says whether the source had a gap between */
  fun onShown(atNs: Long, sourceNs: Long, gapInSource: (Long, Long) -> Boolean) {
    val last = lastNs
    if (last != null && atNs - last > freezeNs) {
      val gap = atNs - last
      count += 1
      totalNs += gap
      longestNs = maxOf(longestNs, gap)
      if (lastSourceNs != Long.MIN_VALUE && gapInSource(lastSourceNs, sourceNs)) {
        inSource += 1
      }
    }
    lastNs = maxOf(atNs, last ?: atNs)
    lastSourceNs = sourceNs
  }

  /** Nothing is shown for a while on purpose (no view, a surface switch, a new source): no freeze is counted over it */
  fun pause() {
    lastNs = null
    lastSourceNs = Long.MIN_VALUE
  }

  /**
   * The picture stops being watched at [atNs] (the view went): a freeze already under way up to then is counted, then
   * nothing more until the next picture
   */
  fun close(atNs: Long) {
    val last = lastNs
    if (last != null && atNs - last > freezeNs) {
      val gap = atNs - last
      count += 1
      totalNs += gap
      longestNs = maxOf(longestNs, gap)
    }
    pause()
  }

  fun toJson(): JsonObject = buildJsonObject {
    put("count", count)
    put("longestMs", if (count == 0L) null else longestNs / 1e6)
    put("totalMs", if (count == 0L) null else totalNs / 1e6)
    put("inSource", inSource)
  }

  fun reset() {
    count = 0
    longestNs = 0
    totalNs = 0
    inSource = 0
    pause()
  }
}

/** What a paced reception measured, for Diagnostics, the reception record and the long pings */
data class SmoothingNumbers(
  val paced: Boolean,
  val units: Long,
  val lateUnits: Long,
  val shown: Long,
  val renderSkips: Long,
  val parked: Long,
  val decoderStalls: Long,
  val safetyFlushes: Long,
  val primersAfterBreak: Long,
  val reanchors: Long,
  val queueMax: Int,
  val heldMax: Int,
  val targetMs: Double?,
  val periodMs: Double?,
  val leadMs: Double?,
  val depthNowMs: Double?,
  val depthP95Ms: Double?,
  val depthMaxMs: Double?,
  val arrivalToShownMedianMs: Double?,
  val arrivalToShownP95Ms: Double?,
  val arrivalToShownMaxMs: Double?,
  /** Phone receive to picture shown, over the last 10 s, with the clock offset of the pings */
  val phoneToShownMedianMs: Double?,
  val phoneToShownP95Ms: Double?,
  /** The same over the whole session */
  val phoneToShownSessionMedianMs: Double?,
  val phoneToShownSessionP95Ms: Double?,
  val phoneToShownSessionMaxMs: Double?,
  /** Freezes over 300 ms from the render times the platform reported, or from the times asked when it reports none */
  val freezes: Long,
  val longestFreezeMs: Double?,
  val freezeTotalMs: Double?,
  val freezesInSource: Long,
  /** Whether the freezes come from the times the platform reported rendering at */
  val freezesFromRenderTimes: Boolean,
  val renderedReports: Long,
  /** Since the last picture released to be shown (or decoded with no view to show it); null before the first */
  val lastPictureAgoMs: Double? = null,
  /** Phone receive to picture shown, the most of the last 2 s: the delay now, spikes included */
  val phoneToShownNowMs: Double? = null,
  /** Since the safety net of the queue was last reached; null when never */
  val safetyNetAgoMs: Double? = null,
  /** The freezes from the times asked and from the render times, both, whichever the counts above come from */
  val freezesAsked: JsonObject? = null,
  val freezesRendered: JsonObject? = null,
) {
  fun toJson(): JsonObject = buildJsonObject {
    put("paced", paced)
    put("units", units)
    put("lateUnits", lateUnits)
    put("shown", shown)
    put("renderSkips", renderSkips)
    put("parked", parked)
    put("decoderStalls", decoderStalls)
    put("safetyFlushes", safetyFlushes)
    put("primersAfterBreak", primersAfterBreak)
    put("reanchors", reanchors)
    put("queueMax", queueMax)
    put("outputsHeldMax", heldMax)
    put("bufferTargetMs", targetMs)
    put("pictureMs", periodMs)
    put("decodeLeadMs", leadMs)
    put("bufferNowMs", depthNowMs)
    put("bufferP95Ms", depthP95Ms)
    put("bufferMaxMs", depthMaxMs)
    put("arrivalToShownMedianMs", arrivalToShownMedianMs)
    put("arrivalToShownP95Ms", arrivalToShownP95Ms)
    put("arrivalToShownMaxMs", arrivalToShownMaxMs)
    put("phoneToShownMedianMs", phoneToShownMedianMs)
    put("phoneToShownP95Ms", phoneToShownP95Ms)
    put("phoneToShownSessionMedianMs", phoneToShownSessionMedianMs)
    put("phoneToShownSessionP95Ms", phoneToShownSessionP95Ms)
    put("phoneToShownSessionMaxMs", phoneToShownSessionMaxMs)
    put("freezes", freezes)
    put("longestFreezeMs", longestFreezeMs)
    put("freezeTotalMs", freezeTotalMs)
    put("freezesInSource", freezesInSource)
    put("freezesFromRenderTimes", freezesFromRenderTimes)
    put("renderedReports", renderedReports)
    put("lastPictureAgoMs", lastPictureAgoMs)
    put("phoneToShownNowMs", phoneToShownNowMs)
    put("safetyNetAgoMs", safetyNetAgoMs)
    freezesAsked?.let { put("freezesAsked", it) }
    freezesRendered?.let { put("freezesRendered", it) }
  }

  /** The numbers of a long ping, -1 where unknown */
  fun pingNumbers(sequenceGaps: Long, roundTripNs: Long?): RelayPingNumbers = RelayPingNumbers(
    bufferTargetMs = targetMs?.toInt() ?: -1,
    bufferNowMs = depthNowMs?.toInt() ?: -1,
    freezes = freezes.toInt(),
    longestFreezeMs = longestFreezeMs?.toInt() ?: -1,
    renderSkips = renderSkips.toInt(),
    lateUnits = lateUnits.toInt(),
    decoderStalls = decoderStalls.toInt(),
    sequenceGaps = sequenceGaps.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
    primersUsed = primersAfterBreak.toInt(),
    roundTripUs = roundTripNs?.let { (it / 1_000).coerceIn(0, Int.MAX_VALUE.toLong()).toInt() } ?: -1,
    phoneToShownMs = phoneToShownMedianMs?.toInt() ?: -1,
    safetyFlushes = safetyFlushes.toInt(),
  )
}

/**
 * The counters of a paced reception, with their own lock: the reader thread places the units, the decoder thread
 * shows or skips them, the page and the pings read them.
 */
class SmoothingStats(private val windowNs: Long = 10_000_000_000L, private val nowWindowNs: Long = 2_000_000_000L) {
  private val lock = Any()
  private var paced = false
  private var units = 0L
  private var late = 0L
  private var shown = 0L
  private var skips = 0L
  private var parked = 0L
  private var stalls = 0L
  private var safety = 0L
  private var primers = 0L
  private var reanchors = 0L
  private var queueMax = 0
  private var heldMax = 0
  private var targetNs: Long? = null
  private var periodNs: Long? = null
  private var leadNs: Long? = null
  private var depthNs: Long? = null
  private val depth = DurationHistogram()
  private val arrivalToShown = DurationHistogram()
  private val phoneToShown = DurationHistogram()
  private val phoneWindow = ArrayDeque<LongArray>()
  private val asked = FreezeTracker()
  private val rendered = FreezeTracker()
  private var renderedReports = 0L
  private val sourceGaps = ArrayDeque<LongArray>()
  private var lastPictureNs: Long? = null
  private var lastNetNs: Long? = null

  fun onPlaced(placement: JitterBuffer.Placement, periodNs: Long, leadNs: Long, sourceNs: Long) = synchronized(lock) {
    paced = true
    units += 1
    if (placement.late) {
      late += 1
    }
    if (placement.reanchored && units > 1) {
      reanchors += 1
    }
    placement.gapFromNs?.let { from ->
      sourceGaps.addLast(longArrayOf(from, sourceNs))
      while (sourceGaps.size > 32) {
        sourceGaps.removeFirst()
      }
    }
    targetNs = placement.targetNs
    this.periodNs = periodNs
    this.leadNs = leadNs
    depthNs = placement.depthNs
    depth.add(placement.depthNs)
  }

  fun onQueued(size: Int) = synchronized(lock) { queueMax = maxOf(queueMax, size) }

  fun onHeld(count: Int) = synchronized(lock) { heldMax = maxOf(heldMax, count) }

  /** A picture released to be shown at [atNs]; [phoneReceiveHereNs] is its phone receive time on this clock if known */
  fun onShown(atNs: Long, stamp: RelayStamp, phoneReceiveHereNs: Long?) = synchronized(lock) {
    shown += 1
    lastPictureNs = maxOf(lastPictureNs ?: atNs, atNs)
    arrivalToShown.add(atNs - stamp.arrivalNs)
    if (phoneReceiveHereNs != null) {
      val value = atNs - phoneReceiveHereNs
      phoneToShown.add(value)
      phoneWindow.addLast(longArrayOf(atNs, value))
      while (phoneWindow.isNotEmpty() && (atNs - phoneWindow.first()[0] > windowNs || phoneWindow.size > 1024)) {
        phoneWindow.removeFirst()
      }
    }
    asked.onShown(atNs, stamp.sourceNsOrArrival(), ::gapBetween)
  }

  /** The platform says a picture of source time [sourceNs] was rendered at [atNs] */
  fun onRendered(atNs: Long, sourceNs: Long) = synchronized(lock) {
    renderedReports += 1
    rendered.onShown(atNs, sourceNs, ::gapBetween)
  }

  fun onSkip() = synchronized(lock) { skips += 1 }

  /** A picture decoded at [atNs] while no view shows it: not a freeze, and a picture all the same for its age */
  fun onParked(atNs: Long) = synchronized(lock) {
    parked += 1
    lastPictureNs = maxOf(lastPictureNs ?: atNs, atNs)
    asked.pause()
    rendered.pause()
  }

  /** A new source or a decoder chosen on the page: what comes next is not measured against what came before */
  fun pause() = synchronized(lock) {
    asked.pause()
    rendered.pause()
  }

  /** The view goes at [atNs]: a freeze under way until then counts, then nothing until the next picture */
  fun closeView(atNs: Long) = synchronized(lock) {
    asked.close(atNs)
    rendered.close(atNs)
  }

  fun onStall() = synchronized(lock) { stalls += 1 }

  /**
   * The safety net of the queue was reached at [atNs] and units went. The freeze under way is not cut: it goes on until
   * the next picture shown, and counts whole then.
   */
  fun onSafetyNet(atNs: Long) = synchronized(lock) {
    safety += 1
    lastNetNs = atNs
  }

  fun onPrimerAfterBreak() = synchronized(lock) { primers += 1 }

  fun reset() = synchronized(lock) {
    paced = false
    units = 0
    late = 0
    shown = 0
    skips = 0
    parked = 0
    stalls = 0
    safety = 0
    primers = 0
    reanchors = 0
    queueMax = 0
    heldMax = 0
    targetNs = null
    periodNs = null
    leadNs = null
    depthNs = null
    depth.reset()
    arrivalToShown.reset()
    phoneToShown.reset()
    phoneWindow.clear()
    asked.reset()
    rendered.reset()
    renderedReports = 0
    sourceGaps.clear()
    lastPictureNs = null
    lastNetNs = null
  }

  private fun gapBetween(fromNs: Long, toNs: Long): Boolean =
    sourceGaps.any { (it[0] >= fromNs && it[0] < toNs) || (it[1] > fromNs && it[1] <= toNs) }

  fun numbers(nowNs: Long): SmoothingNumbers = synchronized(lock) {
    while (phoneWindow.isNotEmpty() && nowNs - phoneWindow.first()[0] > windowNs) {
      phoneWindow.removeFirst()
    }
    val recent = phoneWindow.map { it[1] }.sorted()
    val lastSeconds = phoneWindow.filter { nowNs - it[0] <= nowWindowNs }.maxOfOrNull { it[1] }
    val fromRender = rendered.count > 0 || renderedReports > 30
    val freezes = if (fromRender) rendered else asked
    SmoothingNumbers(
      paced = paced,
      units = units,
      lateUnits = late,
      shown = shown,
      renderSkips = skips,
      parked = parked,
      decoderStalls = stalls,
      safetyFlushes = safety,
      primersAfterBreak = primers,
      reanchors = reanchors,
      queueMax = queueMax,
      heldMax = heldMax,
      targetMs = targetNs?.let { it / 1e6 },
      periodMs = periodNs?.let { it / 1e6 },
      leadMs = leadNs?.let { it / 1e6 },
      depthNowMs = depthNs?.let { it / 1e6 },
      depthP95Ms = depth.percentileMs(0.95),
      depthMaxMs = depth.maxMs,
      arrivalToShownMedianMs = arrivalToShown.percentileMs(0.5),
      arrivalToShownP95Ms = arrivalToShown.percentileMs(0.95),
      arrivalToShownMaxMs = arrivalToShown.maxMs,
      phoneToShownMedianMs = if (recent.isEmpty()) null else recent[(recent.size - 1) / 2] / 1e6,
      phoneToShownP95Ms = if (recent.isEmpty()) null else recent[((recent.size - 1) * 0.95).toInt()] / 1e6,
      phoneToShownSessionMedianMs = phoneToShown.percentileMs(0.5),
      phoneToShownSessionP95Ms = phoneToShown.percentileMs(0.95),
      phoneToShownSessionMaxMs = phoneToShown.maxMs,
      freezes = freezes.count,
      longestFreezeMs = if (freezes.count == 0L) null else freezes.longestNs / 1e6,
      freezeTotalMs = if (freezes.count == 0L) null else freezes.totalNs / 1e6,
      freezesInSource = freezes.inSource,
      freezesFromRenderTimes = fromRender,
      renderedReports = renderedReports,
      lastPictureAgoMs = lastPictureNs?.let { (nowNs - it).coerceAtLeast(0) / 1e6 },
      phoneToShownNowMs = lastSeconds?.let { it / 1e6 },
      safetyNetAgoMs = lastNetNs?.let { (nowNs - it).coerceAtLeast(0) / 1e6 },
      freezesAsked = asked.toJson(),
      freezesRendered = rendered.toJson(),
    )
  }
}

/** The time a stamp was paced on: its source time, or its arrival when it was never placed */
internal fun RelayStamp.sourceNsOrArrival(): Long = if (sourceNs != Long.MIN_VALUE) sourceNs else arrivalNs

/**
 * The times of every unit a receiver got, without its bytes, for the whole session (p2/relay-smoothness-2026-10-25.md,
 * 6.2 item 4): eight longs, 64 bytes, a unit; [capacity] units kept, the oldest overwritten. A line is added on arrival
 * and completed by the decoder thread when the unit goes to the decoder, comes out, and is shown or not.
 */
class UnitTimingRing(val capacity: Int = CAPACITY) {
  companion object {
    /** 18 minutes at 60 pictures a second, 36 at 30: 4 MiB */
    const val CAPACITY = 65_536
    const val SHOWN = 1
    const val SKIPPED = 2
    const val PARKED = 3

    /** What the unit was paced on: the phone receive time, the phone's content clock, this device's reading of it */
    const val SOURCE_PHONE_RECEIVE = 0
    const val SOURCE_PHONE_CLOCK = 1
    const val SOURCE_OWN_CLOCK = 2
    private const val NONE = Int.MIN_VALUE
    private const val WIDTH = 8
    const val CSV_HEADER =
      "sequence,flags,paced,result,bytes,clockMs,phoneReceiveUs,phoneSendUs,arrivalUs,displayUs,fedUs,outputUs," +
        "shownUs,renderedUs"

    private fun pack(high: Int, low: Int): Long = (high.toLong() shl 32) or (low.toLong() and 0xFFFF_FFFFL)

    private fun high(value: Long): Int = (value ushr 32).toInt()

    private fun low(value: Long): Int = value.toInt()

    /** Microseconds after [baseNs], NONE when [ns] is unknown, bounded to the range of an Int */
    private fun delta(ns: Long, baseNs: Long): Int = if (ns == Long.MIN_VALUE) {
      NONE
    } else {
      ((ns - baseNs) / 1_000).coerceIn(-Int.MAX_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
    }
  }

  private val slots = LongArray(capacity * WIDTH)
  private var added = 0L

  /** Units added since the start, whatever the ring still holds */
  val total: Long @Synchronized get() = added

  /** The line of a unit on arrival, paced on [source] with the clock [clockMs] (-1 for none); returns its index */
  @Synchronized
  fun add(stamp: RelayStamp, bytes: Int, source: Int, clockMs: Long): Long {
    val index = added
    added += 1
    val at = slot(index)
    slots[at] = pack((stamp.flags and 0xFF) or ((source and 0xFF) shl 8), (stamp.sequence and 0xFFFF_FFFFL).toInt())
    slots[at + 1] = pack(delta(stamp.displayNs, stamp.arrivalNs), bytes)
    slots[at + 2] = clockMs
    slots[at + 3] = pack(NONE, NONE)
    slots[at + 4] = stamp.phoneReceiveNs
    slots[at + 5] = pack(delta(stamp.phoneSendNs, stamp.phoneReceiveNs), 0)
    slots[at + 6] = stamp.arrivalNs
    slots[at + 7] = pack(NONE, NONE)
    return index
  }

  private fun slot(index: Long): Int = (index % capacity).toInt() * WIDTH

  private fun valid(index: Long): Boolean = index >= 0 && index < added && index >= added - capacity

  @Synchronized
  fun onFed(index: Long, ns: Long) {
    if (!valid(index)) return
    val at = slot(index)
    slots[at + 7] = pack(delta(ns, slots[at + 6]), low(slots[at + 7]))
  }

  @Synchronized
  fun onOutput(index: Long, ns: Long) {
    if (!valid(index)) return
    val at = slot(index)
    slots[at + 7] = pack(high(slots[at + 7]), delta(ns, slots[at + 6]))
  }

  /** The picture was released to be shown at [ns] ([SHOWN]), or not shown ([SKIPPED], [PARKED]) */
  @Synchronized
  fun onResult(index: Long, result: Int, ns: Long = Long.MIN_VALUE) {
    if (!valid(index)) return
    val at = slot(index)
    slots[at] = pack((high(slots[at]) and 0xFFFF) or ((result and 0xFF) shl 16), low(slots[at]))
    if (result == SHOWN) {
      slots[at + 3] = pack(delta(ns, slots[at + 6]), low(slots[at + 3]))
    }
  }

  /** The platform reported the picture rendered at [ns] */
  @Synchronized
  fun onRendered(index: Long, ns: Long) {
    if (!valid(index)) return
    val at = slot(index)
    slots[at + 3] = pack(high(slots[at + 3]), delta(ns, slots[at + 6]))
  }

  /** The bases of the CSV: the arrival and the phone receive time of the oldest line kept */
  @Synchronized
  fun bases(): Pair<Long, Long>? {
    if (added == 0L) return null
    val at = slot(maxOf(0, added - capacity))
    return slots[at + 6] to slots[at + 4]
  }

  /**
   * The lines kept, oldest first: the local times in microseconds after the arrival of the oldest line, the phone's
   * after its phone receive time ([bases]); empty fields where a time is unknown. The slots are copied under the lock
   * and the text is made outside it, so that the decoder thread never waits for an export.
   */
  fun csv(): String {
    val slots: LongArray
    val added: Long
    synchronized(this) {
      slots = this.slots.copyOf()
      added = this.added
    }
    val kept = minOf(added, capacity.toLong()).toInt()
    val out = StringBuilder(CSV_HEADER.length + 1 + kept * 96)
    out.append(CSV_HEADER).append('\n')
    if (added == 0L) {
      return out.toString()
    }
    val first = slot(maxOf(0, added - capacity))
    val localBase = slots[first + 6]
    val phoneBase = slots[first + 4]
    var index = maxOf(0, added - capacity)
    while (index < added) {
      val at = slot(index)
      val arrivalUs = (slots[at + 6] - localBase) / 1_000
      val phoneUs = (slots[at + 4] - phoneBase) / 1_000
      val head = high(slots[at])
      out.append(low(slots[at]).toLong() and 0xFFFF_FFFFL).append(',')
      out.append(head and 0xFF).append(',')
      out.append(
        when ((head ushr 8) and 0xFF) {
          SOURCE_PHONE_CLOCK -> "phoneClock"
          SOURCE_OWN_CLOCK -> "ownClock"
          else -> "phoneReceive"
        },
      ).append(',')
      out.append(
        when ((head ushr 16) and 0xFF) {
          SHOWN -> "shown"
          SKIPPED -> "skipped"
          PARKED -> "parked"
          else -> ""
        },
      ).append(',')
      out.append(low(slots[at + 1])).append(',')
      slots[at + 2].takeIf { it >= 0 }?.let { out.append(it) }
      out.append(',').append(phoneUs).append(',')
      append(out, phoneUs, high(slots[at + 5]))
      out.append(',').append(arrivalUs).append(',')
      append(out, arrivalUs, high(slots[at + 1]))
      out.append(',')
      append(out, arrivalUs, high(slots[at + 7]))
      out.append(',')
      append(out, arrivalUs, low(slots[at + 7]))
      out.append(',')
      append(out, arrivalUs, high(slots[at + 3]))
      out.append(',')
      append(out, arrivalUs, low(slots[at + 3]))
      out.append('\n')
      index += 1
    }
    return out.toString()
  }

  private fun append(out: StringBuilder, baseUs: Long, relative: Int) {
    if (relative != NONE) {
      out.append(baseUs + relative)
    }
  }
}

/**
 * The facts of a stream with their times, for the exports (p2/relay-smoothness-2026-10-25.md, 6.1): each key picture,
 * each encoder restart, and each change of the picture rate, read on the content clock (else on the arrivals). The
 * first [FIRST] events and the last ones up to [MAX_EVENTS] are kept. Under the page lock, as the pipeline is.
 */
class StreamFacts {
  companion object {
    const val MAX_EVENTS = 256
    const val FIRST = 64
    private const val STEPS = 15
  }

  data class Event(val atMs: Long, val kind: String, val value: Long)

  private val events = ArrayList<Event>()
  private var firstNs: Long? = null
  private var lastClock: Long? = null
  private var lastArrivalNs: Long? = null
  private val steps = ArrayDeque<Long>()
  private var rate = 0L
  var keyPictures = 0L
    private set
  var restarts = 0L
    private set

  /** A unit of the stream at [nowNs]; [restarted] when its picture counter said the encoder started again */
  fun onUnit(unit: AccessUnit, nowNs: Long, restarted: Boolean) {
    val first = firstNs ?: nowNs.also { firstNs = it }
    val atMs = (nowNs - first) / 1_000_000
    if (unit.isKey) {
      keyPictures += 1
      add(Event(atMs, "key", unit.size.toLong()))
    }
    if (restarted) {
      restarts += 1
      add(Event(atMs, "restart", unit.pictureCounter?.toLong() ?: -1))
    }
    val clock = unit.contentMs.takeIf { it >= 0 }
    val stepNs = when {
      clock != null && lastClock != null -> (clock - lastClock!!) * 1_000_000
      clock == null && lastArrivalNs != null -> nowNs - lastArrivalNs!!
      else -> null
    }
    lastClock = clock
    lastArrivalNs = nowNs
    if (stepNs != null && stepNs in 1..200_000_000L) {
      steps.addLast(stepNs)
      while (steps.size > STEPS) {
        steps.removeFirst()
      }
      if (steps.size == STEPS) {
        val median = steps.sorted()[STEPS / 2]
        val measured = Math.round(1e9 / median)
        if (rate == 0L || Math.abs(measured - rate) * 100 > rate * 15) {
          rate = measured
          add(Event(atMs, "rate", measured))
        }
      }
    }
  }

  /** A new source: the facts start again */
  fun reset() {
    events.clear()
    firstNs = null
    lastClock = null
    lastArrivalNs = null
    steps.clear()
    rate = 0
    keyPictures = 0
    restarts = 0
  }

  /** A new stream of the same source: the steps start again, the events stay */
  fun newStream() {
    lastClock = null
    lastArrivalNs = null
    steps.clear()
  }

  private fun add(event: Event) {
    events.add(event)
    if (events.size > MAX_EVENTS) {
      events.removeAt(FIRST)
    }
  }

  fun events(): List<Event> = events.toList()

  fun toJson(): JsonObject = buildJsonObject {
    put("keyPictures", keyPictures)
    put("encoderRestarts", restarts)
    put("picturesPerSecond", rate)
    put(
      "events",
      buildJsonArray {
        for (event in events) {
          add(buildJsonObject {
            put("atMs", event.atMs)
            put("event", event.kind)
            put("value", event.value)
          })
        }
      },
    )
  }
}
