package app.alextran.immich.djilink

/**
 * One access unit (one picture with the NAL units that go with it), as it is handed to the decoder.
 *
 * [bytes] start with the start code of the first NAL unit; [nalTypes] and [nalOffsets] give the type and the offset of
 * the first header byte of each NAL unit in [bytes]. The two arrival times are those of the fragments that brought the
 * first byte and the last byte of the unit, on the clock of the caller.
 */
class AccessUnit(
  val bytes: ByteArray,
  val nalTypes: IntArray,
  val nalOffsets: IntArray,
  val firstArrivalNs: Long,
  val lastArrivalNs: Long,
  val closedBy: AccessUnitClose,
  /** The video channel the unit came from */
  val channel: Int = 0,
) {
  val size: Int get() = bytes.size

  /** An intra random access point picture, where a decoder can start clean */
  val isKey: Boolean = nalTypes.any { HevcNal.isIntraRandomAccess(it) }

  val hasSlice: Boolean = nalTypes.any { HevcNal.isSlice(it) }

  val hasParameterSets: Boolean = nalTypes.any { HevcNal.isParameterSet(it) }

  val startsWithDelimiter: Boolean = nalTypes.firstOrNull() == HevcNal.ACCESS_UNIT_DELIMITER

  /** The NAL units of the unit, each from its first header byte to the byte before the next start code */
  val nals: List<NalRef> by lazy {
    List(nalOffsets.size) { index ->
      var end = if (index + 1 < nalOffsets.size) nalOffsets[index + 1] - 3 else bytes.size
      while (end > nalOffsets[index] && index + 1 < nalOffsets.size && bytes[end - 1].toInt() == 0) {
        end -= 1
      }
      NalRef(nalOffsets[index], maxOf(nalOffsets[index], end))
    }
  }

  /** The two header bytes of the first NAL unit, which the H.265 signature check reads */
  fun firstHeader(): Pair<Int, Int>? {
    val at = nalOffsets.firstOrNull() ?: return null
    if (at + 1 >= bytes.size) {
      return null
    }
    return (bytes[at].toInt() and 0xFF) to (bytes[at + 1].toInt() and 0xFF)
  }

  /** The picture counter of the suffix SEI, see [SeiPictureCounter] */
  val pictureCounter: Int? by lazy { SeiPictureCounter.read(bytes, nals) }
}

enum class AccessUnitClose {
  /** The next unit began: a delimiter, a parameter set, a prefix SEI or a first slice after a slice */
  BOUNDARY,

  /** A fragment shorter than the largest seen ended a unit that holds a slice (the fallback) */
  SHORT_FRAGMENT,
}

data class AssemblerCounters(
  val fragments: Long = 0,
  val bytes: Long = 0,
  val largestFragment: Int = 0,
  val units: Long = 0,
  val closedByBoundary: Long = 0,
  val closedByShortFragment: Long = 0,
  /** Bytes dropped before the first unit boundary of a stream: a picture already under way when the stream began */
  val bytesBeforeFirstUnit: Long = 0,
  /** Units above [AccessUnitAssembler.MAX_UNIT_BYTES], dropped whole */
  val unitsTooLarge: Long = 0,
  val bytesDroppedTooLarge: Long = 0,
  /** Bytes of an unfinished unit thrown away by a new stream, a gap of a replay or a page restart */
  val bytesDroppedAtReset: Long = 0,
)

/**
 * Cuts the payloads of a video channel into access units at the NAL level.
 *
 * The rules are ours, written from H.265 section 7.4.2.4.4 (which NAL units may begin an access unit) and from the 23
 * October 2026 capture (p2/capture-2026-10-23.md, section 4), where a payload that opens with a start code is not always
 * a new picture: thirteen payloads open with the suffix SEI of the picture under way.
 *
 * 1. Payloads are appended to the current unit. The start code scan resumes where it stopped, so a start code split
 *    across two fragments is found, and a start code whose header bytes have not arrived yet waits for them.
 * 2. At each start code the two byte header gives the type; for a slice the first bit after the header is
 *    first_slice_segment_in_pic_flag.
 * 3. A boundary is placed before an access unit delimiter (35), a VPS, SPS or PPS (32 to 34), a prefix SEI (39) or a
 *    first slice, but only once the current unit holds a slice. So the parameter sets that precede a key picture join
 *    that picture's unit, and a suffix SEI (40), an end of sequence, an end of bitstream or a filler unit always stays
 *    with its picture.
 * 4. The NAL unit that caused the boundary opens the next unit. The remote puts the next picture's delimiter at the
 *    very end of the last fragment of a picture, so a unit is handed over the moment that fragment arrives.
 * 5. Fallback, for a product that sends no trailing delimiter: a fragment shorter than the largest fragment seen
 *    closes a unit that holds a slice.
 * 6. Before the first boundary of a stream, bytes are dropped and counted. [reset] clears the unit under way.
 * 7. A unit above [MAX_UNIT_BYTES] is dropped and counted, and the assembler waits for the next boundary.
 *
 * No codec is assumed beyond the H.265 header: an H.264 stream read this way gives units that are not pictures, which
 * is why the codec is detected separately ([CodecDetector]) before anything is decoded.
 */
class AccessUnitAssembler(
  private val maxUnitBytes: Int = MAX_UNIT_BYTES,
  private val channel: Int = 0,
) {
  companion object {
    const val MAX_UNIT_BYTES = 4 * 1024 * 1024

    private val BOUNDARY_TYPES = setOf(
      HevcNal.ACCESS_UNIT_DELIMITER,
      HevcNal.VPS,
      HevcNal.SPS,
      HevcNal.PPS,
      HevcNal.PREFIX_SEI,
    )
  }

  private var buffer = ByteArray(64 * 1024)
  private var length = 0

  /** The next index where a start code prefix could begin that has not been looked at */
  private var scan = 0
  private var synced = false
  private var hasSlice = false
  private var firstArrivalNs = 0L
  private var types = IntArray(16)
  private var offsets = IntArray(16)
  private var nalCount = 0

  /** True while a unit above the size bound is being skipped up to the next boundary */
  private var skippingTooLarge = false

  var counters = AssemblerCounters()
    private set

  /** Bytes of the unit under way, which a pulled cable leaves unfinished */
  val pendingBytes: Int get() = if (synced) length else 0

  /** Appends one payload that arrived at [arrivalNs] and returns the units it completes, oldest first */
  fun offer(payload: ByteArray, arrivalNs: Long): List<AccessUnit> {
    counters = counters.copy(
      fragments = counters.fragments + 1,
      bytes = counters.bytes + payload.size,
      largestFragment = maxOf(counters.largestFragment, payload.size),
    )
    if (payload.isEmpty()) {
      return emptyList()
    }
    if (length == 0) {
      firstArrivalNs = arrivalNs
    }
    append(payload)
    val out = mutableListOf<AccessUnit>()
    scanForBoundaries(arrivalNs, out)
    if (!synced) {
      // Nothing to keep but the bytes where a start code may still be completing
      val keepFrom = maxOf(0, minOf(scan, length) - 1)
      if (keepFrom > 0) {
        if (skippingTooLarge) {
          counters = counters.copy(bytesDroppedTooLarge = counters.bytesDroppedTooLarge + keepFrom)
        } else {
          counters = counters.copy(bytesBeforeFirstUnit = counters.bytesBeforeFirstUnit + keepFrom)
        }
        shift(keepFrom)
      }
      return out
    }
    if (length > maxUnitBytes) {
      dropTooLarge()
      return out
    }
    if (payload.size < counters.largestFragment && hasSlice) {
      emit(length, arrivalNs, AccessUnitClose.SHORT_FRAGMENT, out)
      hasSlice = false
      nalCount = 0
    }
    return out
  }

  /** A new stream, a gap of a replay or a page restart: the unit under way goes, the counters stay */
  fun reset() {
    if (synced && length > 0) {
      counters = counters.copy(bytesDroppedAtReset = counters.bytesDroppedAtReset + length)
    }
    length = 0
    scan = 0
    synced = false
    hasSlice = false
    nalCount = 0
    skippingTooLarge = false
  }

  fun clearCounters() {
    counters = AssemblerCounters()
  }

  private fun scanForBoundaries(arrivalNs: Long, out: MutableList<AccessUnit>) {
    var index = scan
    while (index + 2 < length) {
      if (!AnnexB.isStartCodeAt(buffer, index, length)) {
        index += 1
        continue
      }
      val header = index + 3
      // The type, the layer byte and the first bit of a slice header must all be here before a decision
      if (header + 2 >= length) {
        break
      }
      val type = HevcNal.type(buffer[header].toInt() and 0xFF)
      val firstSlice = HevcNal.isSlice(type) && (buffer[header + 2].toInt() and 0x80) != 0
      val boundary = type in BOUNDARY_TYPES || firstSlice
      val startCode = if (index > 0 && buffer[index - 1].toInt() == 0) index - 1 else index
      var headerAt = header
      if (!synced) {
        if (boundary) {
          if (startCode > 0) {
            if (skippingTooLarge) {
              counters = counters.copy(bytesDroppedTooLarge = counters.bytesDroppedTooLarge + startCode)
            } else {
              counters = counters.copy(bytesBeforeFirstUnit = counters.bytesBeforeFirstUnit + startCode)
            }
            shift(startCode)
            headerAt -= startCode
          }
          synced = true
          skippingTooLarge = false
          hasSlice = HevcNal.isSlice(type)
          nalCount = 0
          addNal(type, headerAt)
          firstArrivalNs = arrivalNs
        }
      } else if (boundary && hasSlice) {
        emit(startCode, arrivalNs, AccessUnitClose.BOUNDARY, out)
        headerAt -= startCode
        hasSlice = HevcNal.isSlice(type)
        nalCount = 0
        addNal(type, headerAt)
        firstArrivalNs = arrivalNs
      } else {
        addNal(type, headerAt)
        if (HevcNal.isSlice(type)) {
          hasSlice = true
        }
      }
      index = headerAt + 2
    }
    scan = index
  }

  /** Hands over the first [end] bytes as a unit and keeps the rest as the start of the next one */
  private fun emit(end: Int, arrivalNs: Long, closedBy: AccessUnitClose, out: MutableList<AccessUnit>) {
    if (end > maxUnitBytes) {
      counters = counters.copy(
        unitsTooLarge = counters.unitsTooLarge + 1,
        bytesDroppedTooLarge = counters.bytesDroppedTooLarge + end,
      )
      shift(end)
      return
    }
    val count = (0 until nalCount).count { offsets[it] < end }
    val unit = AccessUnit(
      bytes = buffer.copyOfRange(0, end),
      nalTypes = types.copyOf(count),
      nalOffsets = offsets.copyOf(count),
      firstArrivalNs = firstArrivalNs,
      lastArrivalNs = arrivalNs,
      closedBy = closedBy,
      channel = channel,
    )
    out.add(unit)
    counters = counters.copy(
      units = counters.units + 1,
      closedByBoundary = counters.closedByBoundary + if (closedBy == AccessUnitClose.BOUNDARY) 1 else 0,
      closedByShortFragment = counters.closedByShortFragment +
        if (closedBy == AccessUnitClose.SHORT_FRAGMENT) 1 else 0,
    )
    shift(end)
    firstArrivalNs = arrivalNs
  }

  private fun dropTooLarge() {
    counters = counters.copy(
      unitsTooLarge = counters.unitsTooLarge + 1,
      bytesDroppedTooLarge = counters.bytesDroppedTooLarge + length,
    )
    length = 0
    scan = 0
    synced = false
    hasSlice = false
    nalCount = 0
    skippingTooLarge = true
  }

  private fun addNal(type: Int, headerAt: Int) {
    if (nalCount == types.size) {
      types = types.copyOf(nalCount * 2)
      offsets = offsets.copyOf(nalCount * 2)
    }
    types[nalCount] = type
    offsets[nalCount] = headerAt
    nalCount += 1
  }

  /** Drops the first [count] bytes; NAL offsets and the scan position move with the bytes that stay */
  private fun shift(count: Int) {
    if (count <= 0) {
      return
    }
    buffer.copyInto(buffer, 0, count, length)
    length -= count
    scan = maxOf(0, scan - count)
    var kept = 0
    for (index in 0 until nalCount) {
      val moved = offsets[index] - count
      if (moved >= 0) {
        types[kept] = types[index]
        offsets[kept] = moved
        kept += 1
      }
    }
    nalCount = kept
  }

  private fun append(payload: ByteArray) {
    if (length + payload.size > buffer.size) {
      var size = buffer.size
      while (size < length + payload.size) {
        size *= 2
      }
      buffer = buffer.copyOf(size)
    }
    payload.copyInto(buffer, length)
    length += payload.size
  }
}
