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

  /** Reads an index written by [CaptureSnapshot.indexCsv]; a line that does not parse is skipped */
  fun parseIndex(csv: String): List<CaptureEntry> = csv.lineSequence()
    .drop(1)
    .mapNotNull { line ->
      val cells = line.split(',')
      if (cells.size < 5) {
        return@mapNotNull null
      }
      val offset = cells[0].trim().toLongOrNull() ?: return@mapNotNull null
      val length = cells[1].trim().toLongOrNull() ?: return@mapNotNull null
      val direction = CaptureDirection.ofWord(cells[2].trim()) ?: return@mapNotNull null
      val monotonic = cells[3].trim().toLongOrNull() ?: return@mapNotNull null
      val wall = cells[4].trim().toLongOrNull() ?: return@mapNotNull null
      if (direction == CaptureDirection.GAP) {
        CaptureEntry(offset, 0, direction, monotonic, wall, skippedBytes = length)
      } else {
        CaptureEntry(offset, length.toInt(), direction, monotonic, wall)
      }
    }
    .toList()

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
        val from = entry.offset.toInt()
        if (from < 0 || from >= bytes.size) {
          continue
        }
        val length = minOf(entry.length, bytes.size - from)
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
