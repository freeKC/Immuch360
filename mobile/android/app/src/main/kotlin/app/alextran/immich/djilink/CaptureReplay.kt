package app.alextran.immich.djilink

/**
 * A saved capture fed back through the same codecs, with no hardware.
 *
 * This is what makes the parser answerable: a session recorded once on a cable can be replayed on a phone, on an
 * emulator or in a unit test, and it goes through the very decoders the live path uses. The index says which bytes
 * came in and when, so the inbound stream is replayed on its own; without an index every byte is treated as inbound,
 * which the caller is told.
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
      val length = cells[1].trim().toIntOrNull() ?: return@mapNotNull null
      val direction = when (cells[2].trim()) {
        "in" -> CaptureDirection.IN
        "out" -> CaptureDirection.OUT
        else -> return@mapNotNull null
      }
      val monotonic = cells[3].trim().toLongOrNull() ?: return@mapNotNull null
      val wall = cells[4].trim().toLongOrNull() ?: return@mapNotNull null
      CaptureEntry(offset, length, direction, monotonic, wall)
    }
    .toList()

  fun replay(bytes: ByteArray, index: List<CaptureEntry>? = null): Result {
    val decoder = EnvelopeDecoder()
    val router = FrameRouter()
    var reads = 0
    var replayed = 0L
    val inbound = index?.filter { it.direction == CaptureDirection.IN }
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
        val from = entry.offset.toInt()
        if (from < 0 || from >= bytes.size) {
          continue
        }
        val length = minOf(entry.length, bytes.size - from)
        val nowMs = entry.monotonicNs / 1_000_000
        for (envelope in decoder.offer(bytes, from, length)) {
          router.route(envelope, nowMs)
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
    )
  }
}
