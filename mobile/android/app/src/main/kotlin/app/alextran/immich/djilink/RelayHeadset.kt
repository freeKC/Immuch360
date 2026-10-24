package app.alextran.immich.djilink

import java.io.IOException
import java.io.OutputStream
import java.net.Socket

/** A record taken from a headset's queue, ready to write: a unit carries its final flags and sequence */
class RelayOutgoing(
  val type: Int,
  val flags: Int,
  val body: ByteArray?,
  val unit: AccessUnit?,
  val sequence: Long,
  val enqueuedNs: Long,
)

/**
 * The records waiting for one headset (p2/design-stage2b.md, 4.8), with their enqueue times.
 *
 * 1. Units are never dropped one by one: in a stream of P pictures with rare key pictures, one missing unit damages
 *    every following picture until the refresh repairs it.
 * 2. Only the newest TELEMETRY waits: a newer one replaces an older one still queued. A PONG goes ahead of everything.
 * 3. Overload: when the oldest queued unit is older than [maxAgeNs], or the units would hold more than [maxBytes], every
 *    queued unit is dropped and counted, the sequence skips them (so the headset sees the gap), and the next unit goes
 *    out with BREAK. The headset's decoder then builds the picture up again as on a join.
 *
 * The producer (the reader thread of the cable, or the player) only takes the lock for a few microseconds; the writer
 * thread of the headset waits on it. Pure, with the times given, so that it is unit tested.
 */
class RelayQueue(
  private val maxAgeNs: Long = MAX_AGE_NS,
  private val maxBytes: Long = MAX_BYTES,
) {
  companion object {
    /** The bound the phone's own decoder queue already uses (15 units at 30 per second) */
    const val MAX_AGE_NS = 500_000_000L
    const val MAX_BYTES = 4L * 1024 * 1024
  }

  private class Queued(
    val type: Int,
    val flags: Int,
    val body: ByteArray?,
    val unit: AccessUnit?,
    val breakBefore: Boolean,
    val enqueuedNs: Long,
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

  /** Units dropped for this headset since it connected */
  val unitsDropped: Long get() = synchronized(lock) { dropped }

  /** Times the whole backlog was dropped */
  val overloadCount: Long get() = synchronized(lock) { overloads }

  val size: Int get() = synchronized(lock) { records.size }

  val queuedUnitBytes: Long get() = synchronized(lock) { unitBytes }

  /** Closed, or finished and empty: the writer has nothing more to do */
  val done: Boolean get() = synchronized(lock) { closed || (finishing && records.isEmpty()) }

  /** A unit with its own flags (key, in band, replay); [breakBefore] when it does not continue the previous one */
  fun offerUnit(unit: AccessUnit, flags: Int, breakBefore: Boolean, nowNs: Long): Boolean = synchronized(lock) {
    if (closed || finishing) {
      return false
    }
    val oldest = records.firstOrNull { it.unit != null }
    if (oldest != null && (nowNs - oldest.enqueuedNs > maxAgeNs || unitBytes + unit.size > maxBytes)) {
      dropUnits()
    }
    records.addLast(Queued(RelayWire.UNIT, flags, null, unit, breakBefore, nowNs))
    unitBytes += unit.size
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
   * drops and without a gap in the sequence (the headset's decoder starts again anyway)
   */
  fun clearForReset() = synchronized(lock) {
    records.removeAll { it.type == RelayWire.UNIT || it.type == RelayWire.PARAMETERS }
    unitBytes = 0
    pendingBreak = false
  }

  /** The last record: everything else is dropped, nothing more is taken, the writer ends after writing it */
  fun finish(type: Int, body: ByteArray, nowNs: Long) = synchronized(lock) {
    if (closed || finishing) {
      return
    }
    records.clear()
    unitBytes = 0
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
    if (record.breakBefore || pendingBreak) {
      flags = flags or RelayWire.UNIT_BREAK
      pendingBreak = false
    }
    val sequence = nextSequence + skip
    nextSequence = sequence + 1
    skip = 0
    RelayOutgoing(RelayWire.UNIT, flags, null, unit, sequence, record.enqueuedNs)
  }

  private fun dropUnits() {
    var count = 0
    val iterator = records.iterator()
    while (iterator.hasNext()) {
      val record = iterator.next()
      if (record.unit != null) {
        if (record.breakBefore) {
          // The break it carried goes to the next unit with the drop's own
          pendingBreak = true
        }
        iterator.remove()
        count += 1
      }
    }
    unitBytes = 0
    if (count > 0) {
      dropped += count
      skip += count
      overloads += 1
      pendingBreak = true
    }
  }
}

/**
 * One headset on the phone side: its socket, its queue, the writer thread "DjiRelayOut-n", and what its pings say. The
 * reader side (the hello, then its pings) runs on the server's thread of that connection. The writer stamps each unit
 * with the moment it starts writing it, and each pong with the moment it is written; a write that makes no progress
 * for 3 s, or no ping for 5 s, closes the headset ([RelayServer.tick]).
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
) {
  val connectedAtNs: Long = clockNs()

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

  // Guarded by the server's lock
  internal var lastDescription: StreamDescription? = null
  internal var breakNext = false
  internal var unitSinceReset = false
  internal var resetQueued = false

  private val rateLock = Any()
  private val sent = ArrayDeque<LongArray>()

  @Volatile
  var unitsSent = 0L
    private set

  fun startWriter() {
    Thread({ writeLoop() }, "DjiRelayOut-$number").apply { isDaemon = true }.start()
  }

  /** Megabits written in the last second */
  fun megabitsPerSecond(nowNs: Long): Double = synchronized(rateLock) {
    trimRate(nowNs)
    sent.sumOf { it[1] } * 8.0 / 1_000_000.0
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
        pictureCounter = unit.pictureCounter ?: -1,
      )
      output.write(RelayWire.header(RelayWire.UNIT, next.flags, RelayWire.UNIT_HEADER_BYTES + unit.size))
      output.write(RelayWire.unitHeader(header))
      output.write(unit.bytes)
      unitsSent += 1
      return RelayWire.HEADER_BYTES + RelayWire.UNIT_HEADER_BYTES + unit.size
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
    queue.close()
    runCatching { socket.close() }
    onClosed(this, why)
  }

  private fun trimRate(nowNs: Long) {
    while (sent.isNotEmpty() && nowNs - sent.first()[0] > 1_000_000_000L) {
      sent.removeFirst()
    }
  }
}
