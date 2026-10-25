package app.alextran.immich.djilink

/**
 * Where an encoded picture of the steady stream comes from: the drone unit decoder 2 made it from, found back by its
 * presentation time ([RelayPtsMap]). Its phone receive times and content time go in the steady unit's header, so a
 * receiver's jitter buffer paces it as before (p2/relay-bandwidth-2026-10-25.md, 7.3).
 */
data class RelaySourceStamp(
  val firstArrivalNs: Long,
  val lastArrivalNs: Long,
  /** The drone's content clock of the unit, in milliseconds, or -1 */
  val contentMs: Long,
  /** The SEI picture counter of the drone unit, or -1 */
  val counter: Int,
)

/**
 * The output of the phone's encoder as the relay sends it (p2/relay-bandwidth-2026-10-25.md, 7.2 DjiRelayEnc): each
 * output buffer copied once into an [AccessUnit] (its start codes scanned, its key flag from its NAL types), and the
 * VPS, SPS and PPS of the codec configuration buffer or of a key unit's in band sets read with the same code as the
 * drone's ([RelayWire.parseParameters], [HevcSpsReader]).
 */
object EncodedUnits {
  /**
   * The access unit of the Annex B bytes of one encoder output; [stamp] gives its source's times (null when it went
   * from the map: the unit then carries [nowNs] and no content time); [counter] is the steady stream's own picture
   * counter. Null when the bytes hold no NAL unit.
   */
  fun unitOf(bytes: ByteArray, stamp: RelaySourceStamp?, nowNs: Long, counter: Int): AccessUnit? {
    val nals = AnnexB.split(bytes)
    if (nals.isEmpty()) {
      return null
    }
    val unit = AccessUnit(
      bytes = bytes,
      nalTypes = IntArray(nals.size) { HevcNal.type(bytes[nals[it].offset].toInt() and 0xFF) },
      nalOffsets = IntArray(nals.size) { nals[it].offset },
      firstArrivalNs = stamp?.firstArrivalNs ?: nowNs,
      lastArrivalNs = stamp?.lastArrivalNs ?: nowNs,
      closedBy = AccessUnitClose.BOUNDARY,
    )
    unit.contentMs = stamp?.contentMs ?: -1
    unit.headerCounter = counter
    return unit
  }

  /**
   * The VPS, SPS and PPS of a codec configuration buffer or of a key unit with its sets in band; null when one lacks
   */
  fun descriptionOf(bytes: ByteArray): StreamDescription? = RelayWire.parseParameters(bytes)
}

/**
 * Presentation time to the stamps of the drone unit it was decoded from (p2/relay-bandwidth-2026-10-25.md, 7.2): 256
 * entries, the oldest replaced, which is over four seconds of pictures at 60 a second. Its own lock: decoder 2's input
 * thread writes it, the encoder's output thread reads it.
 */
class RelayPtsMap(private val capacity: Int = CAPACITY) {
  companion object {
    const val CAPACITY = 256
  }

  private val lock = Any()
  private val pts = LongArray(capacity) { Long.MIN_VALUE }
  private val stamps = arrayOfNulls<RelaySourceStamp>(capacity)
  private var next = 0

  fun put(ptsUs: Long, stamp: RelaySourceStamp) = synchronized(lock) {
    pts[next] = ptsUs
    stamps[next] = stamp
    next = (next + 1) % capacity
  }

  /**
   * The stamps put with [ptsUs], within [toleranceUs] (an encoder may round the time to the microsecond); null if gone
   */
  fun find(ptsUs: Long, toleranceUs: Long = 1): RelaySourceStamp? = synchronized(lock) {
    var best: RelaySourceStamp? = null
    var bestDistance = Long.MAX_VALUE
    for (index in 0 until capacity) {
      val at = pts[index]
      if (at == Long.MIN_VALUE) {
        continue
      }
      val distance = kotlin.math.abs(at - ptsUs)
      if (distance <= toleranceUs && distance < bestDistance) {
        best = stamps[index]
        bestDistance = distance
      }
    }
    best
  }

  fun clear() = synchronized(lock) {
    pts.fill(Long.MIN_VALUE)
    stamps.fill(null)
    next = 0
  }
}

/**
 * Which decoded pictures go to the encoder (p2/relay-bandwidth-2026-10-25.md, 7.2): a picture whose presentation time
 * is at least one period less 4 ms after the last one kept. From 60 a second to 30 (or 15), a 30 a second stream at 30
 * kept whole. A time that steps back starts the count again from it.
 */
class RelayDecimator(perSecond: Int = 30) {
  companion object {
    const val SLACK_US = 4_000L
  }

  @Volatile
  var perSecond: Int = perSecond
    set(value) {
      field = value.coerceIn(1, 60)
    }

  private var lastKeptUs: Long? = null

  fun keep(ptsUs: Long): Boolean {
    val last = lastKeptUs
    val interval = 1_000_000L / perSecond - SLACK_US
    if (last == null || ptsUs < last || ptsUs - last >= interval) {
      lastKeptUs = ptsUs
      return true
    }
    return false
  }

  fun reset() {
    lastKeptUs = null
  }
}

/**
 * The content clock of the drone's units as presentation times for decoder 2 and the encoder, always increasing: a
 * step back (a played capture that loops) or a repeat goes on one 30th of a second after the last time given.
 */
class MonotonicPts {
  companion object {
    const val STEP_US = 33_333L
  }

  private var offsetUs = 0L
  private var lastUs: Long? = null

  fun of(contentUs: Long): Long {
    var value = contentUs + offsetUs
    val last = lastUs
    if (last != null && value <= last) {
      offsetUs += last + STEP_US - value
      value = last + STEP_US
    }
    lastUs = value
    return value
  }

  fun reset() {
    offsetUs = 0
    lastUs = null
  }
}

/**
 * The key pictures asked of the phone's encoder (p2/relay-bandwidth-2026-10-25.md, 7.5 item 5): one encoder serves
 * every steady receiver, so a key asked for one goes to all. A request within [spacingNs] of the last key waits until
 * then; one within [spacingNs] of the next periodic key ([periodNs] after the last) waits for it; one made while an
 * earlier request has not brought its key yet (for up to a second) is served by it. Counted by cause. Pure, with the
 * times given; its user holds the lock.
 */
class RelayKeyRequests(private val spacingNs: Long = SPACING_NS, private val periodNs: Long = PERIOD_NS) {
  companion object {
    const val SPACING_NS = 300_000_000L
    const val PERIOD_NS = 2_000_000_000L
    const val ANSWER_NS = 1_000_000_000L
  }

  private var lastKeyNs: Long? = null
  private var lastRequestNs: Long? = null
  private var waiting = false

  /** Requests by cause */
  val byCause = linkedMapOf(RelayKeyCause.JOIN to 0L, RelayKeyCause.DROP to 0L, RelayKeyCause.SWITCH to 0L)

  /** Requests served by a key already asked or due */
  var coalesced = 0L
    private set

  /** Key pictures asked of the encoder */
  var sent = 0L
    private set

  /** Key pictures out of the encoder that were asked, and the others (its own period, its first) */
  var keysAsked = 0L
    private set
  var keysPeriodic = 0L
    private set

  /** A receiver needs a key picture for [cause]: true when the encoder is to be asked now */
  fun request(cause: RelayKeyCause, nowNs: Long): Boolean {
    byCause[cause] = (byCause[cause] ?: 0L) + 1
    if (waiting) {
      coalesced += 1
      return false
    }
    val asked = lastRequestNs
    val key = lastKeyNs
    if (asked != null && (key == null || key < asked) && nowNs - asked < ANSWER_NS) {
      coalesced += 1
      return false
    }
    if (key != null) {
      val since = nowNs - key
      if (periodNs - since in 0..spacingNs) {
        coalesced += 1
        return false
      }
      if (since < spacingNs) {
        waiting = true
        coalesced += 1
        return false
      }
    }
    lastRequestNs = nowNs
    sent += 1
    return true
  }

  /** On a tick: true when a request that waited is due now */
  fun due(nowNs: Long): Boolean {
    if (!waiting) {
      return false
    }
    val key = lastKeyNs
    if (key != null && nowNs - key < spacingNs) {
      return false
    }
    waiting = false
    lastRequestNs = nowNs
    sent += 1
    return true
  }

  /** A key picture came out of the encoder at [nowNs]: true when it was asked for */
  fun onKey(nowNs: Long): Boolean {
    val asked = lastRequestNs
    val previous = lastKeyNs
    val wasAsked = asked != null && (previous == null || asked > previous)
    lastKeyNs = nowNs
    if (wasAsked) keysAsked += 1 else keysPeriodic += 1
    return wasAsked
  }

  /** A new encoder: its first output is a key picture anyway */
  fun onEncoderStarted() {
    waiting = false
  }
}
