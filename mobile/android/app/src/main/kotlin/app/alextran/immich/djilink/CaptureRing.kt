package app.alextran.immich.djilink

import java.security.MessageDigest

/** Which way bytes went */
enum class CaptureDirection {
  /** From the remote controller to this device */
  IN,

  /** From this device to the remote controller; in stage 1 only the one byte liveness probe */
  OUT,

  /** A marker with no bytes: a descriptor was opened here, so the stream before it belongs to another session */
  OPEN,

  /** A marker with no bytes: the descriptor was closed here */
  CLOSE,

  /**
   * A marker with no bytes between the head and the tail of a capture: the bytes of the session in between were not
   * kept, and the length column of the index says how many. A replay restarts its parsers here, as at an open.
   */
  GAP,
  ;

  /** The word of the index file */
  val word: String get() = name.lowercase()

  val isMarker: Boolean get() = this == OPEN || this == CLOSE || this == GAP

  companion object {
    fun ofWord(word: String): CaptureDirection? = entries.firstOrNull { it.word == word }
  }
}

/**
 * One read or one write, kept apart from the bytes themselves. One read is one USB transfer, and knowing where a
 * transfer ended is what makes a reassembly question answerable afterwards. An open or a close is a marker of length
 * zero at the offset where it happened.
 */
data class CaptureEntry(
  /** Offset of the first byte of this record in the whole session, not in the ring */
  val offset: Long,
  val length: Int,
  val direction: CaptureDirection,
  val monotonicNs: Long,
  val wallMs: Long,
  /** For a [CaptureDirection.GAP] marker only: the bytes of the session not kept there */
  val skippedBytes: Long = 0,
)

data class CaptureSnapshot(
  /** The bytes still in the ring, oldest first */
  val bytes: ByteArray,
  /** The records those bytes cover, oldest first, with [CaptureEntry.offset] rebased on the snapshot */
  val entries: List<CaptureEntry>,
  /** Bytes seen since the capture started, whether they are still in the ring or not */
  val totalBytes: Long,
  val droppedBytes: Long,
) {
  fun sha256(): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
    return digest.joinToString("") { "%02x".format(it) }
  }

  /**
   * One line per read, per write and per open or close: offset, length, direction (in, out, open, close), monotonic
   * nanoseconds, wall clock milliseconds
   */
  fun indexCsv(): String {
    val out = StringBuilder("offset,length,direction,monotonic_ns,wall_ms\n")
    for (entry in entries) {
      out.append(entry.offset).append(',')
        .append(if (entry.direction == CaptureDirection.GAP) entry.skippedBytes else entry.length.toLong()).append(',')
        .append(entry.direction.word).append(',')
        .append(entry.monotonicNs).append(',')
        .append(entry.wallMs).append('\n')
    }
    return out.toString()
  }
}

/**
 * The evidence machine: a head and a tail of raw bytes with a parallel index of read and write boundaries.
 *
 * Nothing about a DJI link can be settled from a screenshot, so a session produces a file: the bytes, the boundaries
 * with two clocks, and a header saying on which device, which build and which hardware they were taken. That is the
 * observation sheet of the study, filled by the app rather than by hand.
 *
 * The head keeps the first [headBytes] of a session: from the first open after the capture starts, or from the start
 * when an accessory is already open. That is where the link up sequence is, which a long session would otherwise push
 * out. The tail is a ring of the last [capacityBytes]. A record that does not fit what is left of the head closes the
 * head and goes to the tail. The export writes the head, then the tail, with a [CaptureDirection.GAP] marker between
 * them when bytes were not kept.
 *
 * Both are allocated when a capture starts, never before: a pilot who never records holds no buffer at all.
 */
class CaptureRing(
  capacityBytes: Int = DEFAULT_CAPACITY,
  headBytes: Int = DEFAULT_HEAD,
  private val monotonicNs: () -> Long = { System.nanoTime() },
  private val wallMs: () -> Long = { System.currentTimeMillis() },
) {
  companion object {
    /** The tail: 16 MiB, 10 to 25 s of a session at the rates of the 23 October 2026 capture */
    const val DEFAULT_CAPACITY = 16 * 1024 * 1024

    /** The head: 4 MiB, 3 to 6 s of a session, enough for the link up sequence */
    const val DEFAULT_HEAD = 4 * 1024 * 1024
    const val MAX_CAPACITY = 64 * 1024 * 1024
    const val MIN_CAPACITY = 64 * 1024
  }

  private val capacity = capacityBytes.coerceIn(MIN_CAPACITY, MAX_CAPACITY)
  private val headCapacity = headBytes.coerceIn(0, MAX_CAPACITY)
  private var ring: ByteArray? = null
  private var head: ByteArray? = null
  private var headLength = 0
  private val headEntries = ArrayList<CaptureEntry>()

  /** The head takes records now */
  private var headOpen = false

  /** The head is waiting for the first open of the capture */
  private var headWaiting = false

  /** The head is full or was never wanted: everything goes to the tail */
  private var headClosed = false

  /** Bytes written into the tail since the start, which is also the offset of the next byte there */
  private var written = 0L
  private var dropped = 0L
  private val entries = ArrayDeque<CaptureEntry>()

  var recording = false
    private set

  val capacityOfRing: Int get() = capacity
  val capacityOfHead: Int get() = headCapacity
  val totalBytes: Long get() = headLength + written
  val droppedBytes: Long get() = dropped
  val records: Int get() = headEntries.size + entries.size

  /** Whether the buffers are allocated, which is from the first [start] to a [clear] while not recording */
  val allocated: Boolean get() = ring != null

  /** Starts recording; [accessoryOpen] says a session is already under way, so the head starts with the next record */
  @Synchronized
  fun start(accessoryOpen: Boolean = false) {
    if (ring == null) {
      ring = ByteArray(capacity)
    }
    if (headCapacity > 0 && head == null && !headClosed && headLength == 0 && written == 0L) {
      head = ByteArray(headCapacity)
      headOpen = accessoryOpen
      headWaiting = !accessoryOpen
    } else if (headCapacity == 0) {
      headClosed = true
    }
    recording = true
  }

  @Synchronized
  fun stop() {
    recording = false
  }

  /** Forgets every byte; the buffers themselves go too unless a capture is running */
  @Synchronized
  fun clear() {
    written = 0
    dropped = 0
    entries.clear()
    headEntries.clear()
    headLength = 0
    headClosed = false
    headOpen = false
    headWaiting = false
    if (!recording) {
      ring = null
      head = null
    } else if (headCapacity > 0) {
      // A clear while recording starts a new head with the next open
      head = head ?: ByteArray(headCapacity)
      headWaiting = true
    }
  }

  /** An open or a close, written into the index at the current offset while a capture runs */
  @Synchronized
  fun mark(direction: CaptureDirection) {
    require(direction == CaptureDirection.OPEN || direction == CaptureDirection.CLOSE) {
      "only an open or a close is marked live"
    }
    if (!recording) {
      return
    }
    if (direction == CaptureDirection.OPEN && headWaiting) {
      headWaiting = false
      headOpen = true
    }
    if (headOpen && !headClosed) {
      headEntries.add(CaptureEntry(headLength.toLong(), 0, direction, monotonicNs(), wallMs()))
      return
    }
    entries.addLast(CaptureEntry(written, 0, direction, monotonicNs(), wallMs()))
  }

  @Synchronized
  fun record(direction: CaptureDirection, data: ByteArray, offset: Int = 0, length: Int = data.size - offset) {
    require(!direction.isMarker) { "a marker carries no bytes" }
    val ring = ring
    if (!recording || ring == null || length <= 0) {
      return
    }
    val headBuffer = head
    if (headOpen && !headClosed && headBuffer != null) {
      if (headLength + length <= headCapacity) {
        headEntries.add(CaptureEntry(headLength.toLong(), length, direction, monotonicNs(), wallMs()))
        data.copyInto(headBuffer, headLength, offset, offset + length)
        headLength += length
        return
      }
      // The first record that does not fit closes the head; it and the rest of the session go to the tail
      headClosed = true
      headOpen = false
    }
    val entry = CaptureEntry(
      offset = written,
      length = length,
      direction = direction,
      monotonicNs = monotonicNs(),
      wallMs = wallMs(),
    )
    // A record longer than the whole ring keeps only its tail; its length in the index stays the real one
    val keep = minOf(length, capacity)
    val from = offset + (length - keep)
    val start = ((written + (length - keep)) % capacity).toInt()
    val firstPart = minOf(keep, capacity - start)
    data.copyInto(ring, start, from, from + firstPart)
    if (firstPart < keep) {
      data.copyInto(ring, 0, from + firstPart, from + keep)
    }
    written += length
    entries.addLast(entry)
    // Records whose bytes the ring no longer holds leave the index, so that the two always describe the same window
    val oldest = written - capacity
    while (entries.isNotEmpty() && !inWindow(entries.first(), oldest)) {
      dropped += entries.first().length
      entries.removeFirst()
    }
  }

  /** A record is in the window while one of its bytes is; a marker while its offset is */
  private fun inWindow(entry: CaptureEntry, first: Long): Boolean =
    if (entry.direction.isMarker) entry.offset >= first else entry.offset + entry.length > first

  @Synchronized
  fun snapshot(): CaptureSnapshot {
    val ring = ring ?: return CaptureSnapshot(ByteArray(0), emptyList(), totalBytes = totalBytes, droppedBytes = dropped)
    val size = minOf(written, capacity.toLong()).toInt()
    val bytes = ByteArray(headLength + size)
    head?.copyInto(bytes, 0, 0, headLength)
    val first = written - size
    val start = (first % capacity).toInt()
    val firstPart = minOf(size, capacity - start)
    ring.copyInto(bytes, headLength, start, start + firstPart)
    if (firstPart < size) {
      ring.copyInto(bytes, headLength + firstPart, 0, size - firstPart)
    }
    val kept = ArrayList<CaptureEntry>(headEntries.size + entries.size + 1)
    kept.addAll(headEntries)
    // The tail bytes before its window were not kept: with a head in front, a gap marker says how many
    if (first > 0 && headEntries.isNotEmpty()) {
      val anchor = entries.firstOrNull()
      kept.add(
        CaptureEntry(
          offset = headLength.toLong(),
          length = 0,
          direction = CaptureDirection.GAP,
          monotonicNs = anchor?.monotonicNs ?: monotonicNs(),
          wallMs = anchor?.wallMs ?: wallMs(),
          skippedBytes = first,
        )
      )
    }
    // A record that straddles the start of the window is kept with the part of it that is still there
    for (entry in entries) {
      val end = entry.offset + entry.length
      if (!inWindow(entry, first)) {
        continue
      }
      val from = maxOf(entry.offset, first)
      kept.add(
        CaptureEntry(
          offset = headLength + (from - first),
          length = (end - from).toInt(),
          direction = entry.direction,
          monotonicNs = entry.monotonicNs,
          wallMs = entry.wallMs,
        )
      )
    }
    return CaptureSnapshot(bytes = bytes, entries = kept, totalBytes = totalBytes, droppedBytes = dropped)
  }
}
