package app.alextran.immich.djilink

/**
 * Where a decoded envelope goes: by the role of its channel first, then, for a control frame, by its command set and
 * command id.
 *
 * The router counts and it dispatches. It cannot send: nothing here has a handle on the transport, so no path exists
 * from an arriving frame to a byte on the wire.
 *
 * Liveness: frames whose sender belongs to the aircraft side mark the aircraft as linked, with the exception of the
 * common set keep alive message, whose command id is not established (see [keepAliveCommandId]: null means no
 * exception is applied and the count of exceptions stays zero). After [AIRCRAFT_SILENCE_MS] without such a frame the
 * aircraft is considered lost. An acknowledgement is not an effect and a write is not a state: neither can reach here.
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
  val setName: String?,
  val messageName: String?,
  val count: Long,
  val lastLength: Int,
  val lastSeenMs: Long,
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
  /**
   * Device types of the header that belong to the aircraft side. A candidate set, written from the device type table
   * of the format notes; the radio type exists on both sides of the link, so a frame from it is counted as ambiguous
   * rather than attributed.
   */
  private val aircraftSenderTypes: Set<Int> = setOf(
    DeviceTypes.CAMERA,
    DeviceTypes.FLIGHT_CONTROLLER,
    DeviceTypes.GIMBAL,
    DeviceTypes.CENTRE_BOARD,
    8,
    DeviceTypes.BATTERY,
  ),
  private val controllerSenderTypes: Set<Int> = setOf(DeviceTypes.REMOTE_CONTROLLER, 13, 14, 16, DeviceTypes.GLASSES),
  /** Command id of the common set keep alive message, which does not prove an aircraft. Not established yet. */
  private val keepAliveCommandId: Int? = null,
  private val frameLines: Int = 200,
) {
  companion object {
    /** Without a frame from the aircraft side for this long, the aircraft is considered lost */
    const val AIRCRAFT_SILENCE_MS = 1_500L
  }

  val telemetry = TelemetryTable()
  val video = VideoFragments()
  val probe = VideoProbe()
  val cameraChannels = ChannelRoles()

  private val decoders = mutableMapOf<Int, P3Decoder>()
  private val channels = linkedMapOf<Int, ChannelCounters>()
  private val pairs = linkedMapOf<Int, PairCounters>()
  private val lines = ArrayDeque<FrameLine>()

  var counters = RouterCounters()
    private set
  var controllerSeenMs: Long? = null
    private set
  var aircraftSeenMs: Long? = null
    private set

  fun route(envelope: EnvelopeFrame, nowMs: Long) {
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
      }
      // A payload channel, a reserved channel and a channel nobody has described are all counted and kept. An
      // unknown channel is a value, never a failure, and never a reason to drop bytes silently.
      ChannelRole.PAYLOAD, ChannelRole.RESERVED, ChannelRole.UNKNOWN -> Unit
    }
  }

  private fun routeControl(envelope: EnvelopeFrame, nowMs: Long) {
    val decoder = decoders.getOrPut(envelope.channel) { P3Decoder() }
    for (frame in decoder.offer(envelope.payload)) {
      onControlFrame(envelope.channel, frame, nowMs)
    }
  }

  private fun onControlFrame(channel: Int, frame: P3Frame, nowMs: Long) {
    val key = (frame.commandSet shl 8) or frame.commandId
    val name = TelemetryNames.messageName(frame.commandSet, frame.commandId)
    val previous = pairs[key]
    pairs[key] = PairCounters(
      commandSet = frame.commandSet,
      commandId = frame.commandId,
      setName = TelemetryNames.commandSetName(frame.commandSet),
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
    telemetry.record(frame, nowMs)
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

  /** A new descriptor is a new stream: no decoder buffer and no counter survives a reconnect */
  fun reset() {
    decoders.clear()
    channels.clear()
    pairs.clear()
    lines.clear()
    telemetry.reset()
    video.reset()
    probe.reset()
    counters = RouterCounters()
    controllerSeenMs = null
    aircraftSeenMs = null
  }
}
