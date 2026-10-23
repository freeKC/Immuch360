package app.alextran.immich.djilink

import android.content.Context
import android.content.SharedPreferences
import android.net.wifi.WifiManager
import android.os.Build
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
  private val videoStatistics = VideoStatistics()
  private val feed = VideoDecoderFeed(videoStatistics, onChange = { markDirty() })
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
    // DJI application. The package manager keeps that setting across process deaths.
    DjiLinkApiImpl.setAttachEntryEnabled(context, false)
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
    // Under the page lock, as the reader thread records: whether a session is under way cannot change meanwhile
    synchronized(gate) { capture.clear(accessoryOpen = manager.transport?.isRunning == true) }
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
    val port = runCatching { relay.start(code) }.getOrElse {
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
    synchronized(gate) { startRelayedSource() }
    relay.source = RelaySource.NONE
    receiver.connect(host, port, normalized, phoneId, headsetName, environment.appVersion)
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
    feed.open()
    synchronized(shownHistory) { shownHistory.clear() }
  }

  private inner class ReceiverEvents : RelayReceiver.Listener {
    override fun onConnected(welcome: RelayWelcome) {
      synchronized(gate) { startRelayedSource() }
      markDirty()
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
      markDirty()
    }

    override fun onEnded(state: RelayReceiveState) {
      handler.post { endReception() }
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
    val receiveToPicture = RelayLatencyNumbers.receiveToPicture(
      received.latency.relayDelayMedianMs,
      stats.inProcessMedianMs,
      stats.decodeMedianMs,
    )
    return DjiFlightNumbers(
      receiving = receiving,
      localReplay = player.loaded,
      state = received.state,
      replay = received.phoneSource == RelaySource.REPLAY.wire,
      phoneHasSource = received.phoneSource != RelaySource.NONE.wire,
      replayName = received.replayName,
      lastPictureAgoMs = stats.lastOutputAgoMs,
      picturesPerSecond = stats.picturesPerSecond,
      receiveToPictureMs = receiveToPicture,
      values = values,
    )
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
    if (receiver.active) {
      // A plug ends the reception of a phone's relay: one source at a time
      disconnectRelay()
    }
    synchronized(gate) {
      decoder.reset()
      router.restartStreams()
      video.newStream()
      capture.mark(CaptureDirection.OPEN)
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
        received.toPigeon(stats)
      },
      flightViewFailed = DjiFlightViewActivity.lastFailed,
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
    null -> null
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
    DjiRelayHeadsetRow(
      address = it.address,
      name = it.name,
      connectedForMs = it.connectedForMs,
      picturesShownPerSecond = it.picturesShownPerSecond,
      relayDelayMs = it.relayDelayMs,
      droppedUnits = it.droppedUnits,
      megabitsPerSecond = it.megabitsPerSecond,
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

/** The receiver with the latency lines of the window page: [stats] are this device's own decoding numbers */
private fun RelayReceiveSnapshot.toPigeon(stats: VideoStats): DjiRelayReceiving {
  val numbers = latency
  val receiveToPicture = RelayLatencyNumbers.receiveToPicture(
    numbers.relayDelayMedianMs,
    stats.inProcessMedianMs,
    stats.decodeMedianMs,
  )
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
    receiveToPictureMs = receiveToPicture,
    behindPhoneMs = RelayLatencyNumbers.behindPhone(receiveToPicture, phone?.inProcessMedianMs, phone?.decodeMedianMs),
    lastPictureAgoMs = stats.lastOutputAgoMs,
    receivedPerSecond = numbers.unitsPerSecond,
    decodedPerSecond = stats.decodedPerSecond,
    shownPerSecond = stats.shownPerSecond,
    // What the radio lost, as the phone counts it; this device's own count when no telemetry came yet
    lostOnRadio = phone?.lostPictures ?: stats.lostPictures,
  )
}
