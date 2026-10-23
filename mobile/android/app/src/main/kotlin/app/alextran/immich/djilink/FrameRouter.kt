package app.alextran.immich.djilink

/**
 * Where a decoded envelope goes: by the role of its channel first, then, for a control frame, by its command set and
 * command id. A video payload goes to the fragment counters, the probe and the access unit assembler of its channel;
 * the finished units go to [onVideoUnit]. A control frame goes to the counters, the identifier table and the
 * telemetry decoder.
 *
 * The router counts and it dispatches. It cannot send: nothing here has a handle on the transport, so no path exists
 * from an arriving frame to a byte on the wire. Requests that ask for an answer are only counted, with their repeats.
 *
 * Liveness, by the sender classes the 23 October 2026 capture shows (p2/capture-2026-10-23.md, section 3.2): frames
 * from the aircraft side (camera, flight controller, gimbal, the air side transcoders and radio, battery, the 50 Hz
 * sender and the power module) mark the aircraft as present, with the exception of the common set keep alive message,
 * whose command id is not established (see [keepAliveCommandId]: null means no exception is applied). Frames from the
 * remote itself (type 6, every 540 ms in the capture) mark the remote as present. After [AIRCRAFT_SILENCE_MS] without
 * such a frame either one is considered gone. An acknowledgement is not an effect and a write is not a state: neither
 * can reach here.
 */
data class RouterCounters(
  val envelopes: Long = 0,
  val controlEnvelopes: Long = 0,
  val videoEnvelopes: Long = 0,
  val payloadEnvelopes: Long = 0,
  val reservedEnvelopes: Long = 0,
  val unknownChannelEnvelopes: Long = 0,
  val controlFrames: Long = 0,
  val knownPairs: Long = 0,
  val unknownPairs: Long = 0,
  val aircraftSideFrames: Long = 0,
  val controllerSideFrames: Long = 0,
  val ambiguousSideFrames: Long = 0,
  val keepAliveExceptions: Long = 0,
)

/** One channel as the page shows it */
data class ChannelCounters(
  val channel: Int,
  val role: ChannelRole,
  val envelopes: Long,
  val bytes: Long,
  val largestPayload: Int,
  val lastArrivalMs: Long,
  val firstArrivalMs: Long,
)

/** One (command set, command id) pair as the page shows it */
data class PairCounters(
  val commandSet: Int,
  val commandId: Int,
  /** Only from [MessageCatalogue], which names a message once a capture has shown what it carries */
  val messageName: String?,
  val count: Long,
  val lastLength: Int,
  val lastSeenMs: Long,
)

/**
 * The checksum parameters in use and the seeds the failures vote for. A candidate with many votes and no verified
 * frame is the sign of a product family whose seeds differ from the notes; a replay with that seed settles it.
 */
data class CrcReport(
  val headerParameters: String,
  val frameParameters: String,
  val headerSeedCandidate: Int?,
  val headerSeedVotes: Long,
  val headerFailuresVoting: Long,
  val frameSeedCandidate: Int?,
  val frameSeedVotes: Long,
  val frameFailuresVoting: Long,
)

/** Requests of one sender and pair that ask for an acknowledgement, which nothing here ever gives */
data class RequestRow(
  val senderType: Int,
  val senderIndex: Int,
  val commandSet: Int,
  val commandId: Int,
  /** 1 or 2, as the frame says */
  val ackPolicy: Int,
  val count: Long,
  /** The same sender, pair and sequence number again: the request resent because nobody answered */
  val repeats: Long,
)

/** One parsed frame as the frame list shows it, newest first, bounded */
data class FrameLine(
  val atMs: Long,
  val channel: Int,
  val commandSet: Int,
  val commandId: Int,
  val isAcknowledgement: Boolean,
  val ackPolicy: Int,
  val senderType: Int,
  val receiverType: Int,
  val sequence: Int,
  val length: Int,
  val encryption: Int,
  val preview: String,
)

class FrameRouter(
  /** Device types of the header seen on the aircraft side of the 23 October 2026 capture */
  private val aircraftSenderTypes: Set<Int> = AIRCRAFT_SIDE,
  /** Device types seen on the remote side of the same capture (14.0 relays the flight data) */
  private val controllerSenderTypes: Set<Int> = REMOTE_SIDE,
  /** Command id of the common set keep alive message, which does not prove an aircraft. Not established yet. */
  private val keepAliveCommandId: Int? = null,
  private val frameLines: Int = 200,
  /** Checksum parameters of every control channel decoder; the notes' set unless a replay asks for another */
  private val headerCrc: CrcParams = CrcSets.HEADER_CRC8,
  private val frameCrc: CrcParams = CrcSets.FRAME_CRC16,
) {
  companion object {
    /** Without a frame from the aircraft side for this long, the aircraft is considered lost; the remote likewise */
    const val AIRCRAFT_SILENCE_MS = 1_500L

    /**
     * The aircraft side of the 23 October 2026 capture: camera 1, flight controller 3, gimbal 4, the air side
     * transcoders 8, the air side radio 9, battery 11, the 50 Hz sender 18 and the power module 29
     */
    val AIRCRAFT_SIDE: Set<Int> = setOf(1, 3, 4, 8, 9, 11, 18, 29)

    /** The remote side of the same capture: the remote 6, the ground side transcoder 13 and radio 14 */
    val REMOTE_SIDE: Set<Int> = setOf(DeviceTypes.REMOTE_CONTROLLER, 13, 14)

    /** Sequence numbers kept per sender and pair to recognise a resent request */
    private const val REQUEST_SEQUENCES_KEPT = 16
  }

  val telemetry = TelemetryTable()
  val telemetryDecoder = TelemetryDecoder()
  val video = VideoFragments()
  val probe = VideoProbe()
  val cameraChannels = ChannelRoles()

  /** Where the finished access units go, with the detector of their stream and the description a unit completed */
  var onVideoUnit: ((unit: AccessUnit, detector: CodecDetector, fresh: StreamDescription?, nowNs: Long) -> Unit)? = null

  /** Every control frame as it parsed, for a replay that wants to look at them */
  var onControlFrame: ((frame: P3Frame, nowMs: Long) -> Unit)? = null

  private val decoders = mutableMapOf<Int, P3Decoder>()
  private val assemblers = linkedMapOf<Int, AccessUnitAssembler>()
  private val channels = linkedMapOf<Int, ChannelCounters>()
  private val pairs = linkedMapOf<Int, PairCounters>()
  private val lines = ArrayDeque<FrameLine>()

  private class RequestTally(var count: Long = 0, var repeats: Long = 0, val sequences: LinkedHashSet<Int> = LinkedHashSet())

  private val requests = linkedMapOf<Long, RequestTally>()

  var counters = RouterCounters()
    private set
  var controllerSeenMs: Long? = null
    private set
  var aircraftSeenMs: Long? = null
    private set

  /** The last frame from the remote itself (type 6) */
  var remoteSeenMs: Long? = null
    private set

  fun route(envelope: EnvelopeFrame, nowMs: Long, nowNs: Long = nowMs * 1_000_000) {
    val role = Channels.role(envelope.channel)
    val previous = channels[envelope.channel]
    channels[envelope.channel] = ChannelCounters(
      channel = envelope.channel,
      role = role,
      envelopes = (previous?.envelopes ?: 0) + 1,
      bytes = (previous?.bytes ?: 0) + envelope.payload.size,
      largestPayload = maxOf(previous?.largestPayload ?: 0, envelope.payload.size),
      lastArrivalMs = nowMs,
      firstArrivalMs = previous?.firstArrivalMs ?: nowMs,
    )
    counters = counters.copy(
      envelopes = counters.envelopes + 1,
      controlEnvelopes = counters.controlEnvelopes + if (role == ChannelRole.CONTROL) 1 else 0,
      videoEnvelopes = counters.videoEnvelopes + if (role == ChannelRole.VIDEO) 1 else 0,
      payloadEnvelopes = counters.payloadEnvelopes + if (role == ChannelRole.PAYLOAD) 1 else 0,
      reservedEnvelopes = counters.reservedEnvelopes + if (role == ChannelRole.RESERVED) 1 else 0,
      unknownChannelEnvelopes = counters.unknownChannelEnvelopes + if (role == ChannelRole.UNKNOWN) 1 else 0,
    )
    when (role) {
      ChannelRole.CONTROL -> routeControl(envelope, nowMs)
      ChannelRole.VIDEO -> {
        video.record(envelope.channel, envelope.payload, nowMs)
        probe.offer(envelope.payload)
        val assembler = assemblers.getOrPut(envelope.channel) { AccessUnitAssembler(channel = envelope.channel) }
        for (unit in assembler.offer(envelope.payload, nowNs)) {
          val fresh = probe.detector.offer(unit)
          onVideoUnit?.invoke(unit, probe.detector, fresh, nowNs)
        }
      }
      // A payload channel, a reserved channel and a channel nobody has described are all counted and kept. An
      // unknown channel is a value, never a failure, and never a reason to drop bytes silently.
      ChannelRole.PAYLOAD, ChannelRole.RESERVED, ChannelRole.UNKNOWN -> Unit
    }
  }

  private fun routeControl(envelope: EnvelopeFrame, nowMs: Long) {
    val decoder = decoders.getOrPut(envelope.channel) { P3Decoder(headerCrc, frameCrc) }
    for (frame in decoder.offer(envelope.payload)) {
      onControlFrame(envelope.channel, frame, nowMs)
    }
  }

  private fun onControlFrame(channel: Int, frame: P3Frame, nowMs: Long) {
    val key = (frame.commandSet shl 8) or frame.commandId
    val name = MessageCatalogue.named(frame.commandSet, frame.commandId)?.name
    val previous = pairs[key]
    pairs[key] = PairCounters(
      commandSet = frame.commandSet,
      commandId = frame.commandId,
      messageName = name,
      count = (previous?.count ?: 0) + 1,
      lastLength = frame.body.size,
      lastSeenMs = nowMs,
    )
    val known = name != null
    val fromAircraft = frame.senderType in aircraftSenderTypes
    val fromController = frame.senderType in controllerSenderTypes
    val keepAlive = keepAliveCommandId != null &&
      frame.commandSet == CommandSets.COMMON &&
      frame.commandId == keepAliveCommandId
    counters = counters.copy(
      controlFrames = counters.controlFrames + 1,
      knownPairs = counters.knownPairs + if (known) 1 else 0,
      unknownPairs = counters.unknownPairs + if (known) 0 else 1,
      aircraftSideFrames = counters.aircraftSideFrames + if (fromAircraft) 1 else 0,
      controllerSideFrames = counters.controllerSideFrames + if (fromController) 1 else 0,
      ambiguousSideFrames = counters.ambiguousSideFrames + if (!fromAircraft && !fromController) 1 else 0,
      keepAliveExceptions = counters.keepAliveExceptions + if (keepAlive) 1 else 0,
    )
    if (fromController || fromAircraft) {
      controllerSeenMs = nowMs
    }
    if (fromAircraft && !keepAlive) {
      aircraftSeenMs = nowMs
    }
    if (frame.senderType == DeviceTypes.REMOTE_CONTROLLER) {
      remoteSeenMs = nowMs
    }
    if (!frame.isAcknowledgement && frame.ackPolicy != 0) {
      countRequest(frame)
    }
    telemetry.record(frame, nowMs)
    telemetryDecoder.offer(frame, nowMs)
    onControlFrame?.invoke(frame, nowMs)
    lines.addLast(
      FrameLine(
        atMs = nowMs,
        channel = channel,
        commandSet = frame.commandSet,
        commandId = frame.commandId,
        isAcknowledgement = frame.isAcknowledgement,
        ackPolicy = frame.ackPolicy,
        senderType = frame.senderType,
        receiverType = frame.receiverType,
        sequence = frame.sequence,
        length = frame.body.size,
        encryption = frame.encryption,
        preview = if (frame.encryptionUnsupported) "" else TelemetryTable.hex(frame.body, 16),
      )
    )
    while (lines.size > frameLines) {
      lines.removeFirst()
    }
  }

  /** True while a frame from the aircraft side arrived less than [AIRCRAFT_SILENCE_MS] ago */
  fun aircraftLinked(nowMs: Long): Boolean {
    val seen = aircraftSeenMs ?: return false
    return nowMs - seen < AIRCRAFT_SILENCE_MS
  }

  /** True while a frame from the remote itself arrived less than [AIRCRAFT_SILENCE_MS] ago */
  fun remotePresent(nowMs: Long): Boolean {
    val seen = remoteSeenMs ?: return false
    return nowMs - seen < AIRCRAFT_SILENCE_MS
  }

  private fun countRequest(frame: P3Frame) {
    val key = (frame.ackPolicy.toLong() shl 32) or
      ((frame.senderIndex.toLong() and 0x07) shl 24) or
      ((frame.senderType.toLong() and 0x1F) shl 16) or
      ((frame.commandSet.toLong() and 0xFF) shl 8) or
      (frame.commandId.toLong() and 0xFF)
    val tally = requests.getOrPut(key) { RequestTally() }
    tally.count += 1
    if (!tally.sequences.add(frame.sequence)) {
      tally.repeats += 1
    }
    while (tally.sequences.size > REQUEST_SEQUENCES_KEPT) {
      tally.sequences.remove(tally.sequences.first())
    }
  }

  /** Requests left unanswered, per sender, pair and policy */
  fun requestRows(): List<RequestRow> = requests.map { (key, tally) ->
    RequestRow(
      senderType = ((key ushr 16) and 0x1F).toInt(),
      senderIndex = ((key ushr 24) and 0x07).toInt(),
      commandSet = ((key ushr 8) and 0xFF).toInt(),
      commandId = (key and 0xFF).toInt(),
      ackPolicy = (key ushr 32).toInt(),
      count = tally.count,
      repeats = tally.repeats,
    )
  }.sortedWith(compareBy({ it.ackPolicy }, { it.senderType }, { it.commandSet }, { it.commandId }))

  /** The assembler counters of every video channel, summed */
  fun assemblerCounters(): AssemblerCounters = assemblers.values.fold(AssemblerCounters()) { total, assembler ->
    val counters = assembler.counters
    AssemblerCounters(
      fragments = total.fragments + counters.fragments,
      bytes = total.bytes + counters.bytes,
      largestFragment = maxOf(total.largestFragment, counters.largestFragment),
      units = total.units + counters.units,
      closedByBoundary = total.closedByBoundary + counters.closedByBoundary,
      closedByShortFragment = total.closedByShortFragment + counters.closedByShortFragment,
      bytesBeforeFirstUnit = total.bytesBeforeFirstUnit + counters.bytesBeforeFirstUnit,
      unitsTooLarge = total.unitsTooLarge + counters.unitsTooLarge,
      bytesDroppedTooLarge = total.bytesDroppedTooLarge + counters.bytesDroppedTooLarge,
      bytesDroppedAtReset = total.bytesDroppedAtReset + counters.bytesDroppedAtReset,
    )
  }

  /** Bytes of unfinished units, which a pulled cable leaves behind */
  fun pendingVideoBytes(): Int = assemblers.values.sumOf { it.pendingBytes }

  fun channelCounters(): List<ChannelCounters> = channels.values.sortedBy { it.channel }

  fun pairCounters(): List<PairCounters> = pairs.values.sortedWith(compareBy({ it.commandSet }, { it.commandId }))

  /** Newest first, bounded */
  fun frames(): List<FrameLine> = lines.reversed()

  /** Decoder counters of every control channel, summed: the page shows one set of numbers */
  fun controlCounters(): P3Counters = decoders.values.fold(P3Counters()) { total, decoder ->
    val counters = decoder.counters
    P3Counters(
      frames = total.frames + counters.frames,
      frameBytes = total.frameBytes + counters.frameBytes,
      headerCrcFailures = total.headerCrcFailures + counters.headerCrcFailures,
      frameCrcFailures = total.frameCrcFailures + counters.frameCrcFailures,
      lengthRejections = total.lengthRejections + counters.lengthRejections,
      discardedBytes = total.discardedBytes + counters.discardedBytes,
      resynchronisations = total.resynchronisations + counters.resynchronisations,
      unsupportedEncryption = total.unsupportedEncryption + counters.unsupportedEncryption,
    )
  }

  /** The seeds the checksum failures of every control channel vote for */
  fun crcReport(): CrcReport {
    val headers = SeedTally()
    val frames = SeedTally()
    for (decoder in decoders.values) {
      headers.add(decoder.headerSeeds)
      frames.add(decoder.frameSeeds)
    }
    val header = headers.top()
    val frame = frames.top()
    return CrcReport(
      headerParameters = headerCrc.label,
      frameParameters = frameCrc.label,
      headerSeedCandidate = header?.first,
      headerSeedVotes = header?.second ?: 0,
      headerFailuresVoting = headers.total,
      frameSeedCandidate = frame?.first,
      frameSeedVotes = frame?.second ?: 0,
      frameFailuresVoting = frames.total,
    )
  }

  /**
   * A new descriptor is a new stream: no parser buffer survives it, and the aircraft has to show itself again. The
   * counters stay, so that they cover the whole page session as the capture does.
   */
  fun restartStreams() {
    decoders.values.forEach { it.reset() }
    assemblers.values.forEach { it.reset() }
    probe.detector.newStream()
    telemetryDecoder.newStream()
    controllerSeenMs = null
    aircraftSeenMs = null
    remoteSeenMs = null
  }

  /** A new page session: nothing survives */
  fun reset() {
    decoders.clear()
    assemblers.clear()
    channels.clear()
    pairs.clear()
    lines.clear()
    requests.clear()
    telemetry.reset()
    telemetryDecoder.reset()
    video.reset()
    probe.reset()
    counters = RouterCounters()
    controllerSeenMs = null
    aircraftSeenMs = null
    remoteSeenMs = null
  }
}
