package app.alextran.immich.djilink

import java.security.MessageDigest

/** Which way bytes went */
enum class CaptureDirection {
  /** From the remote controller to this device */
  IN,

  /** From this device to the remote controller; in stage 1 only the one byte liveness probe */
  OUT,
}

/**
 * One read or one write, kept apart from the bytes themselves. One read is one USB transfer, and knowing where a
 * transfer ended is what makes a reassembly question answerable afterwards.
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

  /** One line per read or write: offset, length, direction, monotonic nanoseconds, wall clock milliseconds */
  fun indexCsv(): String {
    val out = StringBuilder("offset,length,direction,monotonic_ns,wall_ms\n")
    for (entry in entries) {
      out.append(entry.offset).append(',')
        .append(entry.length).append(',')
        .append(if (entry.direction == CaptureDirection.IN) "in" else "out").append(',')
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
  private val ring = ByteArray(capacity)

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

  fun start() {
    recording = true
  }

  fun stop() {
    recording = false
  }

  fun clear() {
    written = 0
    dropped = 0
    entries.clear()
  }

  @Synchronized
  fun record(direction: CaptureDirection, data: ByteArray, offset: Int = 0, length: Int = data.size - offset) {
    if (!recording || length <= 0) {
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
    while (entries.isNotEmpty() && entries.first().offset + entries.first().length <= oldest) {
      dropped += entries.first().length
      entries.removeFirst()
    }
  }

  @Synchronized
  fun snapshot(): CaptureSnapshot {
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
      if (end <= first) {
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
