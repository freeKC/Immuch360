package app.alextran.immich.djilink

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import io.flutter.plugin.common.BinaryMessenger
import org.json.JSONArray
import org.json.JSONObject

/** The app's own preferences behind [KeyValueStore], for the stream description cache and the profile bindings */
class SharedPreferencesStore(context: Context) : KeyValueStore {
  private val preferences: SharedPreferences =
    context.getSharedPreferences("dji_link", Context.MODE_PRIVATE)

  override fun read(key: String): String? = preferences.getString(key, null)

  override fun write(key: String, value: String?) {
    preferences.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
  }
}

/**
 * One owner for the whole link, for the lifetime of the process.
 *
 * It holds the accessory manager, the envelope decoder, the frame router, the capture ring, the video pipeline with
 * its decoder, the player of a saved capture, the stick source and the safety rules, and it is the only place that
 * turns all of that into the one answer the page shows. There is no foreground service: the link belongs to the page
 * that is in front of the pilot.
 *
 * Nothing here can send a flight command. The only write is the one byte liveness probe of the transport, which is
 * counted on the page, and the send path of the later stages is behind [DjiLinkBuild.SEND_ENABLED], which is false.
 * The video decoder, the telemetry decoder and the player are receive only: none of them has a handle on the
 * transport.
 */
class DjiLinkController private constructor(private val context: Context) : LinkEvents {
  companion object {
    private const val TAG = "DjiLinkController"

    /** At most one event to Flutter this often; the page also asks for a snapshot when it opens */
    private const val PUBLISH_INTERVAL_MS = 250L

    /** How often the states that follow time (aircraft present, video shown) are looked at */
    private const val TICK_MS = 500L

    /** VIDEO_READY means a picture came out of the decoder less than this long ago */
    private const val VIDEO_READY_WINDOW_NS = 2_000_000_000L

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
   * The reader thread and the player fill the decoders, the routers and the capture while the main thread builds the
   * answer the page shows. One lock around all of them, because a table being sorted while a frame is counted into it
   * is how a diagnostics page crashes in front of a pilot.
   */
  private val gate = Any()
  private val preferences: KeyValueStore = SharedPreferencesStore(context)
  private val profiles = ProfileRegistry()
  private val bindings = ProfileBindings(preferences)
  private val decoder = EnvelopeDecoder()
  private val router = FrameRouter()
  private val capture = CaptureRing(monotonicNs = { SystemClock.elapsedRealtimeNanos() })
  private val videoStatistics = VideoStatistics()
  private val feed = VideoDecoderFeed(videoStatistics, onChange = { markDirty() })
  private val store = ParameterSetStore(preferences)
  private val video = VideoPipeline(store, feed, videoStatistics)
  private val player = CapturePlayer(gate, clockNs = { SystemClock.elapsedRealtimeNanos() })
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

  /** The last accessory strings read on the port and every open, kept after the unplug for the page and the export */
  private val session = SessionLog()
  private val lastAccessory: AccessoryIdentity? get() = session.lastAccessory
  private var started = false
  private var dirty = false
  private var lastPublishMs = 0L
  private var lastDecisionReasons: Set<DeadManSignal> = emptySet()
  private var lastDecisionArmed = false

  private val publish = Runnable { publishNow() }
  private val tick = Runnable { onTick() }

  init {
    router.onVideoUnit = { unit, detector, fresh, nowNs ->
      // One source at a time: while a capture is played, the cable is closed anyway
      if (!player.loaded) {
        video.onUnit(unit, detector, fresh, nowNs)
      }
    }
    player.router.onVideoUnit = { unit, detector, fresh, nowNs -> video.onUnit(unit, detector, fresh, nowNs) }
    DjiLinkVideoSurfaces.listener = { surface -> feed.setViewSurface(surface) }
    store.seed = ProfileRegistry.seed20261023
  }

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
    player.unload()
    synchronized(gate) {
      decoder.reset()
      decoder.clearCounters()
      router.reset()
      video.newSource()
      session.newPageSession()
    }
    feed.setViewSurface(DjiLinkVideoSurfaces.current())
    manager.start()
    handler.removeCallbacks(tick)
    handler.postDelayed(tick, TICK_MS)
    markDirty()
  }

  /**
   * The page closed. A page that never started the link (a device without the accessory feature) may still have played
   * a capture, so the player and the decoder stop in every case.
   */
  fun stop() {
    if (started) {
      started = false
      handler.removeCallbacks(tick)
      manager.stop()
      capture.stop()
    }
    player.unload()
    synchronized(gate) {
      video.newSource()
      store.useAccessory(AccessoryStrings.of(identity))
    }
    feed.shutdown()
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
    capture.start(accessoryOpen = manager.transport?.isRunning == true)
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

  fun setDecoderChoice(choice: DecoderChoice) {
    feed.setChoice(choice)
    markDirty()
  }

  /** The starting profiles, which the pilot can bind the accessory strings to */
  fun bindableProfiles(): List<DeviceProfile> = profiles.bindable()

  /**
   * Binds the strings of the accessory on the port, or of the last one seen, to [profileId]; null forgets the binding.
   * It names the hardware and gives the stream description seed; the link does nothing differently.
   */
  fun bindProfile(profileId: String?) {
    val strings = AccessoryStrings.of(identity ?: lastAccessory) ?: return
    bindings.bind(strings, profileId?.takeIf { profiles.byId(it) != null })
    identity?.let { current ->
      profile = profiles.match(current, bindings.boundTo(strings))
      store.seed = profile?.streamSeed ?: ProfileRegistry.seed20261023
    }
    markDirty()
  }

  /** The captures this app can play */
  fun listCaptures(): List<CaptureFile> = CaptureFiles.list(context)

  /**
   * Plays a capture through the same pipeline as the cable. Refused while an accessory is open. Returns null when it
   * started, otherwise a code the page words: busy, unreadable, tooLarge, damaged (index lines that do not fit the
   * file), empty.
   */
  fun playCapture(binUri: String, indexUri: String, startAtMs: Long, name: String? = null): String? {
    if (manager.transport?.isRunning == true) {
      return "busy"
    }
    val reading = runCatching {
      val bytes = CaptureFiles.read(context, binUri, CaptureFiles.MAX_CAPTURE_BYTES)
      val index = CaptureReplay.readIndex(
        String(CaptureFiles.read(context, indexUri, CaptureFiles.MAX_INDEX_BYTES)),
        fileBytes = bytes.size.toLong(),
      )
      bytes to index
    }.getOrElse {
      Log.w(TAG, "the capture could not be read: ${it.javaClass.simpleName}")
      return if (it is CaptureTooLargeException) "tooLarge" else "unreadable"
    }
    val (bytes, index) = reading
    if (index.damaged) {
      Log.w(
        TAG,
        "the index of the capture has ${index.rejectedLines.size} lines that do not fit, the first at line " +
          "${index.rejectedLines.first()}: not played",
      )
      return "damaged"
    }
    val loaded = LoadedCapture(name ?: binUri.substringAfterLast('/').removeSuffix(".bin"), bytes, index.entries)
    if (loaded.bytes.isEmpty() || loaded.index.none { it.direction == CaptureDirection.IN }) {
      return "empty"
    }
    player.unload()
    synchronized(gate) {
      video.newSource()
      // A replay neither reads nor writes the cache of a live accessory; its seed is the profile's in use, or the one
      // of the only hardware observed so far
      store.useAccessory(null)
      store.seed = boundProfile()?.streamSeed ?: ProfileRegistry.seed20261023
    }
    Log.i(TAG, "playing a capture of ${loaded.bytes.size} bytes from $startAtMs ms")
    handler.removeCallbacks(tick)
    handler.postDelayed(tick, TICK_MS)
    player.play(
      capture = loaded,
      startAtMs = startAtMs,
      onNewStream = { synchronized(gate) { video.newStream() } },
      onRead = { markDirty() },
      onEnd = {
        player.failure?.let { Log.w(TAG, "the playback ended on an error: $it") }
        handler.post { markDirty() }
      },
    )
    markDirty()
    return null
  }

  /** Back to the cable: the played capture is forgotten */
  fun stopPlayback() {
    player.unload()
    synchronized(gate) {
      video.newSource()
      store.useAccessory(AccessoryStrings.of(identity))
      store.seed = profile?.streamSeed ?: ProfileRegistry.seed20261023
    }
    markDirty()
  }

  private fun boundProfile(): DeviceProfile? {
    val strings = AccessoryStrings.of(identity ?: lastAccessory) ?: return null
    return bindings.boundTo(strings)?.let { profiles.byId(it) }
  }

  fun exportCapture(notes: Map<String, String?>): CaptureExport.Result {
    val snapshot: CaptureSnapshot
    val facts: Map<String, Any?>
    val extra: Map<String, Any?>
    synchronized(gate) {
      snapshot = capture.snapshot()
      facts = linkFacts()
      extra = exportExtra()
    }
    val result = CaptureExport.write(
      context = context,
      snapshot = snapshot,
      environment = environment,
      identity = identity,
      profile = profile,
      link = facts,
      notes = notes,
      extra = extra,
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
   * A gamepad moved. Stage 2 only draws it: no sample ever leaves this process, whatever the sticks say, and the
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
   * before the reader thread exists, so the first byte of the remote is counted in full. A capture being played stops:
   * one source at a time.
   */
  override fun onOpened() {
    if (player.loaded) {
      player.unload()
      synchronized(gate) {
        video.newSource()
        store.useAccessory(AccessoryStrings.of(identity))
        store.seed = profile?.streamSeed ?: ProfileRegistry.seed20261023
      }
    }
    synchronized(gate) {
      decoder.reset()
      router.restartStreams()
      video.newStream()
      capture.mark(CaptureDirection.OPEN)
      session.onOpened(System.currentTimeMillis())
    }
    markDirty()
  }

  override fun onClosed(reason: LinkReason) {
    synchronized(gate) {
      capture.mark(CaptureDirection.CLOSE)
      session.onClosed(reason.name, System.currentTimeMillis())
    }
    markDirty()
  }

  override fun onIdentity(identity: AccessoryIdentity?, profile: DeviceProfile?) {
    this.identity = identity
    if (identity == null) {
      this.profile = null
      markDirty()
      return
    }
    synchronized(gate) { session.onIdentity(identity, System.currentTimeMillis()) }
    val strings = AccessoryStrings.of(identity)
    this.profile = profiles.match(identity, bindings.boundTo(strings))
    synchronized(gate) {
      if (!player.loaded && store.accessory != strings) {
        store.useAccessory(strings)
      }
      store.seed = this.profile?.streamSeed ?: ProfileRegistry.seed20261023
    }
    markDirty()
  }

  override fun onBytes(data: ByteArray, length: Int) {
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val nowMs = nowNs / 1_000_000
    val frames: Long
    val linked: Boolean
    synchronized(gate) {
      capture.record(CaptureDirection.IN, data, 0, length)
      session.onRead(length, System.currentTimeMillis())
      for (envelope in decoder.offer(data, 0, length)) {
        router.route(envelope, nowMs, nowNs)
      }
      frames = router.counters.controlFrames
      linked = router.aircraftLinked(nowMs)
    }
    // Frames parsed is a claim the transport cannot make, so it is made here and nowhere else. Frames that parse say
    // more than the probe does, so they move the state on during the quiet window too.
    if (frames > 0 && (state == LinkState.LINK_USABLE || state == LinkState.ACCESSORY_OPEN)) {
      handler.post { promote(LinkState.CONTROLLER_IDENTIFIED, LinkReason.FRAMES_PARSE) }
    }
    if (linked && state == LinkState.CONTROLLER_IDENTIFIED) {
      handler.post { promote(LinkState.AIRCRAFT_LINKED, LinkReason.AIRCRAFT_FRAMES) }
    }
    markDirty()
  }

  /** A state change decided here, made only while the descriptor that justified it is still open */
  private fun promote(next: LinkState, why: LinkReason) {
    if (manager.transport?.isRunning != true) {
      return
    }
    manager.publish(next, why)
  }

  override fun onWrite(data: ByteArray, isProbe: Boolean) {
    synchronized(gate) {
      capture.record(CaptureDirection.OUT, data)
      session.onWritten(data.size)
    }
    markDirty()
  }

  override fun onProbe(result: ProbeResult) {
    markDirty()
  }

  /**
   * The states that follow time: the aircraft present or gone, a picture shown in the last two seconds or not. It also
   * keeps the page current while a capture plays or just stopped, on a device whose link never started too.
   */
  private fun onTick() {
    if (!started && !player.loaded) {
      return
    }
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val linked: Boolean
    val pictures: Boolean
    val active: Boolean
    synchronized(gate) {
      linked = router.aircraftLinked(nowNs / 1_000_000)
      pictures = !player.loaded && videoStatistics.outputWithin(nowNs, VIDEO_READY_WINDOW_NS)
      // A few seconds after the last picture, so that the rates of the panel come down to zero on the page
      active = player.playing || videoStatistics.outputWithin(nowNs, 2 * VIDEO_READY_WINDOW_NS) ||
        (started && router.counters.envelopes > 0)
    }
    when (state) {
      LinkState.AIRCRAFT_LINKED -> when {
        !linked -> promote(LinkState.CONTROLLER_IDENTIFIED, LinkReason.FRAMES_PARSE)
        pictures -> promote(LinkState.VIDEO_READY, LinkReason.VIDEO_DECODED)
        else -> Unit
      }
      LinkState.VIDEO_READY -> when {
        !linked -> promote(LinkState.CONTROLLER_IDENTIFIED, LinkReason.FRAMES_PARSE)
        !pictures -> promote(LinkState.AIRCRAFT_LINKED, LinkReason.AIRCRAFT_FRAMES)
        else -> Unit
      }
      else -> Unit
    }
    if (active) {
      markDirty()
    }
    handler.postDelayed(tick, TICK_MS)
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
      "envelopePaddingBytes" to envelope.paddingBytes,
      "envelopePaddingCutShort" to envelope.paddingCutShort,
      "envelopeUnknownChannelFrames" to envelope.unknownChannelFrames,
      "envelopeUnknownChannelRejections" to envelope.unknownChannelRejections,
      "envelopeOversizeRejections" to envelope.oversizeRejections,
      "envelopeIncompleteTimeouts" to envelope.incompleteTimeouts,
      "controlFrames" to control.frames,
      "headerCrcFailures" to control.headerCrcFailures,
      "frameCrcFailures" to control.frameCrcFailures,
      "unsupportedEncryption" to control.unsupportedEncryption,
      "knownPairs" to routed.knownPairs,
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

  /** The parts of the export header that stage 2 adds: the last accessory, every open, the video, the telemetry */
  private fun exportExtra(): Map<String, Any?> {
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val last = lastAccessory
    val lastJson = if (last == null) {
      JSONObject.NULL
    } else {
      JSONObject()
        .put("manufacturer", last.manufacturer ?: JSONObject.NULL)
        .put("model", last.model ?: JSONObject.NULL)
        .put("description", last.description ?: JSONObject.NULL)
        .put("version", last.version ?: JSONObject.NULL)
        .put("serial", last.serial ?: JSONObject.NULL)
        .put("readAtWallMs", session.lastAccessoryAtWallMs ?: JSONObject.NULL)
    }
    val openList = JSONArray()
    for (open in session.opens()) {
      openList.put(
        JSONObject()
          .put("openedAtWallMs", open.openedAtWallMs)
          .put("firstByteAfterMs", open.firstByteAfterMs ?: JSONObject.NULL)
          .put("bytesRead", open.bytesRead)
          .put("bytesWritten", open.bytesWritten)
          .put("reads", open.reads)
          .put("closedAtWallMs", open.closedAtWallMs ?: JSONObject.NULL)
          .put("closeReason", open.closeReason ?: JSONObject.NULL),
      )
    }
    val stats = video.stats(nowNs, router.assemblerCounters().unitsTooLarge)
    val videoJson = JSONObject()
      .put("codec", stats.codec.name)
      .put("codecEvidence", stats.codecEvidence.name)
      .put("width", stats.width ?: JSONObject.NULL)
      .put("height", stats.height ?: JSONObject.NULL)
      .put("profile", stats.profileName ?: JSONObject.NULL)
      .put("highTier", stats.highTier ?: JSONObject.NULL)
      .put("level", stats.levelName ?: JSONObject.NULL)
      .put("descriptionSource", stats.descriptionSource?.name ?: JSONObject.NULL)
      .put("units", stats.unitsIn)
      .put("queued", stats.queued)
      .put("decoded", stats.decoded)
      .put("shown", stats.shown)
      .put("droppedAtDisplay", stats.droppedAtDisplay)
      .put("overruns", stats.overruns)
      .put("tooLarge", stats.tooLarge)
      .put("errors", stats.errors)
      .put("decoderName", stats.decoder.name ?: JSONObject.NULL)
      .put("decoderKind", stats.decoder.kind?.name ?: JSONObject.NULL)
      .put("lowLatency", stats.decoder.lowLatency)
      .put("switches", stats.decoder.switches)
      .put("decodeMedianMs", stats.decodeMedianMs ?: JSONObject.NULL)
      .put("decodeP95Ms", stats.decodeP95Ms ?: JSONObject.NULL)
      .put("firstPictureMs", stats.firstPictureMs ?: JSONObject.NULL)
      .put("lostPictures", stats.lostPictures)
      .put("encoderRestarts", stats.encoderRestarts)
      .put("keyPictures", stats.keyPictures)
    val values = router.telemetryDecoder.values(nowNs / 1_000_000)
    val seen = JSONObject()
    values.decoded.forEach { (code, count) -> seen.put(code, count) }
    val telemetryJson = JSONObject()
      .put("decoded", seen)
      .put("layoutMismatches", values.layoutMismatches)
      .put(
        "unanswered",
        JSONArray().apply {
          router.requestRows().forEach { row ->
            put("${row.senderType}.${row.senderIndex} set ${row.commandSet} id ${row.commandId} policy ${row.ackPolicy}: ${row.count}, ${row.repeats} repeats")
          }
        },
      )
    val binding = bindings.boundTo(AccessoryStrings.of(identity ?: lastAccessory))
    return linkedMapOf(
      "lastAccessory" to lastJson,
      "opens" to openList,
      "video" to videoJson,
      "telemetry" to telemetryJson,
      "profileBinding" to (binding ?: JSONObject.NULL),
      "captureHeadBytes" to capture.capacityOfHead,
      "captureTailBytes" to capture.capacityOfRing,
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
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val nowMs = nowNs / 1_000_000
    val envelope = decoder.counters
    val control = router.controlCounters()
    val routed = router.counters
    val latest = sticks.latest()
    // The video and the flight values come from the capture being played, when one is; the traffic stays the cable's
    val source = if (player.loaded) player.router else router
    val probeReport = source.probe.report()
    val tooLarge = source.assemblerCounters().unitsTooLarge
    return DjiLinkSnapshot(
      state = state.toPigeon(),
      reason = reason.toPigeon(),
      detail = argument,
      accessory = identity?.toPigeon(),
      profile = profile?.toPigeon(),
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
        paddingBytes = envelope.paddingBytes,
      ),
      crc = router.crcReport().toPigeon(),
      channels = router.channelCounters().map { it.toPigeon(router.cameraChannels.cameraOfChannel(it.channel)) },
      pairs = router.pairCounters().map { it.toPigeon() },
      frames = router.frames().map { it.toPigeon() },
      telemetry = router.telemetry.messages().map { it.toPigeon() },
      video = DjiLinkVideo(
        verdict = probeReport.verdict.toPigeon(),
        payloads = probeReport.payloads,
        payloadsStartingWithStartCode = probeReport.payloadsStartingWithStartCode,
        startCodesSeen = probeReport.startCodesSeen,
        unitTypes = probeReport.unitTypes.entries.joinToString(" ") { "${it.key}:${it.value}" },
        sawH264ParameterSets = probeReport.sawH264ParameterSets,
        sawH265ParameterSets = probeReport.sawH265ParameterSets,
        channels = source.video.channels().map {
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
        headBytes = capture.capacityOfHead.toLong(),
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
      videoDecode = video.stats(nowNs, tooLarge).toPigeon(),
      telemetryValues = telemetryPigeon(source, nowMs),
      source = DjiLinkSource(
        replay = player.loaded,
        playing = player.playing,
        name = player.name,
        positionMs = if (player.loaded) player.positionMs else null,
        durationMs = if (player.loaded) player.durationMs else null,
        failure = if (player.loaded) player.failure else null,
      ),
      lastAccessory = lastAccessory?.toPigeon(),
      lastAccessoryAtMs = session.lastAccessoryAtWallMs,
      boundProfileId = bindings.boundTo(AccessoryStrings.of(identity ?: lastAccessory)),
    )
  }
}

private fun AccessoryIdentity.toPigeon(): DjiLinkAccessory = DjiLinkAccessory(
  manufacturer = manufacturer,
  model = model,
  description = description,
  version = version,
  serial = serial,
)

internal fun DeviceProfile.toPigeon(): DjiLinkProfile = DjiLinkProfile(
  id = id,
  label = label,
  note = note,
  capabilities = Capability.entries.map { capability ->
    val state = capabilities[capability] ?: CapabilityState.unknown
    DjiLinkCapability(
      name = capability.name,
      support = when (state.support) {
        Support.UNKNOWN -> DjiLinkSupport.UNKNOWN
        Support.UNSUPPORTED -> DjiLinkSupport.UNSUPPORTED
        Support.SUPPORTED -> DjiLinkSupport.SUPPORTED
      },
      provenance = state.provenance?.let { "${it.observationId} (${it.date})" },
      observedOn = state.provenance?.deviceModel,
      observedDate = state.provenance?.date,
      observed = state.provenance?.observed,
    )
  },
)

internal fun ProbeVerdict.toPigeon(): DjiLinkProbeVerdict = when (this) {
  ProbeVerdict.NO_DATA -> DjiLinkProbeVerdict.NO_DATA
  ProbeVerdict.NO_START_CODES -> DjiLinkProbeVerdict.NO_START_CODES
  ProbeVerdict.START_CODES_SEEN -> DjiLinkProbeVerdict.START_CODES_SEEN
  ProbeVerdict.H265 -> DjiLinkProbeVerdict.H265
  ProbeVerdict.H264 -> DjiLinkProbeVerdict.H264
}

private fun VideoStats.toPigeon(): DjiLinkDecode = DjiLinkDecode(
  state = when (state) {
    VideoState.WAITING_FOR_VIDEO -> DjiLinkVideoState.WAITING_FOR_VIDEO
    VideoState.WAITING_FOR_DESCRIPTION -> DjiLinkVideoState.WAITING_FOR_DESCRIPTION
    VideoState.BUILDING -> DjiLinkVideoState.BUILDING
    VideoState.DECODING -> DjiLinkVideoState.DECODING
    VideoState.HIDDEN -> DjiLinkVideoState.HIDDEN
    VideoState.FAILED -> DjiLinkVideoState.FAILED
    VideoState.H264_NOT_DECODED -> DjiLinkVideoState.H264NOT_DECODED
  },
  failure = failure,
  codec = when (codec) {
    VideoCodec.H265 -> "h265"
    VideoCodec.H264 -> "h264"
    VideoCodec.UNKNOWN -> "unknown"
  },
  width = width?.toLong(),
  height = height?.toLong(),
  profileName = profileName,
  highTier = highTier,
  levelName = levelName,
  descriptionSource = when (descriptionSource) {
    DescriptionSource.SESSION -> DjiLinkDescriptionSource.SESSION
    DescriptionSource.CACHE -> DjiLinkDescriptionSource.CACHE
    DescriptionSource.PROFILE -> DjiLinkDescriptionSource.PROFILE
    null -> DjiLinkDescriptionSource.NONE
  },
  decoderName = decoder.name,
  decoderHardware = decoder.kind?.let { it == DecoderKind.HARDWARE },
  choice = when (decoder.choice) {
    DecoderChoice.AUTOMATIC -> DjiLinkDecoderChoice.AUTOMATIC
    DecoderChoice.HARDWARE -> DjiLinkDecoderChoice.HARDWARE
    DecoderChoice.SOFTWARE -> DjiLinkDecoderChoice.SOFTWARE
  },
  lowLatency = decoder.lowLatency,
  switches = decoder.switches.toLong(),
  switchReason = when (decoder.lastSwitchReason) {
    DecoderPolicy.SwitchReason.NO_OUTPUT_AFTER_JOIN -> "noOutputAfterJoin"
    DecoderPolicy.SwitchReason.HARDWARE_RETRY_FAILED -> "hardwareRetryFailed"
    DecoderPolicy.SwitchReason.FATAL_ERRORS -> "fatalErrors"
    null -> null
  },
  unitsIn = unitsIn,
  queued = queued,
  decoded = decoded,
  shown = shown,
  droppedAtDisplay = droppedAtDisplay,
  overruns = overruns,
  tooLarge = tooLarge,
  unitsWithoutDescription = unitsWithoutDescription,
  errors = errors,
  picturesPerSecond = picturesPerSecond,
  megabitsPerSecond = megabitsPerSecond,
  decodeLastMs = decodeLastMs,
  decodeMedianMs = decodeMedianMs,
  decodeP95Ms = decodeP95Ms,
  inProcessMedianMs = inProcessMedianMs,
  inProcessP95Ms = inProcessP95Ms,
  firstPictureMs = firstPictureMs,
  lostPictures = lostPictures,
  encoderRestarts = encoderRestarts,
  keyPictures = keyPictures,
  keyPictureAgoMs = keyPictureAgoMs,
  lastOutputAgoMs = lastOutputAgoMs,
)

private fun telemetryPigeon(router: FrameRouter, nowMs: Long): DjiLinkTelemetry {
  val values = router.telemetryDecoder.values(nowMs)
  val link = values.link
  val clock = link.aircraftClockMs
  return DjiLinkTelemetry(
    aircraftPresent = router.aircraftLinked(nowMs),
    remotePresent = router.remotePresent(nowMs),
    layoutMismatches = values.layoutMismatches,
    flight = values.flight?.let { timed ->
      val reading = timed.value
      DjiLinkFlight(
        ageMs = timed.ageMs,
        stale = timed.stale,
        heightM = reading.heightM,
        speedsMps = reading.speedsMps,
        pitchDeg = reading.pitchDeg,
        rollDeg = reading.rollDeg,
        headingDeg = reading.headingDeg,
        mode = reading.mode.toLong(),
        inAir = reading.inAir,
        motorsOn = reading.motorsOn,
        motorTimeS = reading.motorTimeS,
        satellites = reading.satellites.toLong(),
        groundHeightM = reading.groundHeightM,
        evidence = DjiLinkEvidence.PUBLIC_AND_CAPTURE,
      )
    },
    battery = values.battery?.let { timed ->
      val reading = timed.value
      DjiLinkBattery(
        ageMs = timed.ageMs,
        stale = timed.stale,
        percent = reading.percent.toLong(),
        volts = reading.voltageV,
        amps = reading.currentA,
        remainingMah = reading.remainingMah,
        fullMah = reading.fullMah,
        temperatureC = reading.temperatureC,
        cells = reading.cells.toLong(),
        status = "%016x".format(reading.status),
        evidence = DjiLinkEvidence.PUBLIC_AND_CAPTURE,
      )
    },
    gimbal = values.gimbal?.let { timed ->
      val reading = timed.value
      DjiLinkGimbal(
        ageMs = timed.ageMs,
        stale = timed.stale,
        headingDeg = reading.headingDeg,
        headingFineDeg = reading.headingFineDeg,
        angle1Deg = reading.angle1Deg,
        angle2Deg = reading.angle2Deg,
        quaternion = reading.quaternion,
        evidence = DjiLinkEvidence.CAPTURE,
      )
    },
    link = DjiLinkLinkInfo(
      signalAircraftSide = link.signalAircraftSide?.value?.toLong(),
      signalRemoteSide = link.signalRemoteSide?.value?.toLong(),
      liveRateMbps = link.liveRateMbps?.value,
      aircraftClockMs = clock?.value,
      clockJitterP95Ms = link.clockJitterP95Ms,
      clockDriftMs = link.clockDriftMs,
      ageMs = clock?.ageMs,
      stale = clock?.stale ?: false,
    ),
    remoteBatteryPercent = values.remoteBatteryPercent?.value?.toLong(),
    remoteBatteryStale = values.remoteBatteryPercent?.stale ?: false,
    unanswered = router.requestRows().map {
      DjiLinkRequestRow(
        senderType = it.senderType.toLong(),
        senderIndex = it.senderIndex.toLong(),
        commandSet = it.commandSet.toLong(),
        commandId = it.commandId.toLong(),
        ackPolicy = it.ackPolicy.toLong(),
        count = it.count,
        repeats = it.repeats,
      )
    },
  )
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
  LinkReason.VIDEO_DECODED -> DjiLinkReason.VIDEO_DECODED
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
