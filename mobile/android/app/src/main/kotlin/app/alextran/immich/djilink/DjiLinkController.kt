package app.alextran.immich.djilink

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import io.flutter.plugin.common.BinaryMessenger

/**
 * One owner for the whole link, for the lifetime of the process.
 *
 * It holds the accessory manager, the envelope decoder, the frame router, the capture ring, the stick source and the
 * safety rules, and it is the only place that turns all of that into the one answer the page shows. There is no
 * foreground service: the link belongs to the page that is in front of the pilot, and a later stage that has to keep
 * it alive outside the page is the stage that will add one.
 *
 * Nothing here can send a flight command. The only write is the one byte liveness probe of the transport, which is
 * counted on the page, and the send path of the later stages is behind [DjiLinkBuild.SEND_ENABLED], which is false.
 */
class DjiLinkController private constructor(private val context: Context) : LinkEvents {
  companion object {
    private const val TAG = "DjiLinkController"

    /** At most one event to Flutter this often; the page also asks for a snapshot when it opens */
    private const val PUBLISH_INTERVAL_MS = 250L

    @Volatile
    private var instance: DjiLinkController? = null

    fun of(context: Context): DjiLinkController =
      instance ?: synchronized(this) {
        instance ?: DjiLinkController(context.applicationContext).also { instance = it }
      }

    /** The controller if the page ever made one, never creating it: a motion event or a plug must not allocate */
    fun existing(): DjiLinkController? = instance

    private var events: DjiLinkEvents? = null

    fun attachEvents(messenger: BinaryMessenger) {
      events = DjiLinkEvents(messenger)
    }

    fun detachEvents() {
      events = null
    }
  }

  private val handler = Handler(Looper.getMainLooper())

  /**
   * The reader thread fills the decoder, the router and the capture while the main thread builds the answer the page
   * shows. One lock around both sides, because a table being sorted while a frame is counted into it is how a
   * diagnostics page crashes in front of a pilot.
   */
  private val gate = Any()
  private val profiles = ProfileRegistry()
  private val decoder = EnvelopeDecoder()
  private val router = FrameRouter()
  private val capture = CaptureRing(monotonicNs = { SystemClock.elapsedRealtimeNanos() })
  private val sticks = GamepadStickSource()
  private val safety = InputSafety()
  private val manager = AoaAccessoryManager(context, this, profiles, handler)

  private var environment: UsbEnvironmentReport = UsbEnvironment.read(context)
  private var state: LinkState = LinkState.ABSENT
  private var reason: LinkReason = LinkReason.LOOKING

  /** One technical word that goes with [reason], such as the name of an exception */
  private var argument: String? = null
  private var identity: AccessoryIdentity? = null
  private var profile: DeviceProfile? = null
  private var started = false
  private var dirty = false
  private var lastPublishMs = 0L
  private var lastDecisionReasons: Set<DeadManSignal> = emptySet()
  private var lastDecisionArmed = false

  private val publish = Runnable { publishNow() }

  fun readEnvironment(): UsbEnvironmentReport {
    environment = UsbEnvironment.read(context)
    return environment
  }

  /** Whether the page is open and the link is being looked after */
  val isStarted: Boolean get() = started

  fun start() {
    if (started) {
      return
    }
    started = true
    environment = UsbEnvironment.read(context)
    // A new page session: the counters start again; within the session they cover every descriptor
    synchronized(gate) {
      decoder.reset()
      decoder.clearCounters()
      router.reset()
    }
    manager.start()
    markDirty()
  }

  fun stop() {
    if (!started) {
      return
    }
    started = false
    manager.stop()
    capture.stop()
    markDirty()
  }

  fun retry() {
    if (!started) {
      start()
      return
    }
    manager.retryNow()
  }

  /** The pilot picked this application in the system chooser of a plug; nothing happens unless the page is open */
  fun onAttachEntry() {
    if (started) {
      manager.onAttachEntry()
    }
  }

  fun startCapture() {
    capture.start()
    markDirty()
  }

  fun stopCapture() {
    capture.stop()
    markDirty()
  }

  fun clearCapture() {
    synchronized(gate) { capture.clear() }
    markDirty()
  }

  fun exportCapture(notes: Map<String, String?>): CaptureExport.Result {
    val snapshot: CaptureSnapshot
    val facts: Map<String, Any?>
    synchronized(gate) {
      snapshot = capture.snapshot()
      facts = linkFacts()
    }
    val result = CaptureExport.write(
      context = context,
      snapshot = snapshot,
      environment = environment,
      identity = identity,
      profile = profile,
      link = facts,
      notes = notes,
    )
    Log.i(TAG, "capture exported: ok=${result.ok} bytes=${result.bytes} sha256=${result.sha256}")
    return result
  }

  /**
   * A saved capture back through the same codecs. No hardware is touched and the live counters are left alone. A seed
   * other than the notes' can be given for either checksum, typically the candidate the live page voted for.
   */
  fun replay(path: String, headerSeed: Int? = null, frameSeed: Int? = null): CaptureReplay.Result =
    CaptureReplay.replay(
      bytes = java.io.File(path).readBytes(),
      index = runCatching { CaptureReplay.parseIndex(java.io.File(indexPathOf(path)).readText()) }.getOrNull(),
      headerCrc = headerSeed?.let { CrcSets.header(it) } ?: CrcSets.HEADER_CRC8,
      frameCrc = frameSeed?.let { CrcSets.frame(it) } ?: CrcSets.FRAME_CRC16,
    )

  fun indexPathOf(binPath: String): String = binPath.removeSuffix(".bin") + ".idx.csv"

  /**
   * A gamepad moved. Stage 1 only draws it: no sample ever leaves this process, whatever the sticks say, and the
   * safety rules are evaluated anyway so that they are exercised long before anything could be sent.
   */
  fun onMotionEvent(event: MotionEvent): Boolean {
    if (!started) {
      return false
    }
    val source = event.source
    val fromGamepad = (source and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK ||
      (source and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD
    if (!fromGamepad || event.action != MotionEvent.ACTION_MOVE) {
      return false
    }
    val nowMs = SystemClock.elapsedRealtime()
    val triggers = event.getAxisValue(MotionEvent.AXIS_LTRIGGER) > 0.5f &&
      event.getAxisValue(MotionEvent.AXIS_RTRIGGER) > 0.5f
    val sample = sticks.offer(
      leftHorizontal = event.getAxisValue(MotionEvent.AXIS_X).toDouble(),
      // Up is positive here; the device reports up as a negative value
      leftVertical = -event.getAxisValue(MotionEvent.AXIS_Y).toDouble(),
      rightHorizontal = event.getAxisValue(MotionEvent.AXIS_Z).toDouble(),
      rightVertical = -event.getAxisValue(MotionEvent.AXIS_RZ).toDouble(),
      triggersHeld = triggers,
      nowMs = nowMs,
    )
    evaluateSafety(sample, nowMs)
    markDirty()
    return false
  }

  private fun evaluateSafety(sample: StickSample?, nowMs: Long) {
    val signals = mutableSetOf<DeadManSignal>()
    if (!router.aircraftLinked(nowMs)) {
      signals.add(DeadManSignal.LINK_NOT_LINKED)
    }
    if (manager.consecutiveProbeFailures > 0) {
      signals.add(DeadManSignal.WRITE_BLOCKED)
    }
    val decision = safety.evaluate(sample, signals, nowMs)
    lastDecisionReasons = decision.reasons
    lastDecisionArmed = decision.armed
  }

  override fun onState(state: LinkState, reason: LinkReason, argument: String?) {
    this.state = state
    this.reason = reason
    this.argument = argument
    markDirty()
  }

  /**
   * A new descriptor is a new stream: no parser buffer survives it, and the capture marks where it started. Called
   * before the reader thread exists, so the first byte of the remote is counted in full.
   */
  override fun onOpened() {
    synchronized(gate) {
      decoder.reset()
      router.restartStreams()
      capture.mark(CaptureDirection.OPEN)
    }
    markDirty()
  }

  override fun onClosed(reason: LinkReason) {
    synchronized(gate) { capture.mark(CaptureDirection.CLOSE) }
    markDirty()
  }

  override fun onIdentity(identity: AccessoryIdentity?, profile: DeviceProfile?) {
    this.identity = identity
    this.profile = profile
    markDirty()
  }

  override fun onBytes(data: ByteArray, length: Int) {
    val nowMs = SystemClock.elapsedRealtime()
    val frames: Long
    val linked: Boolean
    synchronized(gate) {
      capture.record(CaptureDirection.IN, data, 0, length)
      for (envelope in decoder.offer(data, 0, length)) {
        router.route(envelope, nowMs)
      }
      frames = router.counters.controlFrames
      linked = router.aircraftLinked(nowMs)
    }
    // Frames parsed is a claim the transport cannot make, so it is made here and nowhere else
    if (frames > 0 && state == LinkState.LINK_USABLE) {
      handler.post { manager.publish(LinkState.CONTROLLER_IDENTIFIED, LinkReason.FRAMES_PARSE) }
    }
    if (linked && state == LinkState.CONTROLLER_IDENTIFIED) {
      handler.post { manager.publish(LinkState.AIRCRAFT_LINKED, LinkReason.AIRCRAFT_FRAMES) }
    }
    markDirty()
  }

  override fun onWrite(data: ByteArray, isProbe: Boolean) {
    synchronized(gate) { capture.record(CaptureDirection.OUT, data) }
    markDirty()
  }

  override fun onProbe(result: ProbeResult) {
    markDirty()
  }

  private fun markDirty() {
    dirty = true
    val now = SystemClock.elapsedRealtime()
    val wait = (lastPublishMs + PUBLISH_INTERVAL_MS - now).coerceAtLeast(0)
    handler.removeCallbacks(publish)
    handler.postDelayed(publish, wait)
  }

  private fun publishNow() {
    if (!dirty) {
      return
    }
    dirty = false
    lastPublishMs = SystemClock.elapsedRealtime()
    val api = events ?: return
    runCatching { api.snapshotChanged(snapshot()) { } }
  }

  /** The counters as the exported header holds them */
  private fun linkFacts(): Map<String, Any?> {
    val envelope = decoder.counters
    val control = router.controlCounters()
    val routed = router.counters
    val crc = router.crcReport()
    return linkedMapOf(
      "state" to state.name,
      "reason" to reason.name,
      "reasonArgument" to argument,
      "attempts" to manager.attempts,
      "opens" to manager.opens,
      "openedAtWallMs" to manager.openedAtMs,
      "firstByteMs" to manager.firstByteMs,
      "probesSent" to manager.probesSent,
      "probeFailures" to manager.probeFailures,
      "lastProbeCallMs" to manager.lastProbeCallMs,
      "probesHalted" to manager.probesHalted,
      "quietWindowMs" to AoaAccessoryManager.QUIET_AFTER_OPEN_MS,
      "sendRefusals" to (manager.transport?.sendRefusals ?: 0),
      "bytesRead" to (manager.transport?.bytesRead ?: 0),
      "bytesWritten" to (manager.transport?.bytesWritten ?: 0),
      "reads" to (manager.transport?.reads ?: 0),
      "writes" to (manager.transport?.writes ?: 0),
      "envelopeFrames" to envelope.frames,
      "envelopeBytes" to envelope.frameBytes,
      "envelopeDiscardedBytes" to envelope.discardedBytes,
      "envelopeResynchronisations" to envelope.resynchronisations,
      "envelopeUnknownChannelFrames" to envelope.unknownChannelFrames,
      "envelopeUnknownChannelRejections" to envelope.unknownChannelRejections,
      "envelopeOversizeRejections" to envelope.oversizeRejections,
      "envelopeIncompleteTimeouts" to envelope.incompleteTimeouts,
      "controlFrames" to control.frames,
      "headerCrcFailures" to control.headerCrcFailures,
      "frameCrcFailures" to control.frameCrcFailures,
      "unsupportedEncryption" to control.unsupportedEncryption,
      "unknownPairs" to routed.unknownPairs,
      "aircraftSideFrames" to routed.aircraftSideFrames,
      "controllerSideFrames" to routed.controllerSideFrames,
      "channelsSeen" to router.channelCounters().joinToString(" ") { "${it.channel}:${it.envelopes}" },
      "crcParameters" to "${crc.headerParameters} ${crc.frameParameters}",
      "headerSeedCandidate" to crc.headerSeedCandidate?.let { "0x%02x".format(it) },
      "headerSeedVotes" to "${crc.headerSeedVotes} of ${crc.headerFailuresVoting}",
      "frameSeedCandidate" to crc.frameSeedCandidate?.let { "0x%04x".format(it) },
      "frameSeedVotes" to "${crc.frameSeedVotes} of ${crc.frameFailuresVoting}",
    )
  }

  fun environmentPigeon(): DjiLinkEnvironment = environment.let {
    DjiLinkEnvironment(
      deviceManufacturer = it.deviceManufacturer,
      deviceModel = it.deviceModel,
      buildFingerprint = it.buildFingerprint,
      androidRelease = it.androidRelease,
      sdkInt = it.sdkInt.toLong(),
      appVersion = it.appVersion,
      flavour = it.flavour,
      hasAccessoryFeature = it.hasAccessoryFeature,
      hasHostFeature = it.hasHostFeature,
      accessoryNodeExists = it.accessoryNodeExists,
      accessoryNodeWritable = it.accessoryNodeWritable,
      futureUsbLibraryPresent = it.futureUsbLibraryPresent,
      adbEnabled = it.adbEnabled,
      usbStateKnown = it.usbStateKnown,
      usbConnected = it.usbConnected,
      usbConfigured = it.usbConfigured,
      usbAccessoryMode = it.usbAccessoryMode,
      usbAdbFunction = it.usbAdbFunction,
      djiApplicationInstalled = it.djiApplicationInstalled,
      accessoriesListed = it.accessoriesListed.toLong(),
      transportPossible = it.transportPossible,
      chargeCurrentMicroAmps = it.chargeCurrentMicroAmps?.toLong(),
    )
  }

  fun snapshot(): DjiLinkSnapshot = synchronized(gate) { buildSnapshot() }

  private fun buildSnapshot(): DjiLinkSnapshot {
    val nowMs = SystemClock.elapsedRealtime()
    val envelope = decoder.counters
    val control = router.controlCounters()
    val routed = router.counters
    val probeReport = router.probe.report()
    val latest = sticks.latest()
    return DjiLinkSnapshot(
      state = state.toPigeon(),
      reason = reason.toPigeon(),
      detail = argument,
      accessory = identity?.let {
        DjiLinkAccessory(
          manufacturer = it.manufacturer,
          model = it.model,
          description = it.description,
          version = it.version,
          serial = it.serial,
        )
      },
      profile = profile?.let { known ->
        DjiLinkProfile(
          id = known.id,
          label = known.label,
          note = known.note,
          capabilities = Capability.entries.map { capability ->
            val state = known.capabilities[capability] ?: CapabilityState.unknown
            DjiLinkCapability(
              name = capability.name,
              support = when (state.support) {
                Support.UNKNOWN -> DjiLinkSupport.UNKNOWN
                Support.UNSUPPORTED -> DjiLinkSupport.UNSUPPORTED
                Support.SUPPORTED -> DjiLinkSupport.SUPPORTED
              },
              provenance = state.provenance?.let { "${it.observationId} (${it.date})" },
            )
          },
        )
      },
      firstByteMs = manager.firstByteMs,
      openSinceMs = manager.openedAtMs?.let { System.currentTimeMillis() - it },
      probesSent = manager.probesSent,
      probeFailures = manager.probeFailures,
      consecutiveProbeFailures = manager.consecutiveProbeFailures.toLong(),
      lastProbeCallMs = manager.lastProbeCallMs,
      probesHalted = manager.probesHalted,
      opens = manager.opens,
      bytesRead = manager.transport?.bytesRead ?: 0,
      bytesWritten = manager.transport?.bytesWritten ?: 0,
      reads = manager.transport?.reads ?: 0,
      writes = manager.transport?.writes ?: 0,
      attempts = manager.attempts,
      quietWindowMs = AoaAccessoryManager.QUIET_AFTER_OPEN_MS,
      aircraftLinked = router.aircraftLinked(nowMs),
      chargeCurrentMicroAmps = environment.chargeCurrentMicroAmps?.toLong(),
      counters = DjiLinkCounters(
        envelopeFrames = envelope.frames,
        envelopeBytes = envelope.frameBytes,
        payloadBytes = envelope.payloadBytes,
        discardedBytes = envelope.discardedBytes + control.discardedBytes,
        resynchronisations = envelope.resynchronisations + control.resynchronisations,
        unknownChannelFrames = envelope.unknownChannelFrames,
        unknownChannelRejections = envelope.unknownChannelRejections,
        oversizeRejections = envelope.oversizeRejections,
        incompleteTimeouts = envelope.incompleteTimeouts,
        controlFrames = control.frames,
        headerCrcFailures = control.headerCrcFailures,
        frameCrcFailures = control.frameCrcFailures,
        lengthRejections = control.lengthRejections,
        unsupportedEncryption = control.unsupportedEncryption,
        knownPairs = routed.knownPairs,
        unknownPairs = routed.unknownPairs,
        aircraftSideFrames = routed.aircraftSideFrames,
        controllerSideFrames = routed.controllerSideFrames,
        ambiguousSideFrames = routed.ambiguousSideFrames,
        keepAliveExceptions = routed.keepAliveExceptions,
      ),
      crc = router.crcReport().toPigeon(),
      channels = router.channelCounters().map { it.toPigeon(router.cameraChannels.cameraOfChannel(it.channel)) },
      pairs = router.pairCounters().map { it.toPigeon() },
      frames = router.frames().map { it.toPigeon() },
      telemetry = router.telemetry.messages().map { it.toPigeon() },
      video = DjiLinkVideo(
        verdict = when (probeReport.verdict) {
          ProbeVerdict.NO_DATA -> DjiLinkProbeVerdict.NO_DATA
          ProbeVerdict.NO_START_CODES -> DjiLinkProbeVerdict.NO_START_CODES
          ProbeVerdict.START_CODES_SEEN -> DjiLinkProbeVerdict.START_CODES_SEEN
        },
        payloads = probeReport.payloads,
        payloadsStartingWithStartCode = probeReport.payloadsStartingWithStartCode,
        startCodesSeen = probeReport.startCodesSeen,
        unitTypes = probeReport.unitTypes.entries.joinToString(" ") { "${it.key}:${it.value}" },
        sawH264ParameterSets = probeReport.sawH264ParameterSets,
        sawH265ParameterSets = probeReport.sawH265ParameterSets,
        channels = router.video.channels().map {
          DjiLinkVideoChannel(
            channel = it.channel.toLong(),
            fragments = it.fragments,
            bytes = it.bytes,
            largestFragment = it.largestFragment.toLong(),
            gaps = it.gaps,
            longestGapMs = it.longestGapMs,
          )
        },
      ),
      capture = DjiLinkCapture(
        recording = capture.recording,
        totalBytes = capture.totalBytes,
        droppedBytes = capture.droppedBytes,
        records = capture.records.toLong(),
        capacityBytes = capture.capacityOfRing.toLong(),
      ),
      sticks = DjiLinkSticks(
        kind = sticks.kind,
        throttle = latest?.throttle ?: 0.0,
        yaw = latest?.yaw ?: 0.0,
        pitch = latest?.pitch ?: 0.0,
        roll = latest?.roll ?: 0.0,
        triggersHeld = latest?.triggersHeld ?: false,
        armed = lastDecisionArmed,
        neutralised = !lastDecisionArmed,
        reasons = lastDecisionReasons.map { it.name },
        sendPathEnabled = DjiLinkBuild.SEND_ENABLED,
        sampleAgeMs = latest?.let { nowMs - it.atMs },
        armingCountdownMs = safety.armingCountdownMs(nowMs),
      ),
    )
  }
}

private fun LinkState.toPigeon(): DjiLinkState = when (this) {
  LinkState.ABSENT -> DjiLinkState.ABSENT
  LinkState.ACCESSORY_DETECTED -> DjiLinkState.ACCESSORY_DETECTED
  LinkState.PERMISSION_PENDING -> DjiLinkState.PERMISSION_PENDING
  LinkState.PERMISSION_DENIED -> DjiLinkState.PERMISSION_DENIED
  LinkState.ACCESSORY_OPEN -> DjiLinkState.ACCESSORY_OPEN
  LinkState.LINK_USABLE -> DjiLinkState.LINK_USABLE
  LinkState.CONTROLLER_IDENTIFIED -> DjiLinkState.CONTROLLER_IDENTIFIED
  LinkState.AIRCRAFT_LINKED -> DjiLinkState.AIRCRAFT_LINKED
  LinkState.VIDEO_READY -> DjiLinkState.VIDEO_READY
  LinkState.TELEMETRY_READY -> DjiLinkState.TELEMETRY_READY
  LinkState.LINK_LOST -> DjiLinkState.LINK_LOST
  LinkState.RECOVERING -> DjiLinkState.RECOVERING
  LinkState.UNSUPPORTED_TRANSPORT -> DjiLinkState.UNSUPPORTED_TRANSPORT
  LinkState.UNSUPPORTED_PROTOCOL -> DjiLinkState.UNSUPPORTED_PROTOCOL
}

private fun LinkReason.toPigeon(): DjiLinkReason = when (this) {
  LinkReason.NO_ACCESSORY_FEATURE -> DjiLinkReason.NO_ACCESSORY_FEATURE
  LinkReason.NO_USB_SERVICE -> DjiLinkReason.NO_USB_SERVICE
  LinkReason.LOOKING -> DjiLinkReason.LOOKING
  LinkReason.NOTHING_LISTED -> DjiLinkReason.NOTHING_LISTED
  LinkReason.LISTED -> DjiLinkReason.LISTED
  LinkReason.WAITING_FOR_CHOOSER -> DjiLinkReason.WAITING_FOR_CHOOSER
  LinkReason.PERMISSION_ASKED -> DjiLinkReason.PERMISSION_ASKED
  LinkReason.PERMISSION_REQUEST_FAILED -> DjiLinkReason.PERMISSION_REQUEST_FAILED
  LinkReason.PERMISSION_REFUSED -> DjiLinkReason.PERMISSION_REFUSED
  LinkReason.OPEN_FAILED -> DjiLinkReason.OPEN_FAILED
  LinkReason.OPENED -> DjiLinkReason.OPENED
  LinkReason.PROBE_RETURNS -> DjiLinkReason.PROBE_RETURNS
  LinkReason.PROBES_FAILED -> DjiLinkReason.PROBES_FAILED
  LinkReason.WRITE_BLOCKED -> DjiLinkReason.WRITE_BLOCKED
  LinkReason.DETACHED -> DjiLinkReason.DETACHED
  LinkReason.STREAM_ENDED -> DjiLinkReason.STREAM_ENDED
  LinkReason.READS_FAILED -> DjiLinkReason.READS_FAILED
  LinkReason.WRITES_FAILED -> DjiLinkReason.WRITES_FAILED
  LinkReason.PAGE_CLOSED -> DjiLinkReason.PAGE_CLOSED
  LinkReason.FRAMES_PARSE -> DjiLinkReason.FRAMES_PARSE
  LinkReason.AIRCRAFT_FRAMES -> DjiLinkReason.AIRCRAFT_FRAMES
}

internal fun CrcReport.toPigeon(): DjiLinkCrc = DjiLinkCrc(
  headerParameters = headerParameters,
  frameParameters = frameParameters,
  headerSeedCandidate = headerSeedCandidate?.toLong(),
  headerSeedVotes = headerSeedVotes,
  headerFailuresVoting = headerFailuresVoting,
  frameSeedCandidate = frameSeedCandidate?.toLong(),
  frameSeedVotes = frameSeedVotes,
  frameFailuresVoting = frameFailuresVoting,
)

private fun ChannelCounters.toPigeon(cameraType: Int?): DjiLinkChannel = DjiLinkChannel(
  channel = channel.toLong(),
  role = role.name.lowercase(),
  envelopes = envelopes,
  bytes = bytes,
  largestPayload = largestPayload.toLong(),
  lastArrivalMs = lastArrivalMs,
  firstArrivalMs = firstArrivalMs,
  cameraType = cameraType?.toLong(),
)

private fun PairCounters.toPigeon(): DjiLinkPair = DjiLinkPair(
  commandSet = commandSet.toLong(),
  commandId = commandId.toLong(),
  count = count,
  lastLength = lastLength.toLong(),
  lastSeenMs = lastSeenMs,
  messageName = messageName,
)

private fun FrameLine.toPigeon(): DjiLinkFrame = DjiLinkFrame(
  atMs = atMs,
  channel = channel.toLong(),
  commandSet = commandSet.toLong(),
  commandId = commandId.toLong(),
  isAcknowledgement = isAcknowledgement,
  ackPolicy = ackPolicy.toLong(),
  senderType = senderType.toLong(),
  receiverType = receiverType.toLong(),
  sequence = sequence.toLong(),
  length = length.toLong(),
  encryption = encryption.toLong(),
  preview = preview,
)

private fun TelemetryMessage.toPigeon(): DjiLinkTelemetryRow = DjiLinkTelemetryRow(
  commandSet = commandSet.toLong(),
  commandId = commandId.toLong(),
  count = count,
  lastLength = lastLength.toLong(),
  ratePerSecond = ratePerSecond,
  preview = preview,
  name = name,
)
