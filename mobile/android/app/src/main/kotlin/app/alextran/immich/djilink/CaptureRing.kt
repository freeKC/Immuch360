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
  ;

  /** The word of the index file */
  val word: String get() = name.lowercase()

  val isMarker: Boolean get() = this == OPEN || this == CLOSE

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
        .append(entry.length).append(',')
        .append(entry.direction.word).append(',')
        .append(entry.monotonicNs).append(',')
        .append(entry.wallMs).append('\n')
    }
    return out.toString()
  }
}

/**
 * The evidence machine: a bounded ring of raw bytes with a parallel index of read and write boundaries.
 *
 * Nothing about a DJI link can be settled from a screenshot, so a session produces a file: the bytes, the boundaries
 * with two clocks, and a header saying on which device, which build and which hardware they were taken. That is the
 * observation sheet of the study, filled by the app rather than by hand.
 *
 * The ring is allocated when a capture starts, never before: a pilot who never records holds no buffer at all.
 */
class CaptureRing(
  capacityBytes: Int = DEFAULT_CAPACITY,
  private val monotonicNs: () -> Long = { System.nanoTime() },
  private val wallMs: () -> Long = { System.currentTimeMillis() },
) {
  companion object {
    const val DEFAULT_CAPACITY = 8 * 1024 * 1024
    const val MAX_CAPACITY = 64 * 1024 * 1024
    const val MIN_CAPACITY = 64 * 1024
  }

  private val capacity = capacityBytes.coerceIn(MIN_CAPACITY, MAX_CAPACITY)
  private var ring: ByteArray? = null

  /** Bytes written into the ring since the start, which is also the offset of the next byte */
  private var written = 0L
  private var dropped = 0L
  private val entries = ArrayDeque<CaptureEntry>()

  var recording = false
    private set

  val capacityOfRing: Int get() = capacity
  val totalBytes: Long get() = written
  val droppedBytes: Long get() = dropped
  val records: Int get() = entries.size

  /** Whether the buffer is allocated, which is from the first [start] to a [clear] while not recording */
  val allocated: Boolean get() = ring != null

  @Synchronized
  fun start() {
    if (ring == null) {
      ring = ByteArray(capacity)
    }
    recording = true
  }

  @Synchronized
  fun stop() {
    recording = false
  }

  /** Forgets every byte; the buffer itself goes too unless a capture is running */
  @Synchronized
  fun clear() {
    written = 0
    dropped = 0
    entries.clear()
    if (!recording) {
      ring = null
    }
  }

  /** An open or a close, written into the index at the current offset while a capture runs */
  @Synchronized
  fun mark(direction: CaptureDirection) {
    require(direction.isMarker) { "only an open or a close is a marker" }
    if (!recording) {
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
    val ring = ring ?: return CaptureSnapshot(ByteArray(0), emptyList(), totalBytes = written, droppedBytes = dropped)
    val size = minOf(written, capacity.toLong()).toInt()
    val bytes = ByteArray(size)
    val first = written - size
    val start = (first % capacity).toInt()
    val firstPart = minOf(size, capacity - start)
    ring.copyInto(bytes, 0, start, start + firstPart)
    if (firstPart < size) {
      ring.copyInto(bytes, firstPart, 0, size - firstPart)
    }
    // A record that straddles the start of the window is kept with the part of it that is still there
    val kept = entries.mapNotNull { entry ->
      val end = entry.offset + entry.length
      if (!inWindow(entry, first)) {
        null
      } else {
        val from = maxOf(entry.offset, first)
        CaptureEntry(
          offset = from - first,
          length = (end - from).toInt(),
          direction = entry.direction,
          monotonicNs = entry.monotonicNs,
          wallMs = entry.wallMs,
        )
      }
    }
    return CaptureSnapshot(bytes = bytes, entries = kept, totalBytes = written, droppedBytes = dropped)
  }
}
