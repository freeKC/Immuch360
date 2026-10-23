package app.alextran.immich.djilink

/**
 * A saved capture fed back through the same codecs, with no hardware.
 *
 * This is what makes the parser answerable: a session recorded once on a cable can be replayed on a phone, on an
 * emulator or in a unit test, and it goes through the very decoders the live path uses. The index says which bytes
 * came in and when, so the inbound stream is replayed on its own; without an index every byte is treated as inbound,
 * which the caller is told. An open marker in the index restarts the parsers, as a new descriptor does live, so two
 * sessions of one capture are never glued together; a gap marker between the head and the tail of a capture does the
 * same, since the bytes on either side of it are not contiguous. The checksum parameters are arguments, so that a seed the live
 * page voted for can be tried on the same bytes.
 */
object CaptureReplay {
  data class Result(
    val readsReplayed: Int,
    val bytesReplayed: Long,
    val envelopes: EnvelopeCounters,
    val router: RouterCounters,
    val control: P3Counters,
    val channels: List<ChannelCounters>,
    val pairs: List<PairCounters>,
    val frames: List<FrameLine>,
    val telemetry: List<TelemetryMessage>,
    val video: List<VideoChannelCounters>,
    val probe: VideoProbeReport,
    val usedIndex: Boolean,
    val crc: CrcReport,
    /** Open markers met in the index, each one a new stream */
    val opens: Int,
    /** Gap markers met in the index, each one a new stream too */
    val gaps: Int = 0,
    val assembler: AssemblerCounters = AssemblerCounters(),
    /** Bytes of the picture under way when the capture ended */
    val pendingVideoBytes: Int = 0,
    val telemetryValues: TelemetryValues? = null,
    val requests: List<RequestRow> = emptyList(),
    val aircraftSeenMs: Long? = null,
    val remoteSeenMs: Long? = null,
  )

  /** What reading an index found: the records that fit, and the line numbers of those that did not (the header is 1) */
  data class IndexReading(val entries: List<CaptureEntry>, val rejectedLines: List<Int>) {
    val damaged: Boolean get() = rejectedLines.isNotEmpty()
  }

  /**
   * Reads an index written by [CaptureSnapshot.indexCsv], checking every line against what an export can hold: a read
   * or a write of 0 to [CaptureRing.MAX_CAPACITY] bytes that lies inside the file of [fileBytes] when it is known, an
   * open or a close of no bytes, a gap of a positive count, offsets and clocks that are not negative. A line that does
   * not parse or does not fit is rejected and its number returned, never passed on: a damaged or hand made index must
   * not reach the parsers with a length they refuse.
   */
  fun readIndex(csv: String, fileBytes: Long? = null): IndexReading {
    val entries = ArrayList<CaptureEntry>()
    val rejected = ArrayList<Int>()
    csv.lineSequence().forEachIndexed { index, line ->
      if (index == 0 || line.isBlank()) {
        return@forEachIndexed
      }
      val entry = indexLine(line, fileBytes)
      if (entry == null) rejected.add(index + 1) else entries.add(entry)
    }
    return IndexReading(entries, rejected)
  }

  /** The records of [readIndex] that fit; the rejected lines are left out */
  fun parseIndex(csv: String, fileBytes: Long? = null): List<CaptureEntry> = readIndex(csv, fileBytes).entries

  private fun indexLine(line: String, fileBytes: Long?): CaptureEntry? {
    val cells = line.split(',')
    if (cells.size < 5) {
      return null
    }
    val offset = cells[0].trim().toLongOrNull() ?: return null
    val length = cells[1].trim().toLongOrNull() ?: return null
    val direction = CaptureDirection.ofWord(cells[2].trim()) ?: return null
    val monotonic = cells[3].trim().toLongOrNull() ?: return null
    val wall = cells[4].trim().toLongOrNull() ?: return null
    if (offset < 0 || monotonic < 0 || length < 0 || (fileBytes != null && offset > fileBytes)) {
      return null
    }
    return when (direction) {
      CaptureDirection.GAP -> CaptureEntry(offset, 0, direction, monotonic, wall, skippedBytes = length)
      CaptureDirection.OPEN, CaptureDirection.CLOSE ->
        if (length == 0L) CaptureEntry(offset, 0, direction, monotonic, wall) else null
      CaptureDirection.IN, CaptureDirection.OUT -> when {
        length > CaptureRing.MAX_CAPACITY -> null
        fileBytes != null && offset + length > fileBytes -> null
        else -> CaptureEntry(offset, length.toInt(), direction, monotonic, wall)
      }
    }
  }

  fun replay(
    bytes: ByteArray,
    index: List<CaptureEntry>? = null,
    headerCrc: CrcParams = CrcSets.HEADER_CRC8,
    frameCrc: CrcParams = CrcSets.FRAME_CRC16,
    /** Each access unit as it is finished, with the detector of its stream and the description it completed */
    onVideoUnit: ((AccessUnit, CodecDetector, StreamDescription?, Long) -> Unit)? = null,
    /** Each control frame as it parsed */
    onControlFrame: ((P3Frame, Long) -> Unit)? = null,
    /** Called at each open and gap marker, after the parsers restarted */
    onNewStream: (() -> Unit)? = null,
  ): Result {
    val decoder = EnvelopeDecoder()
    val router = FrameRouter(headerCrc = headerCrc, frameCrc = frameCrc)
    router.onVideoUnit = onVideoUnit
    router.onControlFrame = onControlFrame
    var reads = 0
    var replayed = 0L
    var opens = 0
    var gaps = 0
    val inbound = index?.filter { it.direction == CaptureDirection.IN || it.direction.restartsStream }
      ?.takeIf { entries -> entries.any { it.direction == CaptureDirection.IN } }
    if (inbound.isNullOrEmpty()) {
      var at = 0
      while (at < bytes.size) {
        val length = minOf(AoaTransport.READ_SIZE, bytes.size - at)
        val nowMs = 0L
        for (envelope in decoder.offer(bytes, at, length)) {
          router.route(envelope, nowMs)
        }
        at += length
        reads += 1
        replayed += length
      }
    } else {
      for (entry in inbound) {
        if (entry.direction.restartsStream) {
          if (entry.direction == CaptureDirection.OPEN) opens += 1 else gaps += 1
          decoder.reset()
          router.restartStreams()
          onNewStream?.invoke()
          continue
        }
        val (from, length) = entry.rangeIn(bytes.size) ?: continue
        val nowMs = entry.monotonicNs / 1_000_000
        for (envelope in decoder.offer(bytes, from, length)) {
          router.route(envelope, nowMs, entry.monotonicNs)
        }
        reads += 1
        replayed += length
      }
    }
    return Result(
      readsReplayed = reads,
      bytesReplayed = replayed,
      envelopes = decoder.counters,
      router = router.counters,
      control = router.controlCounters(),
      channels = router.channelCounters(),
      pairs = router.pairCounters(),
      frames = router.frames(),
      telemetry = router.telemetry.messages(),
      video = router.video.channels(),
      probe = router.probe.report(),
      usedIndex = !inbound.isNullOrEmpty(),
      crc = router.crcReport(),
      opens = opens,
      gaps = gaps,
      assembler = router.assemblerCounters(),
      pendingVideoBytes = router.pendingVideoBytes(),
      telemetryValues = router.telemetryDecoder.values(lastMs(index)),
      requests = router.requestRows(),
      aircraftSeenMs = router.aircraftSeenMs,
      remoteSeenMs = router.remoteSeenMs,
    )
  }

  private fun lastMs(index: List<CaptureEntry>?): Long = (index?.lastOrNull()?.monotonicNs ?: 0L) / 1_000_000
}

/** An open and a gap both start a new stream in a replay: the bytes before them do not continue into the bytes after */
val CaptureDirection.restartsStream: Boolean get() = this == CaptureDirection.OPEN || this == CaptureDirection.GAP

/**
 * The part of a read that lies inside a file of [size] bytes, as an offset and a length the parsers accept, or null
 * when nothing of it does. An index checked by [CaptureReplay.readIndex] always fits; this is the second fence.
 */
fun CaptureEntry.rangeIn(size: Int): Pair<Int, Int>? {
  if (offset < 0 || offset >= size || length <= 0) {
    return null
  }
  val from = offset.toInt()
  return from to minOf(length, size - from)
}
