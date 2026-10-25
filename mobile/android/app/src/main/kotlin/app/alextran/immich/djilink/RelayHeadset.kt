package app.alextran.immich.djilink

import java.io.IOException
import java.io.OutputStream
import java.net.Socket
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** A record taken from a headset's queue, ready to write: a unit carries its final flags and sequence */
class RelayOutgoing(
  val type: Int,
  val flags: Int,
  val body: ByteArray?,
  val unit: AccessUnit?,
  val sequence: Long,
  val enqueuedNs: Long,
  /** A key unit kept from earlier, sent ahead of the live ones ([RelayWire.UNIT_PRIMER]) */
  val primer: Boolean = false,
  /** The steady drop this key unit ends, for the wait from the drop to the key written; null otherwise */
  val afterDropNs: Long? = null,
)

/** A key unit kept by the phone, to send with BREAK after a drop that left no key unit in the queue */
class RelayPrimer(val unit: AccessUnit, val flags: Int)

/** What a receiver's queue counted since the receiver connected */
data class RelayQueueCounters(
  val dropEvents: Long,
  val unitsDropped: Long,
  /** Drops that went back to a key unit still queued: no damage */
  val cleanRestarts: Long,
  /** The kept key units sent after a drop, flagged KEY, PRIMER and BREAK (counted when written, not when queued) */
  val recoveryPrimers: Long,
  /** Drops that kept the fresh key unit at the head of the queue and took the units after it */
  val keyFirstDrops: Long = 0,
  val breaksOverload: Long,
  val breaksNewStream: Long,
  val maxRecords: Int,
  val maxUnitBytes: Long,
  val maxAgeNs: Long,
  /** Steady stream: drops (each then waits for a key unit made for it), and the units skipped while it waited */
  val steadyDrops: Long = 0,
  val unitsSkipped: Long = 0,
  /** Units of the steady stream offered to this queue */
  val steadyOffered: Long = 0,
  /** Units of the other stream that went at a switch, not counted as drops */
  val switchCleared: Long = 0,
  val breaksSwitch: Long = 0,
)

/**
 * The records waiting for one receiver (p2/design-stage2b.md, 4.8, with p2/relay-smoothness-2026-10-25.md, 5.2), with
 * their enqueue times.
 *
 * 1. Units are never dropped one by one: in a stream of P pictures with rare key pictures, one missing unit damages
 *    every following picture until the refresh repairs it.
 * 2. Only the newest TELEMETRY waits: a newer one replaces an older one still queued. A PONG goes ahead of everything.
 * 3. Overload: when the oldest queued unit is older than [maxAgeNs] (no more than once every [holdOffNs], unless the
 *    age passes twice the bound), or the units would hold more than [maxBytes], units are dropped and counted, the
 *    sequence skips them (so the receiver sees the gap), and the next unit goes out with BREAK:
 *    a. when a key unit newer than the oldest unit is queued (or comes now), everything before the newest one goes,
 *       and the stream starts again clean from it;
 *    b. when the newest key unit is the oldest queued (a stall right after an encoder start: the take off, the
 *       landing, the link start), it is the only picture this receiver can start from: the age may go to twice the
 *       bound whatever the hold off, then the units after it go and it stays, sent as a live unit; the unit after the
 *       gap carries BREAK (p2/review-relay-2026-10-25.md M3);
 *    c. otherwise every queued unit goes, and the key unit the phone kept ([RelayPrimer]) is sent first, flagged KEY,
 *       PRIMER and BREAK: a receiver whose decoder will not go on without a key picture starts from it, another one
 *       keeps predicting from its last picture.
 *
 * The producer (the reader thread of the cable, or the player) only takes the lock for a few microseconds; the writer
 * thread of the receiver waits on it. Pure, with the times given, so that it is unit tested.
 */
class RelayQueue(
  private val maxAgeNs: Long = MAX_AGE_NS,
  private val maxBytes: Long = MAX_BYTES,
  private val holdOffNs: Long = HOLD_OFF_NS,
) {
  companion object {
    /**
     * A headset (its window and the flight view): the pilot's eyes, so a backlog goes at the 500 ms of stage 2b, and
     * within the hold off at twice that (p2/review-relay-2026-10-25.md M4)
     */
    const val MAX_AGE_NS = 500_000_000L

    /** A TV: a spectator screen with up to 300 ms of jitter buffer behind it */
    const val TV_MAX_AGE_NS = 1_500_000_000L

    /** Twice the age bound of a TV at the 18.4 Mbit/s of a flight, so that the age decides */
    const val MAX_BYTES = 8L * 1024 * 1024

    /** After a drop, none for this long unless the age passes twice the bound */
    const val HOLD_OFF_NS = 2_000_000_000L

    /** The age bound of a receiver that says it is [kind] in its hello */
    fun maxAgeFor(kind: String?): Long = if (kind == "tv") TV_MAX_AGE_NS else MAX_AGE_NS

    /**
     * The age bound of the steady stream (p2/relay-bandwidth-2026-10-25.md, 7.5 item 2): its drop costs a freeze of at
     * most this plus a key picture made for it, so it is short
     */
    const val STEADY_TV_MAX_AGE_NS = 500_000_000L
    const val STEADY_HEADSET_MAX_AGE_NS = 250_000_000L

    fun steadyMaxAgeFor(kind: String?): Long = if (kind == "tv") STEADY_TV_MAX_AGE_NS else STEADY_HEADSET_MAX_AGE_NS
  }

  /** What a unit of the steady stream became */
  class SteadyOffer(
    /** It was queued */
    val queued: Boolean,
    /** The queue dropped its units: a key picture is needed */
    val dropped: Boolean,
  )

  private class Queued(
    val type: Int,
    val flags: Int,
    val body: ByteArray?,
    val unit: AccessUnit?,
    val breakBefore: Boolean,
    val enqueuedNs: Long,
    val primer: Boolean = false,
    /** A kept key unit queued by a drop (rule 3c), counted when written */
    val recovery: Boolean = false,
    /** The key unit that ends a steady drop, and when that drop was */
    val afterDropNs: Long? = null,
  )

  private val lock = Object()
  private val records = ArrayDeque<Queued>()
  private var unitBytes = 0L
  private var nextSequence = 0L
  private var skip = 0L
  private var pendingBreak = false
  private var finishing = false
  private var closed = false
  private var dropped = 0L
  private var overloads = 0L
  private var cleanRestarts = 0L
  private var recoveryPrimers = 0L
  private var keyFirstDrops = 0L

  /** The key unit rule 3b kept at the head, and the units dropped after it: the gap goes after it in the sequence */
  private var keptHead: Queued? = null
  private var skipAfterHead = 0L
  private var breaksOverload = 0L
  private var breaksNewStream = 0L
  private var lastDropNs: Long? = null
  private var maxRecords = 0
  private var maxUnitBytes = 0L
  private var maxAge = 0L
  private var maxAgeSinceSample = 0L

  // The steady stream (p2/relay-bandwidth-2026-10-25.md, 7.5)
  private var steady = false
  private var steadyMaxAgeNs = STEADY_TV_MAX_AGE_NS
  private var waitingForKey = false
  private var steadyDropNs: Long? = null
  private var steadyDrops = 0L
  private var unitsSkipped = 0L
  private var steadyOffered = 0L
  private var switchCleared = 0L
  private var pendingBreakSwitch = false
  private var breaksSwitch = 0L

  /** The queue holds the steady stream */
  val isSteady: Boolean get() = synchronized(lock) { steady }

  /** The steady stream waits for a key unit: after a drop, a switch or a join */
  val waitsForKey: Boolean get() = synchronized(lock) { waitingForKey }

  /** Units dropped for this receiver since it connected */
  val unitsDropped: Long get() = synchronized(lock) { dropped }

  /** Times units were dropped */
  val overloadCount: Long get() = synchronized(lock) { overloads }

  val size: Int get() = synchronized(lock) { records.size }

  val queuedUnitBytes: Long get() = synchronized(lock) { unitBytes }

  /** Closed, or finished and empty: the writer has nothing more to do */
  val done: Boolean get() = synchronized(lock) { closed || (finishing && records.isEmpty()) }

  fun counters(): RelayQueueCounters = synchronized(lock) {
    RelayQueueCounters(
      dropEvents = overloads,
      unitsDropped = dropped,
      cleanRestarts = cleanRestarts,
      recoveryPrimers = recoveryPrimers,
      keyFirstDrops = keyFirstDrops,
      breaksOverload = breaksOverload,
      breaksNewStream = breaksNewStream,
      maxRecords = maxRecords,
      maxUnitBytes = maxUnitBytes,
      maxAgeNs = maxAge,
      steadyDrops = steadyDrops,
      unitsSkipped = unitsSkipped,
      steadyOffered = steadyOffered,
      switchCleared = switchCleared,
      breaksSwitch = breaksSwitch,
    )
  }

  /** The oldest age a unit reached in the queue since the last call, for the timeline of each second */
  fun takeMaxAgeSinceSample(): Long = synchronized(lock) { maxAgeSinceSample.also { maxAgeSinceSample = 0 } }

  /**
   * A unit with its own flags (key, in band, replay, primer); [breakBefore] when it does not continue the previous one.
   * [primer] gives the kept key unit when a drop leaves no key unit to start from; it is called under the lock.
   */
  fun offerUnit(
    unit: AccessUnit,
    flags: Int,
    breakBefore: Boolean,
    nowNs: Long,
    primer: (() -> RelayPrimer?)? = null,
  ): Boolean = synchronized(lock) {
    if (closed || finishing) {
      return false
    }
    records.firstOrNull { it.unit != null }?.let { first ->
      val age = nowNs - first.enqueuedNs
      maxAge = maxOf(maxAge, age)
      maxAgeSinceSample = maxOf(maxAgeSinceSample, age)
    }
    // The key unit kept at the head by an earlier drop is not aged again: the units after it are
    val oldest = records.firstOrNull { it.unit != null && it !== keptHead }
    if (oldest != null) {
      val age = nowNs - oldest.enqueuedNs
      val held = lastDropNs?.let { nowNs - it < holdOffNs } ?: false
      // A fresh key unit at the head, the newest queued, waits up to twice the bound: dropping it would leave no
      // picture to start from (a newer key unit queued or coming makes a clean restart instead)
      val keyFirst = !unit.isKey && records.lastOrNull { it.unit?.isKey == true && !it.primer } === oldest
      val overAge = age > maxAgeNs && (!(held || keyFirst) || age > 2 * maxAgeNs)
      if (overAge || unitBytes + unit.size > maxBytes) {
        drop(unit, nowNs, primer)
      }
    }
    val isPrimer = (flags and RelayWire.UNIT_PRIMER) != 0
    records.addLast(Queued(RelayWire.UNIT, flags, null, unit, breakBefore, nowNs, primer = isPrimer))
    unitBytes += unit.size
    maxRecords = maxOf(maxRecords, records.size)
    maxUnitBytes = maxOf(maxUnitBytes, unitBytes)
    lock.notifyAll()
    true
  }

  /** Telemetry: only the newest waits */
  fun offerTelemetry(body: ByteArray, nowNs: Long): Boolean = synchronized(lock) {
    if (closed || finishing) {
      return false
    }
    records.removeAll { it.type == RelayWire.TELEMETRY }
    records.addLast(Queued(RelayWire.TELEMETRY, 0, body, null, false, nowNs))
    lock.notifyAll()
    true
  }

  /** A pong goes ahead of everything, behind the pongs already waiting */
  fun offerPong(body: ByteArray, nowNs: Long): Boolean = synchronized(lock) {
    if (closed || finishing) {
      return false
    }
    val at = records.indexOfFirst { it.type != RelayWire.PONG }.let { if (it < 0) records.size else it }
    records.add(at, Queued(RelayWire.PONG, 0, body, null, false, nowNs))
    lock.notifyAll()
    true
  }

  /** Parameter sets and resets: in order with the units */
  fun offerRecord(type: Int, flags: Int, body: ByteArray, nowNs: Long): Boolean = synchronized(lock) {
    if (closed || finishing) {
      return false
    }
    records.addLast(Queued(type, flags, body, null, false, nowNs))
    lock.notifyAll()
    true
  }

  /**
   * A new source: the units and parameter sets still waiting belong to the old one and go, without counting them as
   * drops and without a gap in the sequence (the receiver's decoder starts again anyway)
   */
  fun clearForReset() = synchronized(lock) {
    records.removeAll { it.type == RelayWire.UNIT || it.type == RelayWire.PARAMETERS }
    unitBytes = 0
    pendingBreak = false
    pendingBreakSwitch = false
    keptHead = null
    skipAfterHead = 0
    // The steady stream starts again from a key picture of the new source
    waitingForKey = steady
    steadyDropNs = null
  }

  /** The last record: everything else is dropped, nothing more is taken, the writer ends after writing it */
  fun finish(type: Int, body: ByteArray, nowNs: Long) = synchronized(lock) {
    if (closed || finishing) {
      return
    }
    records.clear()
    unitBytes = 0
    keptHead = null
    records.addLast(Queued(type, 0, body, null, false, nowNs))
    finishing = true
    lock.notifyAll()
  }

  fun close() = synchronized(lock) {
    closed = true
    records.clear()
    unitBytes = 0
    lock.notifyAll()
  }

  /** The age of the oldest unit waiting, null when none waits */
  fun oldestUnitAgeNs(nowNs: Long): Long? = synchronized(lock) {
    records.firstOrNull { it.unit != null }?.let { nowNs - it.enqueuedNs }
  }

  /** The next record to write, waiting up to [timeoutMs]; null on a timeout or once [done] */
  fun take(timeoutMs: Long): RelayOutgoing? = synchronized(lock) {
    val deadline = System.nanoTime() + timeoutMs * 1_000_000
    while (records.isEmpty() && !closed) {
      val left = (deadline - System.nanoTime()) / 1_000_000
      if (left <= 0 || finishing) {
        return null
      }
      try {
        lock.wait(left)
      } catch (_: InterruptedException) {
        return null
      }
    }
    if (closed) {
      return null
    }
    val record = records.removeFirst()
    val unit = record.unit
    if (unit == null) {
      return RelayOutgoing(record.type, record.flags, record.body, null, -1, record.enqueuedNs)
    }
    unitBytes -= unit.size
    var flags = record.flags
    if (!record.primer && (record.breakBefore || pendingBreak || pendingBreakSwitch)) {
      flags = flags or RelayWire.UNIT_BREAK
      when {
        pendingBreak -> breaksOverload += 1
        pendingBreakSwitch -> breaksSwitch += 1
        else -> breaksNewStream += 1
      }
      pendingBreak = false
      pendingBreakSwitch = false
    }
    val sequence = nextSequence + skip
    nextSequence = sequence + 1
    skip = 0
    if (record.recovery) {
      recoveryPrimers += 1
    }
    if (record === keptHead) {
      // Rule 3b: the units dropped after the key unit show as a gap after it, and the next unit breaks
      keptHead = null
      skip = skipAfterHead
      skipAfterHead = 0
      pendingBreak = true
    }
    RelayOutgoing(
      RelayWire.UNIT,
      flags,
      null,
      unit,
      sequence,
      record.enqueuedNs,
      primer = record.primer,
      afterDropNs = record.afterDropNs,
    )
  }

  /**
   * The receiver changes stream (p2/relay-bandwidth-2026-10-25.md, 7.5 item 3): the units and parameter sets still
   * queued belong to the other stream and go, counted as a switch and not as drops, with no gap in the sequence. To the
   * steady stream ([toSteady]), nothing more goes until a key unit of it; [breakNext] puts BREAK on the next unit that
   * is not a primer (a receiver that had units before). Returns the units cleared.
   */
  fun switchStream(toSteady: Boolean, steadyMaxAgeNs: Long = this.steadyMaxAgeNs, breakNext: Boolean): Int =
    synchronized(lock) {
      var cleared = 0
      val iterator = records.iterator()
      while (iterator.hasNext()) {
        val record = iterator.next()
        val unit = record.unit
        if (unit != null) {
          if (!record.primer) {
            cleared += 1
          }
          unitBytes -= unit.size
          iterator.remove()
        } else if (record.type == RelayWire.PARAMETERS) {
          iterator.remove()
        }
      }
      keptHead = null
      skipAfterHead = 0
      pendingBreak = false
      pendingBreakSwitch = breakNext
      steady = toSteady
      this.steadyMaxAgeNs = steadyMaxAgeNs
      waitingForKey = toSteady
      steadyDropNs = null
      switchCleared += cleared
      cleared
    }

  /**
   * A unit of the steady stream (p2/relay-bandwidth-2026-10-25.md, 7.5 item 2), with the PARAMETERS body to send before
   * it when it needs one. When the oldest queued unit is older than the steady bound, every queued unit goes (counted,
   * the sequence skips them), and units are skipped until a key unit comes: that one goes with BREAK and its parameter
   * sets. No primer, no hold off: the phone makes the key picture.
   */
  fun offerSteadyUnit(
    unit: AccessUnit,
    flags: Int,
    parameters: ByteArray?,
    parametersFlags: Int,
    nowNs: Long,
  ): SteadyOffer = synchronized(lock) {
    if (closed || finishing || !steady) {
      return SteadyOffer(queued = false, dropped = false)
    }
    steadyOffered += 1
    val dropped = steadyAgeDrop(nowNs)
    if (waitingForKey && !unit.isKey) {
      unitsSkipped += 1
      skip += 1
      return SteadyOffer(queued = false, dropped = dropped)
    }
    var afterDrop: Long? = null
    if (waitingForKey) {
      waitingForKey = false
      afterDrop = steadyDropNs
      steadyDropNs = null
    }
    if (parameters != null) {
      records.addLast(Queued(RelayWire.PARAMETERS, parametersFlags, parameters, null, false, nowNs))
    }
    records.addLast(Queued(RelayWire.UNIT, flags, null, unit, false, nowNs, afterDropNs = afterDrop))
    unitBytes += unit.size
    maxRecords = maxOf(maxRecords, records.size)
    maxUnitBytes = maxOf(maxUnitBytes, unitBytes)
    lock.notifyAll()
    SteadyOffer(queued = true, dropped = dropped)
  }

  /** The steady bound checked on the tick too, when no unit comes to check it; true when it dropped */
  fun checkSteadyAge(nowNs: Long): Boolean = synchronized(lock) {
    if (closed || finishing || !steady) false else steadyAgeDrop(nowNs)
  }

  /** Under the lock: the steady drop when the oldest unit passed the bound */
  private fun steadyAgeDrop(nowNs: Long): Boolean {
    val oldest = records.firstOrNull { it.unit != null } ?: return false
    val age = nowNs - oldest.enqueuedNs
    maxAge = maxOf(maxAge, age)
    maxAgeSinceSample = maxOf(maxAgeSinceSample, age)
    if (age <= steadyMaxAgeNs && unitBytes <= maxBytes) {
      return false
    }
    var count = 0
    val iterator = records.iterator()
    while (iterator.hasNext()) {
      val record = iterator.next()
      val unit = record.unit
      if (unit != null) {
        count += 1
        unitBytes -= unit.size
        iterator.remove()
      } else if (record.type == RelayWire.PARAMETERS) {
        iterator.remove()
      }
    }
    dropped += count
    skip += count
    steadyDrops += 1
    lastDropNs = nowNs
    pendingBreak = true
    waitingForKey = true
    steadyDropNs = nowNs
    return true
  }

  /** Rule 3, under the lock, before [incoming] is queued */
  private fun drop(incoming: AccessUnit, nowNs: Long, primer: (() -> RelayPrimer?)?) {
    val keyAt = if (incoming.isKey) records.size else records.indexOfLast { it.unit?.isKey == true && !it.primer }
    val firstUnit = records.indexOfFirst { it.unit != null }
    // Rule 3a: back to the newest key unit, with the parameter sets queued last before it
    val restart = keyAt > firstUnit
    // Rule 3b: the newest key unit is the oldest queued; it stays, the units after it go
    val keyFirst = !restart && keyAt >= 0 && keyAt == firstUnit
    val keepParameters = if (restart) {
      (keyAt - 1 downTo 0).firstOrNull { records[it].type == RelayWire.PARAMETERS }
    } else {
      null
    }
    var count = 0
    var index = 0
    val iterator = records.iterator()
    while (iterator.hasNext()) {
      val record = iterator.next()
      val goes = when {
        restart -> index < keyAt
        keyFirst -> index > keyAt
        else -> true
      }
      if (goes && record.unit != null) {
        if (record.breakBefore && !keyFirst) {
          // The break it carried goes to the next unit with the drop's own
          pendingBreak = true
        }
        if (!record.primer) {
          count += 1
        }
        if (record === keptHead) {
          // A key unit kept by an earlier drop goes now: the gap after it goes before the unit that restarts
          skip += skipAfterHead
          skipAfterHead = 0
          keptHead = null
        }
        unitBytes -= record.unit.size
        iterator.remove()
      } else if (keepParameters != null && index < keyAt && record.type == RelayWire.PARAMETERS &&
        index != keepParameters
      ) {
        // Older parameter sets, for units that went
        iterator.remove()
      }
      index += 1
    }
    lastDropNs = nowNs
    overloads += 1
    dropped += count
    if (keyFirst) {
      // The gap goes after the key unit, which this receiver never had: it goes as a live unit, not as a primer
      keyFirstDrops += 1
      keptHead = records[keyAt]
      skipAfterHead += count
      return
    }
    skip += count
    pendingBreak = true
    if (restart) {
      cleanRestarts += 1
      return
    }
    // Rule 3c: the kept key unit first, flagged by the server with KEY, PRIMER and BREAK
    primer?.invoke()?.let { kept ->
      records.addLast(Queued(RelayWire.UNIT, kept.flags, null, kept.unit, false, nowNs, primer = true, recovery = true))
      unitBytes += kept.unit.size
    }
  }
}

/** A receiver's change of stream: when, from what, to what and why */
data class RelaySwitch(val atNs: Long, val from: RelayStream, val to: RelayStream, val why: RelaySwitchWhy)

/** What the phone got of a receiver's socket: the send buffer the kernel granted, and the unsent bytes bound if set */
data class RelaySocketFacts(
  val sendBufferBytes: Int?,
  val notSentLowWaterBytes: Int?,
)

/**
 * What the phone measured for one receiver (p2/relay-smoothness-2026-10-25.md, 6.1): what it sent, how long each unit
 * waited and took to write, what the receiver's long pings said, and a line for every second of the session. With its
 * own lock: the writer thread, the reader of the pings, the tick and the page each touch it.
 */
class RelayReceiverStats(private val connectedAtNs: Long) {
  companion object {
    /** Two hours of seconds */
    const val TIMELINE_SECONDS = 7_200
    const val TIMELINE_HEADER = "second,units,kB,oldestMs,dropped,roundTripMs,freezes,shownPer10s,stream,bitrateKbps"
    private const val COLUMNS = 10
  }

  private val lock = Any()
  private var units = 0L
  private var bytes = 0L
  private var primers = 0L
  private val records = sortedMapOf<Int, Long>()
  private val writes = DurationHistogram(100_000L)
  private val ages = DurationHistogram()
  private var stalls50 = 0L
  private var stalls200 = 0L
  private var stalls1000 = 0L
  private var pings = 0L
  private var longPings = 0L
  private var numbers: RelayPingNumbers? = null
  private val roundTrips = DurationHistogram(100_000L)
  private var lastRoundTripNs: Long? = null
  private val timeline = IntArray(TIMELINE_SECONDS * COLUMNS)
  private var seconds = 0L
  private var unitsAtSample = 0L
  private var bytesAtSample = 0L
  private var droppedAtSample = 0L
  private var bytesSecondMax = 0L
  private var longestWriteSinceTake = 0L
  private val keyWaits = DurationHistogram()
  private var network: RelayPingNetwork? = null

  /** A record written at [startNs], [bytes] long, that took [writeNs] with its flush and waited [ageNs] in the queue */
  fun onWritten(next: RelayOutgoing, bytes: Int, writeNs: Long, ageNs: Long): Unit = synchronized(lock) {
    this.bytes += bytes
    records[next.type] = (records[next.type] ?: 0L) + 1
    if (next.unit == null) {
      return
    }
    units += 1
    if (next.primer) {
      primers += 1
    }
    writes.add(writeNs)
    ages.add(ageNs)
    longestWriteSinceTake = maxOf(longestWriteSinceTake, writeNs)
    if (writeNs > 50_000_000L) stalls50 += 1
    if (writeNs > 200_000_000L) stalls200 += 1
    if (writeNs > 1_000_000_000L) stalls1000 += 1
  }

  fun onPing(ping: RelayPing): Unit = synchronized(lock) {
    pings += 1
    ping.network?.let { network = it }
    val said = ping.numbers ?: return
    longPings += 1
    numbers = said
    if (said.roundTripUs >= 0) {
      val ns = said.roundTripUs * 1_000L
      roundTrips.add(ns)
      lastRoundTripNs = ns
    }
  }

  /** The longest write of a unit since the last call, for the rate of the steady stream */
  fun takeLongestWrite(): Long = synchronized(lock) { longestWriteSinceTake.also { longestWriteSinceTake = 0 } }

  /** From a steady drop to the key unit that ends it, written */
  fun onKeyAfterDrop(waitNs: Long) = synchronized(lock) { keyWaits.add(waitNs) }

  /** The receiver's own network, from its 96 byte pings */
  val receiverNetwork: RelayPingNetwork? get() = synchronized(lock) { network }

  /**
   * The best second its socket carried in the last [lastSeconds] seconds of the timeline, in bits; with [steadyOnly],
   * only the seconds it was on the steady stream
   */
  fun bestSecondBits(lastSeconds: Int = 120, steadyOnly: Boolean = false): Long = synchronized(lock) {
    var best = 0L
    val first = maxOf(0L, seconds - minOf(lastSeconds, TIMELINE_SECONDS))
    for (index in first until seconds) {
      val at = ((index % TIMELINE_SECONDS) * COLUMNS).toInt()
      if (steadyOnly && timeline[at + 8] != 1) {
        continue
      }
      best = maxOf(best, timeline[at + 2] * 1024L * 8)
    }
    best
  }

  /** The receiver's last long ping, null when it sends short ones */
  val receiverNumbers: RelayPingNumbers? get() = synchronized(lock) { numbers }

  val unitsSent: Long get() = synchronized(lock) { units }

  /**
   * One second of the timeline, at [nowNs], with the queue's counters and the oldest age of that second, the stream it
   * was on (0 full, 1 steady) and its allowed rate on the steady stream (-1 on the full one)
   */
  fun sample(
    nowNs: Long,
    unitsDropped: Long,
    oldestNs: Long,
    shownPer10s: Int,
    stream: Int = 0,
    bitrateKbps: Int = -1,
  ) = synchronized(lock) {
    val at = ((seconds % TIMELINE_SECONDS) * COLUMNS).toInt()
    val second = bytes - bytesAtSample
    bytesSecondMax = maxOf(bytesSecondMax, second)
    timeline[at] = ((nowNs - connectedAtNs) / 1_000_000_000L).toInt()
    timeline[at + 1] = (units - unitsAtSample).toInt()
    timeline[at + 2] = (second / 1024).toInt()
    timeline[at + 3] = (oldestNs / 1_000_000).toInt()
    timeline[at + 4] = (unitsDropped - droppedAtSample).toInt()
    timeline[at + 5] = lastRoundTripNs?.let { (it / 1_000_000).toInt() } ?: -1
    timeline[at + 6] = numbers?.freezes ?: -1
    timeline[at + 7] = shownPer10s
    timeline[at + 8] = stream
    timeline[at + 9] = bitrateKbps
    seconds += 1
    unitsAtSample = units
    bytesAtSample = bytes
    droppedAtSample = unitsDropped
  }

  /** Write time per unit, 95th percentile, in milliseconds */
  val writeP95Ms: Double? get() = synchronized(lock) { writes.percentileMs(0.95) }

  val writeStalls200: Long get() = synchronized(lock) { stalls200 }

  val lastRoundTripMs: Double? get() = synchronized(lock) { lastRoundTripNs?.let { it / 1e6 } }

  /** The lines of the timeline kept, oldest first */
  fun timelineLines(): List<String> = synchronized(lock) {
    val first = maxOf(0L, seconds - TIMELINE_SECONDS)
    (first until seconds).map { index ->
      val at = ((index % TIMELINE_SECONDS) * COLUMNS).toInt()
      (0 until COLUMNS).joinToString(",") { timeline[at + it].toString() }
    }
  }

  fun toJson(nowNs: Long): JsonObject = synchronized(lock) {
    val spanNs = (nowNs - connectedAtNs).coerceAtLeast(1)
    buildJsonObject {
      put("unitsSent", units)
      put("bytesSent", bytes)
      put("primersSent", primers)
      put(
        "recordsSent",
        buildJsonObject { records.forEach { (type, count) -> put(RelayWire.typeName(type), count) } },
      )
      put("megabitsPerSecondMean", bytes * 8.0 / 1e6 / (spanNs / 1e9))
      put("megabitsPerSecondMax1s", bytesSecondMax * 8.0 / 1e6)
      put("queueAgeMedianMs", ages.percentileMs(0.5))
      put("queueAgeP95Ms", ages.percentileMs(0.95))
      put("queueAgeMaxMs", ages.maxMs)
      put("writeMedianMs", writes.percentileMs(0.5))
      put("writeP95Ms", writes.percentileMs(0.95))
      put("writeMaxMs", writes.maxMs)
      put("writeStallsOver50Ms", stalls50)
      put("writeStallsOver200Ms", stalls200)
      put("writeStallsOver1s", stalls1000)
      put("pings", pings)
      put("longPings", longPings)
      put("roundTripMinMs", roundTrips.minMs)
      put("roundTripMedianMs", roundTrips.percentileMs(0.5))
      put("roundTripMaxMs", roundTrips.maxMs)
      put("keyWaitMedianMs", keyWaits.percentileMs(0.5))
      put("keyWaitMaxMs", keyWaits.maxMs)
      put(
        "receiverNetwork",
        network?.let { said ->
          buildJsonObject {
            put("transport", RelayPingNetwork.transportName(said.transport))
            put("band", said.band)
            put("frequencyMhz", said.frequencyMhz.takeIf { it > 0 })
            put("linkMbps", said.linkMbps.takeIf { it > 0 })
            put("rssiDbm", said.rssiDbm.takeIf { it in -126..-1 })
            put("bytesLastSecond", said.bytesLastSecond.takeIf { it >= 0 })
            put("longestReadGapMs", said.longestReadGapMs.takeIf { it >= 0 })
          }
        } ?: JsonNull,
      )
      put(
        "receiverSays",
        numbers?.let { said ->
          buildJsonObject {
            put("bufferTargetMs", said.bufferTargetMs)
            put("bufferNowMs", said.bufferNowMs)
            put("freezes", said.freezes)
            put("longestFreezeMs", said.longestFreezeMs)
            put("renderSkips", said.renderSkips)
            put("lateUnits", said.lateUnits)
            put("decoderStalls", said.decoderStalls)
            put("sequenceGaps", said.sequenceGaps)
            put("primersUsed", said.primersUsed)
            put("roundTripUs", said.roundTripUs)
            put("phoneToShownMs", said.phoneToShownMs)
            put("safetyFlushes", said.safetyFlushes)
          }
        } ?: JsonNull,
      )
    }
  }
}

/**
 * One receiver (a headset or a TV) on the phone side: its socket, its queue, the writer thread "DjiRelayOut-n", and
 * what its pings say. The reader side (the hello, then its pings) runs on the server's thread of that connection. The
 * writer stamps each unit with the moment it starts writing it, and each pong with the moment it is written; a write
 * that makes no progress for 3 s, or no ping for 5 s, closes the receiver ([RelayServer.tick]).
 */
class RelayHeadset internal constructor(
  val number: Int,
  private val socket: Socket,
  private val output: OutputStream,
  val address: String,
  val name: String?,
  val app: String?,
  private val clockNs: () -> Long,
  private val onClosed: (RelayHeadset, String) -> Unit,
  val queue: RelayQueue = RelayQueue(),
  /** The id of the screen code a TV proved; null for the phone's own code */
  val screenCodeId: String? = null,
  /** What its hello says it is ("tv"), null when it says nothing */
  val kind: String? = null,
  /** The unit header it reads: [RelayWire.UNIT_HEADER_LONG_BYTES] when its hello says so */
  val unitHeaderBytes: Int = RelayWire.UNIT_HEADER_BYTES,
  val socketFacts: RelaySocketFacts = RelaySocketFacts(null, null),
  /** The age of the oldest unit at which its queue drops ([RelayQueue.maxAgeFor]) */
  val maxAgeNs: Long = RelayQueue.MAX_AGE_NS,
  /** Its hello says it takes the phone's steady stream, and the welcome said the phone has one */
  val steadyCapable: Boolean = false,
  /** The longest ping the welcome said the phone takes from it */
  val pingBytes: Int = RelayWire.PING_LONG_BYTES,
  /** Sets TCP_NOTSENT_LOWAT on its socket; false when refused */
  private val lowWaterTuning: (Socket, Int) -> Boolean = { _, _ -> false },
) {
  /** A headset (its window and the flight view) rather than a TV: shorter bounds */
  val headset: Boolean get() = kind != "tv"

  // The stream it gets (p2/relay-bandwidth-2026-10-25.md, 7.7), guarded by the server's lock

  /** The drone's stream or the phone's steady stream */
  @Volatile
  var stream: RelayStream = RelayStream.FULL
    internal set

  /** Why it waits for the steady stream's next key unit to switch to it, null when it does not */
  internal var pendingSteady: RelaySwitchWhy? = null
  internal val policy = RelayStreamPolicy(headset = kind != "tv")
  internal val rate = RelayRateController(headset = kind != "tv")
  internal var lastOverloads = 0L
  internal var lastSteadyDrops = 0L
  internal var streamSinceNs: Long = 0
  internal var secondsFull = 0L
  internal var secondsSteady = 0L
  private val switches = ArrayDeque<RelaySwitch>()

  /** Its switches of stream, oldest first */
  fun switchList(): List<RelaySwitch> = synchronized(switches) { switches.toList() }

  /** The steady bound of its queue ([RelayQueue.steadyMaxAgeFor]) */
  val steadyMaxAgeNs: Long = RelayQueue.steadyMaxAgeFor(kind)

  /**
   * The unsent bytes bound set on its socket now: the fixed one of the full stream until the steady rate sets its own
   */
  @Volatile
  var lowWaterBytes: Int? = socketFacts.notSentLowWaterBytes
    private set

  /** Sets the unsent bytes bound to [bytes] when it moves by more than a quarter ([RelayLowWater]) */
  internal fun followLowWater(bytes: Int) {
    if (!RelayLowWater.shouldApply(lowWaterBytes, bytes)) {
      return
    }
    if (runCatching { lowWaterTuning(socket, bytes) }.getOrDefault(false)) {
      lowWaterBytes = bytes
    }
  }

  /** A switch of stream, kept for the export (the last 64) */
  internal fun recordSwitch(nowNs: Long, to: RelayStream, why: RelaySwitchWhy) {
    synchronized(switches) {
      switches.addLast(RelaySwitch(nowNs, stream, to, why))
      while (switches.size > 64) {
        switches.removeFirst()
      }
    }
    stream = to
    streamSinceNs = nowNs
  }

  val connectedAtNs: Long = clockNs()

  val stats = RelayReceiverStats(connectedAtNs)

  @Volatile
  var lastPingNs: Long = connectedAtNs
    internal set

  /** The headset's median of the phone receive to its receive time, in microseconds, or -1 */
  @Volatile
  var relayDelayMedianUs: Int = -1
    internal set

  /** Pictures the headset showed in its last 10 s, or -1 */
  @Volatile
  var shownPer10s: Int = -1
    internal set

  /** When the record being written started, 0 while the writer waits */
  @Volatile
  var writeStartedNs: Long = 0
    private set

  @Volatile
  var closed = false
    private set

  /** Why it left, once it did */
  @Volatile
  var leftWhy: String? = null
    private set

  @Volatile
  var leftAtNs: Long? = null
    private set

  // Guarded by the server's lock
  internal var lastDescription: StreamDescription? = null
  internal var breakNext = false
  internal var unitSinceReset = false
  internal var resetQueued = false
  internal var nextSampleNs: Long = connectedAtNs + 1_000_000_000L

  private val rateLock = Any()
  private val sent = ArrayDeque<LongArray>()

  val unitsSent: Long get() = stats.unitsSent

  fun startWriter() {
    Thread({ writeLoop() }, "DjiRelayOut-$number").apply { isDaemon = true }.start()
  }

  /** Megabits written in the last second */
  fun megabitsPerSecond(nowNs: Long): Double = bitsLastSecond(nowNs) / 1_000_000.0

  /** Bits written in the last second: what the path carried while the queue held data */
  fun bitsLastSecond(nowNs: Long): Long = synchronized(rateLock) {
    trimRate(nowNs)
    sent.sumOf { it[1] } * 8
  }

  /** A ping read at [nowNs] */
  internal fun onPing(ping: RelayPing, nowNs: Long) {
    lastPingNs = nowNs
    relayDelayMedianUs = ping.relayDelayMedianUs
    shownPer10s = ping.shownPer10s
    stats.onPing(ping)
  }

  /** One line of the timeline each second, from the server's tick */
  internal fun sampleSecond(nowNs: Long) {
    if (nowNs < nextSampleNs) {
      return
    }
    // A tick that came late does not make up the seconds it missed: one line, then the next second from now
    nextSampleNs = maxOf(nextSampleNs + 1_000_000_000L, nowNs + 500_000_000L)
    val steady = stream == RelayStream.STEADY
    if (steady) secondsSteady += 1 else secondsFull += 1
    stats.sample(
      nowNs,
      queue.unitsDropped,
      queue.takeMaxAgeSinceSample(),
      shownPer10s,
      stream = if (steady) 1 else 0,
      bitrateKbps = if (steady) rate.allowedBps / 1000 else -1,
    )
  }

  private fun writeLoop() {
    var why = "writer"
    try {
      while (!closed) {
        val next = queue.take(500)
        if (next == null) {
          if (queue.done) {
            why = "finished"
            break
          }
          continue
        }
        val now = clockNs()
        writeStartedNs = now
        val bytes = write(next, now)
        output.flush()
        writeStartedNs = 0
        stats.onWritten(next, bytes, clockNs() - now, now - next.enqueuedNs)
        next.afterDropNs?.let { stats.onKeyAfterDrop(now - it) }
        synchronized(rateLock) {
          sent.addLast(longArrayOf(now, bytes.toLong()))
          trimRate(now)
        }
        if (next.type == RelayWire.BYE) {
          why = "bye"
          break
        }
      }
    } catch (_: IOException) {
      why = "write failed"
    } finally {
      writeStartedNs = 0
      close(why)
    }
  }

  private fun write(next: RelayOutgoing, nowNs: Long): Int {
    val unit = next.unit
    if (unit != null) {
      val header = RelayUnitHeader(
        sequence = next.sequence,
        firstArrivalNs = unit.firstArrivalNs,
        lastArrivalNs = unit.lastArrivalNs,
        sendNs = nowNs,
        pictureCounter = unit.headerCounter ?: unit.pictureCounter ?: -1,
        contentMs = unit.contentMs,
      )
      output.write(RelayWire.header(RelayWire.UNIT, next.flags, unitHeaderBytes + unit.size))
      output.write(RelayWire.unitHeader(header, unitHeaderBytes))
      output.write(unit.bytes)
      return RelayWire.HEADER_BYTES + unitHeaderBytes + unit.size
    }
    val body = next.body ?: ByteArray(0)
    if (next.type == RelayWire.PONG && body.size == RelayWire.PONG_BYTES) {
      // The phone's send time of the pong is the moment it is written, not the moment it was queued
      RelayWire.putI64(body, 16, nowNs)
    }
    RelayWire.write(output, next.type, next.flags, body)
    return RelayWire.HEADER_BYTES + body.size
  }

  /** Closes the socket; the writer and the reader end on their own, and the server forgets the headset */
  fun close(why: String) {
    if (closed) {
      return
    }
    closed = true
    leftWhy = why
    leftAtNs = clockNs()
    queue.close()
    runCatching { socket.close() }
    onClosed(this, why)
  }

  /** Everything the phone knows of this receiver, for the relay section of the export */
  fun report(nowNs: Long): JsonObject {
    val counters = queue.counters()
    val end = leftAtNs ?: nowNs
    return buildJsonObject {
      put("number", number)
      put("kind", kind)
      put("name", name)
      put("app", app)
      put("address", address)
      put("screenCode", screenCodeId != null)
      put("connectedForMs", (end - connectedAtNs) / 1_000_000)
      put("leftAgoMs", leftAtNs?.let { (nowNs - it) / 1_000_000 })
      put("leftWhy", leftWhy)
      put("unitHeaderBytes", unitHeaderBytes)
      put("sendBufferBytes", socketFacts.sendBufferBytes)
      put("notSentLowWaterBytes", socketFacts.notSentLowWaterBytes)
      put("dropAgeMs", maxAgeNs / 1_000_000)
      put("steadyCapable", steadyCapable)
      put("pingBytes", pingBytes)
      put("stream", stream.wire)
      put("secondsFull", secondsFull)
      put("secondsSteady", secondsSteady)
      put(
        "streamSwitches",
        buildJsonArray {
          synchronized(switches) { switches.toList() }.forEach { switch ->
            add(
              buildJsonObject {
                put("atMs", (switch.atNs - connectedAtNs) / 1_000_000)
                put("from", switch.from.wire)
                put("to", switch.to.wire)
                put("why", switch.why.wire)
              },
            )
          }
        },
      )
      put(
        "steady",
        buildJsonObject {
          put("dropAgeMs", steadyMaxAgeNs / 1_000_000)
          put("cleanDrops", counters.steadyDrops)
          put("unitsSkipped", counters.unitsSkipped)
          put("unitsOffered", counters.steadyOffered)
          put("switchCleared", counters.switchCleared)
          put("breaksSwitch", counters.breaksSwitch)
          put("allowedKbpsNow", rate.allowedBps / 1000)
          put("allowedKbpsMin", rate.minBps / 1000)
          put("allowedKbpsMax", rate.maxBps / 1000)
          put("allowedChanges", rate.changes)
          put("slow", rate.slow)
          put("notSentLowWaterBytesNow", lowWaterBytes)
        },
      )
      put("dropEvents", counters.dropEvents)
      put("unitsDropped", counters.unitsDropped)
      put("cleanRestarts", counters.cleanRestarts)
      put("recoveryPrimers", counters.recoveryPrimers)
      put("keyFirstDrops", counters.keyFirstDrops)
      put("breaksOverload", counters.breaksOverload)
      put("breaksNewStream", counters.breaksNewStream)
      put("queueMaxRecords", counters.maxRecords)
      put("queueMaxBytes", counters.maxUnitBytes)
      put("queueMaxAgeMs", counters.maxAgeNs / 1_000_000)
      stats.toJson(end).forEach { (key, value) -> put(key, value) }
      put("timelineColumns", RelayReceiverStats.TIMELINE_HEADER)
      put("timeline", buildJsonArray { stats.timelineLines().forEach { add(JsonPrimitive(it)) } })
    }
  }

  private fun trimRate(nowNs: Long) {
    while (sent.isNotEmpty() && nowNs - sent.first()[0] > 1_000_000_000L) {
      sent.removeFirst()
    }
  }
}
