package app.alextran.immich.djilink

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.MotionEvent
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference

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
 * The system build and the install of the app, which [DecoderMemory] keeps its entries against: a system update or a
 * new install of the app (its last update time changes) gives every decoder its chance again
 */
private fun installedBuild(context: Context): String {
  val installed = runCatching {
    @Suppress("DEPRECATION")
    context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
  }.getOrDefault(0L)
  return "${Build.FINGERPRINT ?: ""} $installed"
}

/**
 * One owner for the whole link, for the lifetime of the process.
 *
 * It holds the accessory manager, the envelope decoder, the frame router, the capture ring, the video pipeline with
 * its decoder, the player of a saved capture, the relay to the headsets and the receiver of a phone's relay, the stick
 * source and the safety rules, and it is the only place that turns all of that into the one answer the page shows.
 *
 * The link has owners ([LinkOwners]): the page in front of the pilot, the relay while it sends (kept alive by
 * [DjiLinkRelayService]) and the flight view of the Quest while it shows. It starts with the first and stops with the
 * last, so a pilot who leaves the page while the phone sends to a headset does not cut the headset's picture.
 *
 * One source at a time feeds the video pipeline: the cable, a capture being played, or a phone's relay. The relay
 * forwards the units of the first two only, never a received stream.
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

    /** A phone's telemetry older than this no longer says the aircraft or the remote is there */
    private const val STALE_RELAY_MS = 2_000L

    /** The values a pilot reads go to Flutter at most this often, while a screen with the picture is in front */
    private const val FRAME_INTERVAL_MS = 100L

    /** How often the obstacle ring decides and the tick is looked at: finer than a frame, so the tick keeps pace */
    private const val FRAME_TICK_MS = 50L

    /**
     * Every control frame of a session, unpadded: 11.5 kB/s on the ground and 19.5 kB/s in flight in our captures, so
     * 32 MiB hold a whole battery (p2/telemetry-deep-dive-2026-10-24.md, section 8)
     */
    const val CONTROL_CAPTURE_BYTES = 32 * 1024 * 1024

    /** A header only export asked again this soon, with nothing new, writes nothing */
    private const val REPEAT_HEADER_ONLY_MS = 5_000L

    /** A relay with nothing to send and no headset for this long stops by itself, as its notification says */
    const val RELAY_IDLE_STOP_MS = 10L * 60 * 1000

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

  /** Every control envelope of the session beside the capture, which the video pushes out of its tail in a minute */
  private val controlCapture = CaptureRing(
    capacityBytes = CONTROL_CAPTURE_BYTES,
    headBytes = 0,
    monotonicNs = { SystemClock.elapsedRealtimeNanos() },
  )

  /** What this device received from a phone's relay, for a bug report from a headset */
  private val reception = ReceptionRecord(monotonicNs = { SystemClock.elapsedRealtimeNanos() })
  private var receptionPageSession = -1L

  /** The last export and what it covered: a second tap with nothing new writes nothing */
  private val exports = ExportMemory(REPEAT_HEADER_ONLY_MS)
  private val receptionExports = ExportMemory(REPEAT_HEADER_ONLY_MS)

  /** The obstacle ring: offered by the gate in Flutter, decided here with its sample, its tick played here */
  private val ringTicker = ObstacleRingTicker()
  private val beeper = TickBeeper()
  private val tone = ObstacleTone(beeper) { tapWithTick() }

  /**
   * This device's choices for the ring, from Flutter. On a receiver the phone's record says whether it is offered,
   * its distances and its side; the sound, the tap and the number stay this device's own.
   */
  @Volatile
  private var ring = DjiObstacleRingSettings(
    offered = false,
    directional = false,
    farM = RingSettings.DEFAULT_FAR_M,
    nearM = RingSettings.DEFAULT_NEAR_M,
    sound = true,
    haptic = false,
    numbers = false,
  )

  /** The live screen's activity, whose window taps with the tick; held weakly, the controller outlives it */
  @Volatile
  private var tapActivity: WeakReference<Activity>? = null

  @Volatile
  private var lastDecision = ObstacleDecision.OFF

  /** A headset asked for the lowest delay in Options: no floor under its jitter buffer */
  @Volatile
  private var lowestDelay = false

  /** A screen with the picture is in front: the frames go to Flutter and the tick may play */
  private var frameStreamOn = false
  private val frames = FrameGate<DjiLiveFrame>(FRAME_INTERVAL_MS) { a, b -> a.copy(atMs = 0) == b.copy(atMs = 0) }
  private val videoStatistics = VideoStatistics()
  private val feed = VideoDecoderFeed(
    videoStatistics,
    onChange = { markDirty() },
    memory = DecoderMemory(preferences, installedBuild(context)),
  )
  private val store = ParameterSetStore(preferences)

  /** Who keeps the link running; read and changed under [gate] */
  private val owners = LinkOwners()

  /** The relay to the headsets: the second half of the tee, after the phone's own decoder */
  private val relay = RelayServer(
    clockNs = { SystemClock.elapsedRealtimeNanos() },
    telemetry = { sequence -> relayTelemetryBody(sequence) },
    welcomeFacts = { RelayWelcomeFacts(relayPhoneName, relayPhoneId, if (player.loaded) player.name else null) },
    onChange = { markDirty() },
  )
  private val tee = TeeSink(feed, relay)
  private val video = VideoPipeline(store, tee, videoStatistics)
  private val player = CapturePlayer(gate, clockNs = { SystemClock.elapsedRealtimeNanos() })

  /** The receiver of a phone's relay, and the detector of the stream it receives */
  private val receiverDetector = CodecDetector()
  private val receiver = RelayReceiver(ReceiverEvents(), clockNs = { SystemClock.elapsedRealtimeNanos() })

  /** The display of this device and its changes, watched once a reception starts */
  private val displayWatch = DisplayWatch()

  /** The network facts read at most every 2 s for the page, and when an export is written */
  @Volatile
  private var networkFacts: NetworkFacts? = null
  private var networkFactsAtMs = 0L
  @Volatile
  private var receiverWifiLock: WifiManager.WifiLock? = null
  private val shownHistory = ArrayDeque<LongArray>()

  @Volatile
  private var relayPhoneName: String = Build.MODEL ?: "phone"

  @Volatile
  private var relayPhoneId: String? = null
  private val relayIdle = RelayIdleWatch(RELAY_IDLE_STOP_MS)
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
  private val frameTick = Runnable { onFrameTick() }

  init {
    router.onVideoUnit = { unit, detector, fresh, nowNs ->
      // One source at a time: while a capture is played, the cable is closed anyway; a received stream is refused
      // while the cable is open
      if (!player.loaded && !receiver.active) {
        video.onUnit(unit, detector, fresh, nowNs)
      }
    }
    player.router.onVideoUnit = { unit, detector, fresh, nowNs -> video.onUnit(unit, detector, fresh, nowNs) }
    DjiLinkVideoSurfaces.listener = { surface -> feed.setViewSurface(surface) }
    store.seed = ProfileRegistry.seed20261023
    // The phone receive time of a relayed unit on this device's clock, for phone receive to picture shown
    feed.phoneToLocal = { phoneNs -> receiver.clock.offsetNs?.let { phoneNs - it } }
  }

  fun readEnvironment(): UsbEnvironmentReport {
    environment = UsbEnvironment.read(context)
    return environment
  }

  /** Whether the page is open and the link is being looked after */
  val isStarted: Boolean get() = started

  /**
   * Raised each time the page closes. A capture asked for by a page is played only while this is the number it read
   * when it asked: a request still on the worker thread when the page closed must not start a decoder nobody stops.
   */
  @Volatile
  var pageSession = 0L
    private set

  /**
   * The page opened on a device that can be an accessory: it owns the link from now on. A link the relay kept running
   * while the page was away is joined as it is, its counters kept.
   */
  fun start() {
    synchronized(gate) { owners.take(LinkOwner.PAGE) }
    if (started) {
      markDirty()
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
    feed.open()
    feed.setViewSurface(DjiLinkVideoSurfaces.current())
    manager.start()
    handler.removeCallbacks(tick)
    handler.postDelayed(tick, TICK_MS)
    markDirty()
  }

  /**
   * [owner] lets go of the link. The page releasing it raises the page session. The link, the player, the receiver and
   * the decoder stop only when no owner is left: a page that never started the link (a device without the accessory
   * feature) may still have played a capture, so the player and the decoder stop in that case too.
   */
  fun stop(owner: LinkOwner = LinkOwner.PAGE) {
    val last = synchronized(gate) {
      if (owner == LinkOwner.PAGE) {
        pageSession += 1
      }
      owners.release(owner)
    }
    if (!last) {
      markDirty()
      return
    }
    stopEverything()
  }

  /** No owner is left, or the app was swiped away: every part of the link stops */
  private fun stopEverything() {
    synchronized(gate) { owners.clear() }
    if (relay.isRunning) {
      relay.stop(RelayWire.BYE_CLOSING)
      DjiLinkRelayService.stop(context)
    }
    if (receiver.active) {
      receiver.disconnect()
    }
    releaseReceiverWifiLock()
    if (started) {
      started = false
      handler.removeCallbacks(tick)
      manager.stop()
      capture.stop()
      controlCapture.stop()
    }
    player.unload()
    synchronized(gate) {
      video.newSource()
      store.useAccessory(AccessoryStrings.of(identity))
      store.seed = profile?.streamSeed ?: ProfileRegistry.seed20261023
    }
    relay.source = RelaySource.NONE
    feed.shutdown()
    // The link really ends here, whoever ended it (the page, Stop in the notification, the app swiped away): a pilot
    // not using the link is never offered this application when a cable is plugged in, and it never competes with the
    // DJI application, unless he said yes to "Open this screen when the remote is plugged in" (AttachEntryPolicy).
    // The package manager keeps that setting across process deaths.
    DjiLinkApiImpl.setAttachEntryEnabled(context, AttachEntryPreferences(preferences).entryEnabled(linkRunning = false))
    markDirty()
  }

  /** A request of the page on a device whose page never started the link: the page holds it from now on */
  private fun holdForPage() {
    synchronized(gate) { owners.take(LinkOwner.PAGE) }
  }

  fun retry() {
    if (!started) {
      start()
      return
    }
    manager.retryNow()
  }

  /**
   * The pilot picked this application in the system chooser of a plug. An open live screen takes the accessory at once;
   * otherwise Flutter opens the live screen ([AttachLaunch]), whose link then finds it.
   */
  fun onAttachEntry() {
    if (started) {
      manager.onAttachEntry()
    }
  }

  fun startCapture() {
    val open = manager.transport?.isRunning == true
    capture.start(accessoryOpen = open)
    controlCapture.start(accessoryOpen = open)
    markDirty()
  }

  fun stopCapture() {
    capture.stop()
    controlCapture.stop()
    markDirty()
  }

  fun clearCapture() {
    // Under the page lock, as the reader thread records: whether a session is under way cannot change meanwhile
    synchronized(gate) {
      val open = manager.transport?.isRunning == true
      capture.clear(accessoryOpen = open)
      controlCapture.clear(accessoryOpen = open)
    }
    markDirty()
  }

  fun setDecoderChoice(choice: DecoderChoice) {
    feed.setChoice(choice)
    markDirty()
  }

  /** The starting profiles, which the pilot can bind the accessory strings to */
  fun bindableProfiles(): List<DeviceProfile> = profiles.bindable()

  /** This device and the flavour of this build, which a capability answer holds for or not */
  val runningDevice: RunningDevice get() = environment.runningDevice

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
   * file), empty, or closed when the page that asked has closed since ([session], read when it asked).
   */
  fun playCapture(
    binUri: String,
    indexUri: String,
    startAtMs: Long,
    name: String? = null,
    session: Long = pageSession,
    loop: Boolean = false,
  ): String? {
    if (session != pageSession) {
      return "closed"
    }
    if (manager.transport?.isRunning == true) {
      return "busy"
    }
    // Playing a local capture ends the reception of a phone's relay: one source at a time
    if (receiver.active) {
      disconnectRelay()
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
    // Checked again under the page lock, which stop() takes to raise the session: either this playback starts before
    // the page closes, and stop() ends it and shuts the decoder down, or it does not start at all
    synchronized(gate) {
      if (session != pageSession) {
        return "closed"
      }
      owners.take(LinkOwner.PAGE)
      feed.open()
      video.newSource()
      // A replay neither reads nor writes the cache of a live accessory; its seed is the profile's in use, or the one
      // of the only hardware observed so far
      store.useAccessory(null)
      store.seed = boundProfile()?.streamSeed ?: ProfileRegistry.seed20261023
      Log.i(TAG, "playing a capture of ${loaded.bytes.size} bytes from $startAtMs ms")
      handler.removeCallbacks(tick)
      handler.postDelayed(tick, TICK_MS)
      relay.source = RelaySource.REPLAY
      player.play(
        capture = loaded,
        startAtMs = startAtMs,
        onNewStream = { synchronized(gate) { video.newStream() } },
        onRead = { markDirty() },
        onEnd = {
          player.failure?.let { Log.w(TAG, "the playback ended on an error: $it") }
          handler.post { markDirty() }
        },
        loop = loop,
      )
    }
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
    relay.source = if (manager.transport?.isRunning == true) RelaySource.CABLE else RelaySource.NONE
    markDirty()
  }

  // The relay to the headsets (phone)

  /**
   * Starts sending to headsets with [code]: the relay listens, the foreground service keeps the phone sending with the
   * screen locked, and the link is owned by the relay too. Called on a worker thread (the socket is bound there).
   * Returns the port, or 0 when nothing could listen, this device receives a phone's relay itself, or the page that
   * asked has closed since ([session], read on the main thread when it asked): a relay nobody sees is never started.
   */
  fun startRelay(
    code: String,
    texts: DjiLinkRelayTexts,
    phoneName: String,
    phoneId: String?,
    session: Long = pageSession,
    screens: List<RelayScreenCode> = emptyList(),
  ): Int {
    if (receiver.active || RelayWire.normalizeCode(code) != code) {
      return 0
    }
    // Under the page lock, which stop() takes to raise the session: either the relay is owned before the page closes,
    // and it keeps the link as it should, or it does not start at all
    val open = synchronized(gate) {
      if (session != pageSession) {
        false
      } else {
        owners.take(LinkOwner.PAGE)
        owners.take(LinkOwner.RELAY)
        true
      }
    }
    if (!open) {
      Log.i(TAG, "the page closed before the relay started: not started")
      return 0
    }
    relayPhoneName = phoneName
    relayPhoneId = phoneId
    relay.source = when {
      player.loaded -> RelaySource.REPLAY
      manager.transport?.isRunning == true -> RelaySource.CABLE
      else -> RelaySource.NONE
    }
    val port = runCatching { relay.start(code, screens = screens) }.getOrElse {
      Log.w(TAG, "the relay could not listen: ${it.javaClass.simpleName}")
      stop(LinkOwner.RELAY)
      return 0
    }
    handler.post {
      relayIdle.reset()
      // A relay that cannot keep running in the foreground would go on listening with no notification and no Stop
      if (relay.isRunning && !DjiLinkRelayService.start(context, texts)) {
        relayServiceRefused()
      }
    }
    scheduleTick()
    markDirty()
    return port
  }

  /**
   * Android refused the foreground service of the relay (the app went to the background in between, or the type was
   * refused): the relay stops at once and Flutter is told, as for Stop in the notification, so that the switch goes
   * off and the announcement stops.
   */
  fun relayServiceRefused() {
    handler.post {
      if (!relay.isRunning) {
        return@post
      }
      Log.w(TAG, "the relay service could not run in the foreground: the relay stops")
      stopRelay()
      runCatching { events?.relayStopRequested { } }
    }
  }

  /** Stops sending: a bye to every headset; the link stops too when nothing else owns it */
  fun stopRelay() {
    relay.stop(RelayWire.BYE_STOPPED)
    DjiLinkRelayService.stop(context)
    stop(LinkOwner.RELAY)
  }

  /** "New code": every headset is told and must prove the new one */
  fun setRelayCode(code: String) {
    if (RelayWire.normalizeCode(code) == code && relay.isRunning) {
      relay.setCode(code)
    }
  }

  /** The TVs the pilot added on this phone, each with its own code; a TV removed is told to leave */
  fun setRelayScreenCodes(screens: List<RelayScreenCode>) {
    relay.setScreenCodes(screens)
  }

  /** Stop in the notification: the relay stops here, and Flutter is told so that it stops the announcement */
  fun stopRelayFromNotification() {
    handler.post {
      stopRelay()
      runCatching { events?.relayStopRequested { } }
    }
  }

  /** The app was swiped away while sending: everything stops */
  fun onTaskRemoved() {
    handler.post { stopEverything() }
  }

  fun updateRelayNotification(text: String) {
    DjiLinkRelayService.update(text)
  }

  // The receiver of a phone's relay (headset, or a phone that receives)

  /**
   * Receives from the phone at [host]:[port]. Null when it started; otherwise badHost (not an IPv4 address of the local
   * network), badCode, busy (a remote is open on this device's cable) or sending (this device sends to headsets).
   */
  fun connectRelay(host: String, port: Int, code: String, phoneId: String?, headsetName: String): String? {
    if (!RelayWire.isLocalIPv4Literal(host) || port !in 1..65535) {
      return "badHost"
    }
    val normalized = RelayWire.normalizeCode(code) ?: return "badCode"
    if (manager.transport?.isRunning == true) {
      receiver.refuseBusy()
      markDirty()
      return "busy"
    }
    if (relay.isRunning) {
      return "sending"
    }
    holdForPage()
    if (player.loaded) {
      player.unload()
    }
    synchronized(gate) {
      startRelayedSource()
      // A new reception after the page was closed starts a new record; within the page it goes on in the same one
      if (receptionPageSession != pageSession) {
        reception.clear()
        receptionExports.clear()
        feed.clearTiming()
        receptionPageSession = pageSession
      }
      // The counters of the pacing follow the receiver's: from this connect on, across its reconnections
      feed.clearSmoothing()
    }
    reception.start(ReceptionRecord.Watched(name = null, host = host, port = port))
    handler.post { displayWatch.start(context) }
    relay.source = RelaySource.NONE
    // A TV says so in its hello, so that the phone's Diagnostics list it as a TV; a headset says nothing, as before
    val kind = if (environment.television) "tv" else null
    receiver.connect(host, port, normalized, phoneId, headsetName, environment.appVersion, kind)
    acquireReceiverWifiLock()
    scheduleTick()
    markDirty()
    return null
  }

  fun disconnectRelay() {
    receiver.disconnect()
    releaseReceiverWifiLock()
    synchronized(gate) {
      video.newSource()
      receiverDetector.reset()
      store.useAccessory(AccessoryStrings.of(identity))
      store.seed = profile?.streamSeed ?: ProfileRegistry.seed20261023
    }
    markDirty()
  }

  /**
   * The reception ended on its own (a refused or new code, another version, a phone that did not prove the code): the
   * receiving pipeline stops as Disconnect stops it, so that the window and the flight view never keep the last
   * picture with its last frame rate as if it were live. On the main thread; a connect, a capture or a cable that
   * took the pipeline since then is left alone.
   */
  private fun endReception() {
    val ended = synchronized(gate) {
      if (receiver.active || player.loaded || manager.transport?.isRunning == true) {
        false
      } else {
        video.newSource()
        receiverDetector.reset()
        store.useAccessory(AccessoryStrings.of(identity))
        store.seed = profile?.streamSeed ?: ProfileRegistry.seed20261023
        true
      }
    }
    if (ended) {
      releaseReceiverWifiLock()
      markDirty()
    }
  }

  /** Under [gate]: the pipeline starts again for a relayed stream, which has no accessory, no cache and no seed */
  private fun startRelayedSource() {
    video.newSource()
    receiverDetector.reset()
    store.useAccessory(null)
    store.seed = null
    // A TV can afford a deeper jitter buffer than the pilot's headset, which may ask for the lowest delay
    feed.setPacing(television = environment.television, lowestDelay = lowestDelay)
    feed.open()
    synchronized(shownHistory) { shownHistory.clear() }
  }

  private inner class ReceiverEvents : RelayReceiver.Listener {
    override fun onConnected(welcome: RelayWelcome) {
      synchronized(gate) { startRelayedSource() }
      val target = receiver.snapshot()
      reception.start(ReceptionRecord.Watched(name = welcome.phoneName, host = target.host, port = target.port))
      markDirty()
    }

    override fun onRecord(record: RelayRecord, arrivalNs: Long) {
      reception.record(record)
    }

    override fun onParameters(description: StreamDescription, source: DescriptionSource, arrivalNs: Long) {
      synchronized(gate) {
        if (!receiver.active) {
          return
        }
        // The relayed parameter sets settle the codec the way in band ones do
        receiverDetector.offer(RelayWire.annexBUnit(description.configuration(), arrivalNs))
        store.onRelayedDescription(description, source)
      }
    }

    override fun onUnit(unit: AccessUnit, header: RelayUnitHeader, flags: Int, arrivalNs: Long) {
      synchronized(gate) {
        if (!receiver.active) {
          return
        }
        if ((flags and RelayWire.UNIT_PRIMER) != 0) {
          // The phone's last key unit, ahead of the live units: kept to start the decoder from, counted nowhere
          video.onPrimer(unit, receiverDetector)
          return
        }
        if ((flags and RelayWire.UNIT_BREAK) != 0) {
          // Units the phone dropped for this device, or a new loop of a played capture: neither is a radio loss
          video.relayBreak()
        }
        val fresh = receiverDetector.offer(unit)
        video.onUnit(unit, receiverDetector, fresh, arrivalNs)
      }
      markDirty()
    }

    override fun onReset() {
      synchronized(gate) {
        if (receiver.active) {
          startRelayedSource()
        }
      }
      markDirty()
    }

    override fun onDisconnected() = markDirty()

    override fun onChanged() {
      // A wrong code, another version or a phone that did not prove the code ends the reception: the lock goes with it
      if (!receiver.active) {
        releaseReceiverWifiLock()
      }
      reception.state(receiver.snapshot().state.name)
      markDirty()
    }

    override fun onEnded(state: RelayReceiveState) {
      handler.post { endReception() }
    }

    override fun pingNumbers(): RelayPingNumbers {
      val nowNs = SystemClock.elapsedRealtimeNanos()
      val received = receiver.snapshot(nowNs)
      return feed.smoothingNumbers(nowNs).pingNumbers(received.lostOnWifi, receiver.clock.lastRoundTripNs)
    }

    override fun shownPer10s(): Int {
      val nowNs = SystemClock.elapsedRealtimeNanos()
      val shown = videoStatistics.numbers(nowNs).shown
      synchronized(shownHistory) {
        if (shownHistory.isNotEmpty() && shown < shownHistory.last()[1]) {
          shownHistory.clear()
        }
        shownHistory.addLast(longArrayOf(nowNs, shown))
        while (shownHistory.size > 1 && nowNs - shownHistory.first()[0] > 10_000_000_000L) {
          shownHistory.removeFirst()
        }
        val first = shownHistory.first()
        val spanNs = nowNs - first[0]
        if (spanNs < 1_000_000_000L) {
          return -1
        }
        return ((shown - first[1]) * 10_000_000_000L / spanNs).toInt()
      }
    }
  }

  /** On Horizon OS the app is in front and the display on while a headset is worn: Android honours the lock then */
  private fun acquireReceiverWifiLock() {
    if (receiverWifiLock != null) {
      return
    }
    val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
    val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      WifiManager.WIFI_MODE_FULL_LOW_LATENCY
    } else {
      @Suppress("DEPRECATION")
      WifiManager.WIFI_MODE_FULL_HIGH_PERF
    }
    receiverWifiLock = runCatching {
      wifi.createWifiLock(mode, "immuch360:djirelay-receiver").apply {
        setReferenceCounted(false)
        acquire()
      }
    }.getOrNull()
  }

  private fun releaseReceiverWifiLock() {
    val lock = synchronized(this) { receiverWifiLock.also { receiverWifiLock = null } } ?: return
    runCatching { if (lock.isHeld) lock.release() }
  }

  // The values a pilot reads, ten times a second, and the obstacle ring

  /**
   * A screen with the picture is in front (the live screen, the watch page, and the flight view over the watch page) or
   * not. While it is, the values go to Flutter at most ten times a second when they change, the obstacle ring decides,
   * and its tick may play; when it is not, nothing ticks.
   */
  fun setFrameStream(on: Boolean) {
    handler.post {
      frameStreamOn = on
      handler.removeCallbacks(frameTick)
      frames.reset()
      if (on) {
        handler.post(frameTick)
      } else {
        tone.update(0, soundOn = false, screenShown = false, nowMs = SystemClock.elapsedRealtime())
        beeper.release()
        ringTicker.reset()
        lastDecision = ObstacleDecision.OFF
      }
    }
  }

  /**
   * The ring as this device draws and sounds it, and the activity whose window taps with the tick on a phone. The ring
   * never acts on the drone.
   */
  fun setObstacleRing(settings: DjiObstacleRingSettings, activity: Activity?) {
    ring = settings
    if (activity != null) {
      tapActivity = WeakReference(activity)
    }
  }

  /**
   * A headset's choice in Options (p2/review-relay-2026-10-25.md M4): no floor under its jitter buffer, for the lowest
   * delay. Taken at once while a reception runs: the buffer starts again from the next unit.
   */
  fun setLowestDelay(on: Boolean) {
    lowestDelay = on
    synchronized(gate) {
      if (receiver.active) {
        feed.setPacing(television = environment.television, lowestDelay = on)
      }
    }
  }

  /** Three ticks, to check the volume before take off */
  fun playObstacleTest() {
    tone.playTest { delayMs, tick -> handler.postDelayed({ tick() }, delayMs) }
  }

  /**
   * "Show a sample": eight seconds of a made up ring through the same decision and drawing, on this device only (never
   * relayed, never in a capture). Refused while the motors run, and while no picture screen is in front to draw it;
   * ended as soon as the motors start ([ringTickInputs]).
   */
  fun showObstacleSample(): Boolean {
    if (!frameStreamOn) {
      return false
    }
    val nowNs = SystemClock.elapsedRealtimeNanos()
    return ringTicker.startSample(currentSource(nowNs), nowNs / 1_000_000)
  }

  /** A light tap on the live screen's window, which needs no permission; with the tick, within "Strong glow from" */
  private fun tapWithTick() {
    val activity = tapActivity?.get() ?: return
    runCatching { activity.window?.decorView?.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK) }
  }

  /**
   * The obstacle sound follows the media volume: at zero it cannot be heard. A device whose volume is fixed (most HDMI
   * boxes, whose volume lives on the TV or the sound bar) cannot tell: no warning there.
   */
  fun mediaVolumeOff(): Boolean {
    val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
    return runCatching {
      mediaVolumeSilent(audio.isVolumeFixed, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
    }.getOrDefault(false)
  }

  /**
   * The values of the source in use (a phone's relay, a capture being played, or the cable), what the ring reads from
   * them and, from a phone's relay, the phone's choices for the ring
   */
  private fun currentSource(nowNs: Long): RingSource {
    val received = if (receiver.active) receiver.snapshot(nowNs) else null
    return synchronized(gate) {
      if (received != null) {
        RingSource.received(received.telemetry, received.telemetryAgeMs ?: 0)
      } else {
        RingSource.local((if (player.loaded) player.router else router).telemetryDecoder.values(nowNs / 1_000_000))
      }
    }
  }

  /** On the main thread every 50 ms while a picture screen is in front: the ring, the tick, and the frame */
  private fun onFrameTick() {
    if (!frameStreamOn) {
      return
    }
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val nowMs = nowNs / 1_000_000
    val source = currentSource(nowNs)
    val choices = ring
    // On a receiver the phone's record decides whether the ring is offered, its distances and its side; the sample
    // ends as soon as the motors start; the tap is the phone's (ringTickInputs)
    val tick = ringTicker.tick(
      source,
      RingChoices(choices.offered, RingSettings(choices.farM, choices.nearM, choices.directional), choices.haptic),
      nowMs,
    )
    val decision = tick.decision
    lastDecision = decision
    tone.update(decision.tickIntervalMs, choices.sound, screenShown = true, nowMs = nowMs, tapOn = tick.tap)
    // Only a change goes, ten times a second at most: a frame that says the same thing again would redraw nothing
    val frame = liveFramePigeon(source.values, decision, nowMs)
    if (frames.offer(frame, nowMs)) {
      runCatching { events?.flightChanged(frame) { } }
    }
    handler.postDelayed(frameTick, FRAME_TICK_MS)
  }

  // The flight view (Horizon OS)

  /** Opens the flight view; false off Horizon OS, or while no picture comes */
  fun openFlightView(labels: Map<String, String>): Boolean {
    if (!app.alextran.immich.immersive.isHorizonOsDevice()) {
      return false
    }
    val nowNs = SystemClock.elapsedRealtimeNanos()
    if (!videoStatistics.outputWithin(nowNs, VIDEO_READY_WINDOW_NS)) {
      return false
    }
    return runCatching { context.startActivity(DjiFlightViewActivity.intent(context, labels)) }.isSuccess
  }

  fun flightViewOpened() {
    synchronized(gate) { owners.take(LinkOwner.FLIGHT_VIEW) }
    markDirty()
  }

  fun flightViewClosed() {
    stop(LinkOwner.FLIGHT_VIEW)
  }

  /** What the flight view's panel shows, read four times a second on the main thread */
  fun flightViewNumbers(): DjiFlightNumbers {
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val received = receiver.snapshot(nowNs)
    val receiving = receiver.active
    val stats: VideoStats
    val values: TelemetryValues?
    synchronized(gate) {
      stats = video.stats(nowNs, 0)
      values = if (receiving) {
        received.telemetry?.aged(received.telemetryAgeMs ?: 0)
      } else {
        (if (player.loaded) player.router else router).telemetryDecoder.values(nowNs / 1_000_000)
      }
    }
    val smoothing = feed.smoothingNumbers(nowNs)
    val delay = shownDelay(received, stats, smoothing)
    return DjiFlightNumbers(
      receiving = receiving,
      localReplay = player.loaded,
      state = received.state,
      replay = received.phoneSource == RelaySource.REPLAY.wire,
      phoneHasSource = received.phoneSource != RelaySource.NONE.wire,
      replayName = received.replayName,
      lastPictureAgoMs = ShownDelay.pictureAgoMs(receiving, smoothing, stats.lastOutputAgoMs),
      picturesPerSecond = stats.picturesPerSecond,
      // The pilot sees the delay of the last 2 s, so that a spike shows, and a warning from 500 ms on
      receiveToPictureMs = delay.nowMs,
      values = values,
      alert = lastDecision,
      delayEstimateMs = delay.estimateMs,
      ringNumbers = ring.numbers,
    )
  }

  /**
   * Phone receive to picture shown here (p2/review-relay-2026-10-25.md M1): measured on the pictures released for
   * display when the clocks are aligned (the jitter buffer included), else an estimate apart (the relay delay plus this
   * device's in process and decode medians), and nothing while no picture was shown for half a second
   */
  private fun shownDelay(received: RelayReceiveSnapshot, stats: VideoStats, smoothing: SmoothingNumbers): ShownDelay =
    ShownDelay.of(smoothing, received.latency.relayDelayMedianMs, stats.inProcessMedianMs, stats.decodeMedianMs)

  /** The network facts, read again when older than 2 s */
  private fun currentNetworkFacts(): NetworkFacts? {
    val now = SystemClock.elapsedRealtime()
    if (networkFacts == null || now - networkFactsAtMs > 2_000) {
      networkFacts = runCatching { NetworkFacts.read(context) }.getOrNull()
      networkFactsAtMs = now
    }
    return networkFacts
  }

  private fun boundProfile(): DeviceProfile? {
    val strings = AccessoryStrings.of(identity ?: lastAccessory) ?: return null
    return bindings.boundTo(strings)?.let { profiles.byId(it) }
  }

  /**
   * Writes the capture, its control frames and its header. Called on the one worker of the bridge, so two taps never
   * write at once; a call with nothing new since the last export (the same bytes, or a header only one a few seconds
   * ago) writes nothing and answers the last export with [CaptureExport.Result.repeated].
   */
  fun exportCapture(notes: Map<String, String?>): CaptureExport.Result {
    val snapshot: CaptureSnapshot
    val control: CaptureSnapshot
    val facts: Map<String, Any?>
    val extra: Map<String, Any?>
    val key: List<Long>
    synchronized(gate) {
      key = listOf(capture.totalBytes, capture.records.toLong(), capture.droppedBytes, controlCapture.totalBytes)
      exports.repeated(key, capture.totalBytes, SystemClock.elapsedRealtime())?.let { last ->
        Log.i(TAG, "capture export repeated: nothing new since ${last.binPath ?: last.headerPath}")
        return last
      }
      snapshot = capture.snapshot()
      control = controlCapture.snapshot()
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
      control = control,
    )
    synchronized(gate) { exports.remember(key, result, SystemClock.elapsedRealtime()) }
    Log.i(
      TAG,
      "capture exported: ok=${result.ok} bytes=${result.bytes} control=${control.bytes.size} sha256=${result.sha256}",
    )
    return result
  }

  /**
   * A headset's reception record: the relay records it received, every telemetry record, and a header with the
   * receiver's and the decoder's counters. Nothing is written when nothing was received, or nothing new since the last.
   */
  fun exportReception(): CaptureExport.Result {
    val received = reception.received
    if (received == 0L) {
      Log.i(TAG, "reception record: nothing received, nothing written")
      return CaptureExport.Result(ok = true, bytes = 0, nothing = true)
    }
    synchronized(gate) { receptionExports.repeated(listOf(received), received, SystemClock.elapsedRealtime()) }?.let {
      Log.i(TAG, "reception record repeated: nothing new since ${it.binPath}")
      return it
    }
    val header = receptionHeader()
    val result = CaptureExport.writeReception(
      context = context,
      records = reception.records(),
      telemetry = reception.telemetryRecords(),
      header = header,
      units = feed.timing?.csv(),
    )
    synchronized(gate) { receptionExports.remember(listOf(received), result, SystemClock.elapsedRealtime()) }
    Log.i(TAG, "reception record exported: ok=${result.ok} bytes=${result.bytes} records=$received")
    return result
  }

  /** The header of a reception record: the record's own part, this device, the receiver and the decoder */
  private fun receptionHeader(): String {
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val received = receiver.snapshot(nowNs)
    val stats = synchronized(gate) { video.stats(nowNs, 0) }
    val lastTelemetry = received.telemetry
    val json = buildJsonObject {
      reception.header().forEach { (key, value) -> put(key, value) }
      put("takenAtWallMs", System.currentTimeMillis())
      put("sendPathEnabled", DjiLinkBuild.SEND_ENABLED)
      put(
        "device",
        buildJsonObject {
          put("manufacturer", environment.deviceManufacturer)
          put("model", environment.deviceModel)
          put("fingerprint", environment.buildFingerprint)
          put("androidRelease", environment.androidRelease)
          put("appVersion", environment.appVersion)
          put("flavour", environment.flavour)
        },
      )
      put(
        "receiver",
        buildJsonObject {
          put("state", received.state.name)
          put("phoneSource", received.phoneSource)
          put("failures", received.failures)
          put("units", received.units)
          put("lostOnWifi", received.lostOnWifi)
          put("breaks", received.breaks)
          put("primers", received.primers)
          put("recoveryPrimers", received.recoveryPrimers)
          put("unitHeaderBytes", received.unitHeaderBytes)
          put("longPings", received.longPings)
          put("roundTripMs", received.roundTripMs)
          put("relayDelayMedianMs", received.latency.relayDelayMedianMs)
          put("relayDelayP95Ms", received.latency.relayDelayP95Ms)
          put("networkMedianMs", received.latency.networkMedianMs)
          put("networkP95Ms", received.latency.networkP95Ms)
          put("clockUncertaintyMs", received.latency.clockUncertaintyMs)
          put("telemetryAgeMs", received.telemetryAgeMs)
          put("lastUnitAgoMs", received.lastUnitAgoMs)
          val delay = shownDelay(received, stats, feed.smoothingNumbers(nowNs))
          put("receiveToPictureMs", delay.medianMs)
          put("receiveToPictureNowMs", delay.nowMs)
          put("receiveToPictureEstimateMs", delay.estimateMs)
          put("wifiLockHeld", receiverWifiLock?.isHeld == true)
        },
      )
      // The jitter buffer and what was shown, late, skipped or frozen (p2/relay-smoothness-2026-10-25.md, 6.2)
      put("smoothing", feed.smoothingNumbers(nowNs).toJson())
      put("network", currentNetworkFacts()?.toJson() ?: JsonNull)
      put("display", displayWatch.toJson())
      put("stream", synchronized(gate) { video.facts.toJson() })
      feed.timing?.let { ring ->
        put(
          "unitTiming",
          buildJsonObject {
            put("lines", minOf(ring.total, ring.capacity.toLong()))
            put("total", ring.total)
            put("columns", UnitTimingRing.CSV_HEADER)
            ring.bases()?.let { (local, phone) ->
              put("localBaseNs", local)
              put("phoneBaseNs", phone)
            }
          },
        )
      }
      put(
        "decoder",
        buildJsonObject {
          put("codec", stats.codec.name)
          put("width", stats.width)
          put("height", stats.height)
          put("profile", stats.profileName)
          put("level", stats.levelName)
          put("name", stats.decoder.name)
          put("kind", stats.decoder.kind?.name)
          put("lowLatency", stats.decoder.lowLatency)
          put("lowLatencyFeature", stats.decoder.lowLatencyFeature)
          put("operatingRate", stats.decoder.operatingRate)
          put("configurationLevel", stats.decoder.configurationLevel)
          put("frameRateAsked", stats.decoder.frameRateAsked)
          put("switches", stats.decoder.switches)
          put("switchReason", stats.decoder.lastSwitchReason?.name)
          put("skippedAtStart", JsonArray(stats.decoder.skippedAtStart.map { JsonPrimitive(it.toString()) }))
          put("units", stats.unitsIn)
          put("queued", stats.queued)
          put("decoded", stats.decoded)
          put("shown", stats.shown)
          put("droppedAtDisplay", stats.droppedAtDisplay)
          put("overruns", stats.overruns)
          put("unitsDropped", stats.decoder.unitsDropped)
          put("primers", stats.decoder.primers)
          put("errors", stats.errors)
          put("lostPictures", stats.lostPictures)
          put("encoderRestarts", stats.encoderRestarts)
          put("picturesPerSecond", stats.picturesPerSecond)
          put("decodeMedianMs", stats.decodeMedianMs)
          put("decodeP95Ms", stats.decodeP95Ms)
          put("firstPictureMs", stats.firstPictureMs)
          put("lastOutputAgoMs", stats.lastOutputAgoMs)
        },
      )
      if (lastTelemetry != null) {
        put(
          "lastTelemetry",
          RelayTelemetry.build(
            phoneNs = lastTelemetry.phoneNs,
            sequence = lastTelemetry.sequence,
            link = lastTelemetry.link,
            values = lastTelemetry.values,
            phoneVideo = lastTelemetry.phoneVideo,
            headsets = lastTelemetry.headsets,
            unitsDropped = lastTelemetry.unitsDropped,
            ring = lastTelemetry.obstacleRing,
          ),
        )
      }
    }
    return json.toString()
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
    if (receiver.active) {
      // A plug ends the reception of a phone's relay: one source at a time
      disconnectRelay()
    }
    synchronized(gate) {
      decoder.reset()
      router.restartStreams()
      video.newStream()
      capture.mark(CaptureDirection.OPEN)
      controlCapture.mark(CaptureDirection.OPEN)
      session.onOpened(System.currentTimeMillis())
    }
    setRelaySource(RelaySource.CABLE)
    markDirty()
  }

  /** A new source for the headsets: their decoders stop and wait for the parameter sets of the new one */
  private fun setRelaySource(next: RelaySource) {
    if (relay.source == next) {
      return
    }
    relay.source = next
    relay.reset()
  }

  override fun onClosed(reason: LinkReason) {
    synchronized(gate) {
      capture.mark(CaptureDirection.CLOSE)
      controlCapture.mark(CaptureDirection.CLOSE)
      session.onClosed(reason.name, System.currentTimeMillis())
    }
    if (!player.loaded) {
      setRelaySource(RelaySource.NONE)
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
        if (Channels.role(envelope.channel) == ChannelRole.CONTROL) {
          controlCapture.record(CaptureDirection.IN, EnvelopeDecoder.encode(envelope.channel, envelope.payload))
        }
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
    val nowNs = SystemClock.elapsedRealtimeNanos()
    // A picture out of the decoder in the last 4 s keeps the tick going whatever stopped it, so that the last snapshot
    // the page gets is never one of a picture that still looks live
    if (!started && !player.loaded && !receiver.active && !relay.isRunning &&
      !videoStatistics.outputWithin(nowNs, 2 * VIDEO_READY_WINDOW_NS)
    ) {
      return
    }
    val linked: Boolean
    val pictures: Boolean
    val active: Boolean
    synchronized(gate) {
      linked = router.aircraftLinked(nowNs / 1_000_000)
      pictures = !player.loaded && videoStatistics.outputWithin(nowNs, VIDEO_READY_WINDOW_NS)
      // A few seconds after the last picture, so that the rates of the panel come down to zero on the page
      active = player.playing || videoStatistics.outputWithin(nowNs, 2 * VIDEO_READY_WINDOW_NS) ||
        (started && router.counters.envelopes > 0) || receiver.active || relay.isRunning
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
    checkIdleRelay()
    handler.postDelayed(tick, TICK_MS)
  }

  /** Nothing to send and no headset for 10 minutes: the relay stops by itself and Flutter is told, as for Stop */
  private fun checkIdleRelay() {
    val idle = relay.isRunning && relay.source == RelaySource.NONE && relay.headsetCount == 0
    if (!relayIdle.expired(idle, SystemClock.elapsedRealtime())) {
      return
    }
    Log.i(TAG, "nothing to send and no headset for 10 minutes: the relay stops")
    stopRelay()
    runCatching { events?.relayStopRequested { } }
  }

  private fun scheduleTick() {
    handler.post {
      handler.removeCallbacks(tick)
      handler.postDelayed(tick, TICK_MS)
    }
  }

  /** The TELEMETRY body of the relay, built on its tick thread: values, link, and this phone's own video numbers */
  private fun relayTelemetryBody(sequence: Long): ByteArray {
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val nowMs = nowNs / 1_000_000
    val json = synchronized(gate) {
      val relayed = relay.source
      val source = if (player.loaded) player.router else router
      val stats = video.stats(nowNs, source.assemblerCounters().unitsTooLarge)
      RelayTelemetry.build(
        phoneNs = nowNs,
        sequence = sequence,
        link = RelayLinkFacts(
          source = relayed.wire,
          state = RelayTelemetry.stateName(state),
          aircraft = source.aircraftLinked(nowMs),
          remote = source.remotePresent(nowMs),
          replayName = if (player.loaded) player.name else null,
          replayPositionMs = if (player.loaded) player.positionMs else null,
          codec = codecName(stats.codec),
        ),
        values = if (relayed == RelaySource.NONE) null else source.telemetryDecoder.values(nowMs),
        phoneVideo = RelayPhoneVideo.of(stats),
        headsets = relay.headsetCount,
        unitsDropped = relay.unitsDropped,
        ring = ring.let { RelayObstacleRing(it.offered, it.farM, it.nearM, it.directional) },
      )
    }
    return RelayWire.jsonBody(json)
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
      .put("unitsDropped", stats.decoder.unitsDropped)
      .put("tooLarge", stats.tooLarge)
      .put("errors", stats.errors)
      .put("decoderName", stats.decoder.name ?: JSONObject.NULL)
      .put("decoderKind", stats.decoder.kind?.name ?: JSONObject.NULL)
      .put("lowLatency", stats.decoder.lowLatency)
      .put("switches", stats.decoder.switches)
      .put("switchReason", stats.decoder.lastSwitchReason?.name ?: JSONObject.NULL)
      .put("skippedAtStart", JSONArray(stats.decoder.skippedAtStart))
      .put("primers", stats.decoder.primers)
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
    // Every receiver of the relay, those that left included, with this phone's Wi-Fi (relay-smoothness, 6.1)
    val relayJson = JSONObject(
      buildJsonObject {
        relay.report(nowNs).forEach { (key, value) -> put(key, value) }
        put("wifiLowLatencyLockHeld", DjiLinkRelayService.wifiLockHeld)
        put("network", currentNetworkFacts()?.toJson() ?: JsonNull)
      }.toString(),
    )
    return linkedMapOf(
      "lastAccessory" to lastJson,
      "relay" to relayJson,
      "stream" to JSONObject(video.facts.toJson().toString()),
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
      television = it.television,
    )
  }

  fun snapshot(): DjiLinkSnapshot {
    // Read outside the page lock: a service call never holds the reader thread
    val network = if (receiver.active) currentNetworkFacts() else networkFacts
    return synchronized(gate) { buildSnapshot(network) }
  }

  private fun buildSnapshot(network: NetworkFacts?): DjiLinkSnapshot {
    val nowNs = SystemClock.elapsedRealtimeNanos()
    val nowMs = nowNs / 1_000_000
    val envelope = decoder.counters
    val control = router.controlCounters()
    val routed = router.counters
    val latest = sticks.latest()
    // The video and the flight values come from the capture being played, when one is; the traffic stays the cable's
    val source = if (player.loaded) player.router else router
    val probeReport = source.probe.report()
    val receiving = receiver.active
    val tooLarge = if (receiving) 0 else source.assemblerCounters().unitsTooLarge
    val received = receiver.snapshot(nowNs)
    val stats = video.stats(nowNs, tooLarge)
    return DjiLinkSnapshot(
      state = state.toPigeon(),
      reason = reason.toPigeon(),
      detail = argument,
      accessory = identity?.toPigeon(),
      profile = profile?.toPigeon(environment.runningDevice),
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
      videoDecode = stats.toPigeon(),
      telemetryValues = if (receiving) {
        received.telemetry?.let { record ->
          telemetryPigeon(
            values = record.aged(received.telemetryAgeMs ?: 0),
            aircraftPresent = record.link.aircraft && (received.telemetryAgeMs ?: Long.MAX_VALUE) < STALE_RELAY_MS,
            remotePresent = record.link.remote && (received.telemetryAgeMs ?: Long.MAX_VALUE) < STALE_RELAY_MS,
            unanswered = emptyList(),
          )
        }
      } else {
        telemetryPigeon(
          values = source.telemetryDecoder.values(nowMs),
          aircraftPresent = source.aircraftLinked(nowMs),
          remotePresent = source.remotePresent(nowMs),
          unanswered = source.requestRows(),
        )
      },
      source = DjiLinkSource(
        replay = player.loaded,
        playing = player.playing,
        name = player.name,
        positionMs = if (player.loaded) player.positionMs else null,
        durationMs = if (player.loaded) player.durationMs else null,
        failure = if (player.loaded) player.failure else null,
        relay = receiving,
        phoneName = if (receiving) received.phoneName else null,
        loop = player.looping,
      ),
      relaySending = relay.snapshot(nowNs).toPigeon(DjiLinkRelayService.wifiLockHeld),
      relayReceiving = if (received.state == RelayReceiveState.IDLE && !receiving) {
        null
      } else {
        val smoothing = feed.smoothingNumbers(nowNs)
        received.toPigeon(
          stats = stats,
          delay = shownDelay(received, stats, smoothing),
          smoothing = smoothing,
          lastPictureAgoMs = ShownDelay.pictureAgoMs(receiving, smoothing, stats.lastOutputAgoMs),
          network = network,
          refreshHz = displayWatch.refreshHz,
        )
      },
      flightViewFailed = DjiFlightViewActivity.lastFailed,
      liveFrame = liveFramePigeon(
        values = if (receiving) {
          received.telemetry?.aged(received.telemetryAgeMs ?: 0)
        } else {
          source.telemetryDecoder.values(nowMs)
        },
        decision = lastDecision,
        atMs = nowMs,
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

/**
 * The profile as the page shows it on [device]: each answer holds on the device and flavour of its observation only,
 * so the same profile reads unknown on the headset build or on another phone, with the device it was verified on.
 */
internal fun DeviceProfile.toPigeon(device: RunningDevice): DjiLinkProfile = DjiLinkProfile(
  id = id,
  label = label,
  note = note,
  capabilities = Capability.entries.map { capability ->
    val state = capabilities[capability] ?: CapabilityState.unknown
    DjiLinkCapability(
      name = capability.name,
      support = when (state.on(device)) {
        Support.UNKNOWN -> DjiLinkSupport.UNKNOWN
        Support.UNSUPPORTED -> DjiLinkSupport.UNSUPPORTED
        Support.SUPPORTED -> DjiLinkSupport.SUPPORTED
      },
      provenance = state.provenance?.let { "${it.observationId} (${it.date})" },
      observedOn = state.provenance?.device?.verifiedOn,
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
    DecoderPolicy.SwitchReason.NO_PICTURE_WITH_KEY -> "noPictureWithKey"
    DecoderPolicy.SwitchReason.NO_PICTURE_NOTHING_LEFT -> "noPictureNothingLeft"
    // No switch in this session, but it did not start with the first decoder of the order
    null -> if (decoder.skippedAtStart.isNotEmpty()) "rememberedNoPicture" else null
  },
  unitsIn = unitsIn,
  queued = queued,
  decoded = decoded,
  shown = shown,
  droppedAtDisplay = droppedAtDisplay,
  overruns = overruns,
  unitsDropped = decoder.unitsDropped,
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

/**
 * The values a pilot reads, as the gate of dji_live_fields.dart takes them: a group that is stale or never came gives
 * nulls, never an old number. The speed over ground counts only while the motors run: on the ground the drone holds the
 * last speed it had (p2/telemetry-deep-dive-2026-10-24.md, 3.1).
 */
internal fun liveFramePigeon(values: TelemetryValues?, decision: ObstacleDecision, atMs: Long): DjiLiveFrame {
  fun <T> Timed<T>?.fresh(): T? = this?.takeIf { !it.stale }?.value
  val flight = values?.flight.fresh()
  val battery = values?.battery.fresh()
  return DjiLiveFrame(
    atMs = atMs,
    alert = decision.toPigeon(),
    droneBatteryPercent = battery?.percent?.toLong(),
    batteryVolts = battery?.voltageV,
    batteryTemperatureC = battery?.temperatureC,
    motorTimeS = flight?.motorTimeS,
    motorsOn = flight?.motorsOn,
    headingDeg = flight?.headingDeg,
    heightM = flight?.heightM,
    verticalSpeedMps = flight?.verticalSpeedMps,
    speedMps = flight?.takeIf { it.motorsOn }?.horizontalSpeedMps,
    distanceBelowM = values?.rangeBelow.fresh()?.distanceM,
    obstacleM = values?.obstacles.fresh()?.nearestM,
    remoteBatteryPercent = values?.remoteBatteryPercent.fresh()?.toLong(),
    signal = values?.link?.signalRemoteSide.fresh()?.toLong(),
    signalBars = values?.signalBars.fresh()?.toLong(),
    linkRateMbps = values?.link?.liveRateMbps.fresh(),
    satellites = flight?.satellites?.toLong(),
    landing = flight?.mode == TelemetryFields.MODE_AUTOMATIC_LANDING,
  )
}

internal fun ObstacleDecision.toPigeon(): DjiObstacleDecision = DjiObstacleDecision(
  on = on,
  stopped = stopped,
  listening = listening,
  even = even,
  arcs = arcs.map { arc ->
    DjiObstacleArc(
      centreDeg = arc.centreDeg,
      distanceM = arc.distanceM,
      strength = arc.strength,
      opacity = arc.opacity,
      // Unsigned, as Flutter's Color takes it
      argb = arc.argb.toLong() and 0xFFFFFFFFL,
    )
  },
  nearestM = nearestM,
  tickIntervalMs = tickIntervalMs.toLong(),
)

internal fun telemetryPigeon(
  values: TelemetryValues,
  aircraftPresent: Boolean,
  remotePresent: Boolean,
  unanswered: List<RequestRow>,
): DjiLinkTelemetry {
  val link = values.link
  val clock = link.aircraftClockMs
  return DjiLinkTelemetry(
    aircraftPresent = aircraftPresent,
    remotePresent = remotePresent,
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
    remoteBatteryAgeMs = values.remoteBatteryPercent?.ageMs,
    unanswered = unanswered.map {
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

internal fun codecName(codec: VideoCodec): String = when (codec) {
  VideoCodec.H265 -> "h265"
  VideoCodec.H264 -> "h264"
  VideoCodec.UNKNOWN -> "unknown"
}

private fun RelaySendingSnapshot.toPigeon(wifiLowLatencyHeld: Boolean): DjiRelaySending = DjiRelaySending(
  on = on,
  port = port?.toLong(),
  sending = source.wire,
  headsets = headsets.map {
    val said = it.receiver
    DjiRelayHeadsetRow(
      address = it.address,
      name = it.name,
      connectedForMs = it.connectedForMs,
      picturesShownPerSecond = it.picturesShownPerSecond,
      relayDelayMs = it.relayDelayMs,
      droppedUnits = it.droppedUnits,
      megabitsPerSecond = it.megabitsPerSecond,
      screenCodeId = it.screenCodeId,
      kind = it.kind,
      queueAgeMs = it.queueAgeMs,
      queueMaxAgeMs = it.queueMaxAgeMs,
      dropEvents = it.dropEvents,
      writeStalls = it.writeStalls,
      writeP95Ms = it.writeP95Ms,
      roundTripMs = said?.roundTripUs?.takeIf { us -> us >= 0 }?.let { us -> us / 1000.0 },
      receiverBufferMs = said?.bufferTargetMs?.takeIf { ms -> ms >= 0 }?.toDouble(),
      receiverFreezes = said?.freezes?.takeIf { count -> count >= 0 }?.toLong(),
      receiverLongestFreezeMs = said?.longestFreezeMs?.takeIf { ms -> ms >= 0 }?.toLong(),
      receiverSkips = said?.renderSkips?.takeIf { count -> count >= 0 }?.toLong(),
      receiverLate = said?.lateUnits?.takeIf { count -> count >= 0 }?.toLong(),
    )
  },
  refusedProofs = refusedProofs,
  unexpectedRecords = unexpectedRecords,
  wifiLowLatencyHeld = wifiLowLatencyHeld,
  unitsDropped = unitsDropped,
)

private fun RelayReceiveState.toPigeon(): DjiRelayReceiveState = when (this) {
  RelayReceiveState.IDLE -> DjiRelayReceiveState.IDLE
  RelayReceiveState.CONNECTING -> DjiRelayReceiveState.CONNECTING
  RelayReceiveState.CHECKING_CODE -> DjiRelayReceiveState.CHECKING_CODE
  RelayReceiveState.RECEIVING -> DjiRelayReceiveState.RECEIVING
  RelayReceiveState.LOST -> DjiRelayReceiveState.LOST
  RelayReceiveState.WRONG_CODE -> DjiRelayReceiveState.WRONG_CODE
  RelayReceiveState.FULL -> DjiRelayReceiveState.FULL
  RelayReceiveState.BLOCKED -> DjiRelayReceiveState.BLOCKED
  RelayReceiveState.OTHER_VERSION -> DjiRelayReceiveState.OTHER_VERSION
  RelayReceiveState.PHONE_UNPROVEN -> DjiRelayReceiveState.PHONE_UNPROVEN
  RelayReceiveState.BUSY -> DjiRelayReceiveState.BUSY
}

/**
 * The receiver with the latency lines of the window page: [stats] are this device's own decoding numbers, [delay] the
 * phone receive to picture shown, [smoothing] the jitter buffer's numbers, [lastPictureAgoMs] the age of the last
 * picture shown
 */
private fun RelayReceiveSnapshot.toPigeon(
  stats: VideoStats,
  delay: ShownDelay,
  smoothing: SmoothingNumbers,
  lastPictureAgoMs: Long?,
  network: NetworkFacts?,
  refreshHz: Float?,
): DjiRelayReceiving {
  val numbers = latency
  val phone = telemetry?.phoneVideo
  return DjiRelayReceiving(
    state = state.toPigeon(),
    phoneName = phoneName,
    phoneId = phoneId,
    host = host,
    port = port?.toLong(),
    phoneSource = phoneSource,
    replay = phoneSource == RelaySource.REPLAY.wire,
    replayName = replayName,
    replayPositionMs = replayPositionMs,
    reconnectInMs = reconnectInMs,
    failures = failures.toLong(),
    units = units,
    lostOnWifi = lostOnWifi,
    relayDelayMedianMs = numbers.relayDelayMedianMs,
    relayDelayP95Ms = numbers.relayDelayP95Ms,
    phoneQueueMedianMs = numbers.phoneQueueMedianMs,
    networkMedianMs = numbers.networkMedianMs,
    networkP95Ms = numbers.networkP95Ms,
    clockUncertaintyMs = numbers.clockUncertaintyMs,
    arrivalSpreadMedianMs = numbers.arrivalSpreadMedianMs,
    phoneInProcessMedianMs = phone?.inProcessMedianMs,
    phoneDecodeMedianMs = phone?.decodeMedianMs,
    receiveToPictureMs = delay.medianMs,
    receiveToPictureNowMs = delay.nowMs,
    receiveToPictureEstimateMs = delay.estimateMs,
    behindPhoneMs = RelayLatencyNumbers.behindPhone(delay.medianMs, phone?.inProcessMedianMs, phone?.decodeMedianMs),
    lastPictureAgoMs = lastPictureAgoMs,
    receivedPerSecond = numbers.unitsPerSecond,
    decodedPerSecond = stats.decodedPerSecond,
    shownPerSecond = stats.shownPerSecond,
    // What the radio lost, as the phone counts it; this device's own count when no telemetry came yet
    lostOnRadio = phone?.lostPictures ?: stats.lostPictures,
    paced = smoothing.paced,
    bufferTargetMs = smoothing.targetMs,
    bufferNowMs = smoothing.depthNowMs,
    bufferP95Ms = smoothing.depthP95Ms,
    lateUnits = smoothing.lateUnits,
    renderSkips = smoothing.renderSkips,
    decoderStalls = smoothing.decoderStalls,
    safetyFlushes = smoothing.safetyFlushes,
    safetyNetAgoMs = smoothing.safetyNetAgoMs?.toLong(),
    freezes = smoothing.freezes,
    longestFreezeMs = smoothing.longestFreezeMs,
    freezesInSource = smoothing.freezesInSource,
    breaks = breaks,
    primers = primers,
    primersUsed = smoothing.primersAfterBreak,
    network = network?.transport,
    wifiBand = network?.band,
    wifiLinkMbps = network?.linkMbps?.toLong(),
    wifiRssi = network?.rssiDbm?.toLong(),
    refreshHz = refreshHz?.toDouble(),
  )
}

/**
 * Whether the obstacle sound cannot be heard at this media volume: at zero, unless the device's volume is fixed (an
 * HDMI box, a TV whose sound goes to a sound bar), where the reading says nothing. Pure, unit tested.
 */
internal fun mediaVolumeSilent(volumeFixed: Boolean, volume: Int): Boolean = !volumeFixed && volume == 0
