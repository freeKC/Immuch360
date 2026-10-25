package app.alextran.immich.djilink

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/** What the phone relays: nothing, the remote's live video, or a capture being played */
enum class RelaySource(val wire: String) {
  NONE("none"),
  CABLE("cable"),
  REPLAY("replay"),
}

/** What the welcome says of the phone, asked for each headset that proves the code */
data class RelayWelcomeFacts(
  val phoneName: String,
  val phoneId: String?,
  val replayName: String?,
)

/**
 * A TV the pilot added on the phone (p2/design-tv-2026-10-24.md, 2.4): the code the TV made itself and shows with a QR
 * code, kept under an opaque id. The relay accepts a proof of it as well as a proof of the phone's own code.
 */
data class RelayScreenCode(val id: String, val code: String)

/** One headset or TV as the phone's page shows it */
data class RelayHeadsetRow(
  val address: String,
  val name: String?,
  val connectedForMs: Long,
  /** From its pings: pictures it showed per second over its last 10 s */
  val picturesShownPerSecond: Double?,
  /** From its pings: how long after this phone it receives the pictures */
  val relayDelayMs: Double?,
  val droppedUnits: Long,
  val megabitsPerSecond: Double,
  /** The id of the screen code it proved; null for the phone's own code (a headset, or a TV that typed it) */
  val screenCodeId: String? = null,
  /** What its hello says it is: "tv" from a TV of this build, null otherwise */
  val kind: String? = null,
  /** The age of the oldest unit queued for it now, null when none waits */
  val queueAgeMs: Double? = null,
  val queueMaxAgeMs: Double? = null,
  val dropEvents: Long = 0,
  /** Writes of a unit that took over 200 ms */
  val writeStalls: Long = 0,
  val writeP95Ms: Double? = null,
  val sendBufferBytes: Int? = null,
  /** From its long pings, null from a receiver of an earlier build */
  val receiver: RelayPingNumbers? = null,
  /** The stream it gets: full or steady (p2/relay-bandwidth-2026-10-25.md, 7.10) */
  val stream: String = RelayStream.FULL.wire,
  /** Its hello says it takes the steady stream; false for a receiver of an earlier build */
  val steadyCapable: Boolean = false,
  /** Since it is on this stream */
  val streamForMs: Long? = null,
  /** The best second its socket carried in the last 2 minutes */
  val bestSecondMegabits: Double? = null,
  /** The rate its link allows the steady stream, while it is on it */
  val allowedMegabits: Double? = null,
  /** Its own Wi-Fi, from its 96 byte pings */
  val network: RelayPingNetwork? = null,
)

data class RelaySendingSnapshot(
  val on: Boolean,
  val port: Int?,
  val source: RelaySource,
  val headsets: List<RelayHeadsetRow>,
  val refusedProofs: Long,
  val unexpectedRecords: Long,
  val unitsDropped: Long,
  /** Key units sent ahead of the live ones: to receivers that joined, and after drops */
  val primersSent: Long = 0,
  /** "Relay quality" */
  val quality: RelayQuality = RelayQuality.AUTOMATIC,
  /** The steady stream's line, null on a phone that has none to describe */
  val steadyLine: RelaySteadyLine? = null,
  /** What the drone sent in the last second */
  val droneMegabitsPerSecond: Double? = null,
)

/**
 * The send side of a receiver's socket (p2/relay-smoothness-2026-10-25.md, 5.2 item 1): the send buffer is left to the
 * kernel's tuning, and only the unsent bytes are bounded with TCP_NOTSENT_LOWAT, through android.system.Os on a
 * duplicate of the socket's descriptor. Where that is refused, a fixed send buffer is asked instead. The send buffer
 * the kernel granted is read back for the export.
 */
object RelaySocketTuning {
  /** TCP_NOTSENT_LOWAT of Linux (include/uapi/linux/tcp.h), which android.system.OsConstants does not name */
  private const val TCP_NOTSENT_LOWAT = 25

  fun tune(socket: Socket): RelaySocketFacts {
    val lowWater = runCatching {
      val duplicate = android.os.ParcelFileDescriptor.fromSocket(socket)
      try {
        val tcp = android.system.OsConstants.IPPROTO_TCP
        val bytes = RelayWire.NOT_SENT_LOW_WATER_BYTES
        // No exception: the kernel took it (the getter of an int option is not public, so it is not read back)
        android.system.Os.setsockoptInt(duplicate.fileDescriptor, tcp, TCP_NOTSENT_LOWAT, bytes)
        bytes
      } finally {
        runCatching { duplicate.close() }
      }
    }.getOrNull()?.takeIf { it > 0 }
    if (lowWater == null) {
      runCatching { socket.sendBufferSize = RelayWire.FALLBACK_SEND_BUFFER_BYTES }
    }
    return RelaySocketFacts(runCatching { socket.sendBufferSize }.getOrNull(), lowWater)
  }

  /**
   * The unsent bytes bound of a steady receiver, set again as its rate changes (p2/relay-bandwidth-2026-10-25.md, 7.6);
   * false when refused
   */
  fun setLowWater(socket: Socket, bytes: Int): Boolean = runCatching {
    val duplicate = android.os.ParcelFileDescriptor.fromSocket(socket)
    try {
      val tcp = android.system.OsConstants.IPPROTO_TCP
      android.system.Os.setsockoptInt(duplicate.fileDescriptor, tcp, TCP_NOTSENT_LOWAT, bytes)
      true
    } finally {
      runCatching { duplicate.close() }
    }
  }.getOrDefault(false)
}

/**
 * The phone side of relay protocol 1 ([RelayWire]): it listens on the local network, checks that each headset knows
 * the code, and sends every unit the phone decodes, with the description it decodes it with, to each headset through
 * its own bounded queue. It is the relay half of the tee ([TeeSink]): [submit] takes each headset's lock for a few
 * microseconds and returns, so a slow headset never slows the phone, the cable or the other headsets.
 *
 * Receive only toward the remote: this class has no reference to the transport, the accessory manager or the USB
 * service, and what a headset may send is the hello, its pings and its bye; anything else closes that connection.
 *
 * Who may connect: an address of the local network ([RelayWire.isLocalNetworkAddress]) arriving on an interface that
 * is neither mobile data nor a VPN; a headset that proves the code, or a TV that proves one of the screen codes the
 * pilot added ([setScreenCodes]), within [helloTimeoutMs] of its connection (a deadline the tick enforces, whatever the
 * pace of the bytes); at most [maxHandshakes] handshakes at once, of which
 * [maxHandshakesPerAddress] from one address, and [maxHeadsets] headsets; [failureLimit] wrong proofs or missed
 * deadlines from one address within [failureWindowNs] block it for [blockNs] (the phone share's numbers).
 */
class RelayServer(
  private val clockNs: () -> Long = { System.nanoTime() },
  private val random: SecureRandom = SecureRandom(),
  private val addressRule: (Socket) -> Boolean = ::localNetworkOnly,
  private val helloTimeoutMs: Int = 5_000,
  private val pingTimeoutMs: Int = 5_000,
  private val writerStallNs: Long = 3_000_000_000L,
  private val maxHeadsets: Int = 4,
  private val maxHandshakes: Int = 8,
  private val maxHandshakesPerAddress: Int = 2,
  private val failureLimit: Int = 10,
  private val failureWindowNs: Long = 60_000_000_000L,
  private val blockNs: Long = 60_000_000_000L,
  /** The TELEMETRY body of tick [sequence]; null sends none */
  private val telemetry: (sequence: Long) -> ByteArray? = { null },
  private val welcomeFacts: () -> RelayWelcomeFacts = { RelayWelcomeFacts("phone", null, null) },
  private val onChange: () -> Unit = {},
  /** False in the tests that drive [tick] themselves */
  private val runTicker: Boolean = true,
  /** The age bound of every receiver's queue; null takes the one of its kind ([RelayQueue.maxAgeFor]) */
  private val queueMaxAgeNs: Long? = null,
  private val queueMaxBytes: Long = RelayQueue.MAX_BYTES,
  private val socketTuning: (Socket) -> RelaySocketFacts = RelaySocketTuning::tune,
  /** The phone's steady stream (p2/relay-bandwidth-2026-10-25.md, 7); null: the full stream only */
  private val steady: RelaySteadySource? = null,
  private val lowWaterTuning: (Socket, Int) -> Boolean = RelaySocketTuning::setLowWater,
) : DecoderSink {
  companion object {
    private const val TAG = "DjiRelay"
    const val TELEMETRY_INTERVAL_NS = 100_000_000L
    const val IDLE_TELEMETRY_INTERVAL_NS = 1_000_000_000L

    /** Loopback or a private address, arriving on an interface that is not mobile data or a VPN */
    fun localNetworkOnly(socket: Socket): Boolean {
      if (!RelayWire.isLocalNetworkAddress(socket.inetAddress)) {
        return false
      }
      val local: InetAddress = socket.localAddress ?: return false
      val name = runCatching { NetworkInterface.getByInetAddress(local)?.name }.getOrNull()
      return !RelayWire.isSkippedInterface(name)
    }

    /** The TVs a phone keeps at most */
    const val MAX_SCREEN_CODES = 8

    /** The screen codes kept: codes of the pairing alphabet under a short id, one per id, [MAX_SCREEN_CODES] at most */
    fun validScreenCodes(codes: List<RelayScreenCode>): List<RelayScreenCode> = codes
      .filter { it.id.isNotEmpty() && it.id.length <= 64 && RelayWire.normalizeCode(it.code) == it.code }
      .distinctBy { it.id }
      .take(MAX_SCREEN_CODES)

    /** What a hello may say it is: a short lower case word, anything else is dropped */
    private val KIND = Regex("[a-z]{1,16}")

    /** Receivers that left, kept for the export */
    const val LEFT_KEPT = 8

    private fun log(message: String) {
      runCatching { android.util.Log.i(TAG, message) }
    }
  }

  /** The code a connection proved: this phone's own ([screenId] null) or the screen code of [screenId] */
  internal class ProvedCode(val code: String, val screenId: String?)

  private val lock = Any()
  private val headsets = mutableListOf<RelayHeadset>()

  /** The receivers that left since the relay started, newest last, for the export */
  private val left = ArrayDeque<RelayHeadset>()
  private var reserved = 0
  private val handshakes = AtomicInteger()
  private val numbers = AtomicInteger()
  private val failures = HashMap<String, ArrayDeque<Long>>()
  private val blockedUntil = HashMap<String, Long>()

  /** A connection between its accept and its welcome, closed by the tick once its deadline passed */
  private class Handshake(val socket: Socket, val address: String, val startedNs: Long)

  /** The handshakes under way, under [lock] */
  private val pending = mutableListOf<Handshake>()

  @Volatile
  private var serverSocket: ServerSocket? = null

  @Volatile
  private var code: String? = null

  /** The TVs the pilot added: a proof of one of their codes is welcomed too */
  @Volatile
  private var screenCodes: List<RelayScreenCode> = emptyList()

  @Volatile
  private var running = false

  /** The last description the phone resolved: sent to a headset right after its welcome */
  private var lastResolved: ResolvedDescription? = null

  /** The last key unit seen and its description, under [lock]: sent after the parameter sets to a headset that joins */
  private var lastKey: KeptKey? = null

  /** Key units sent ahead of the live units to headsets that joined mid stream ([RelayWire.UNIT_PRIMER]) */
  @Volatile
  var primersSent = 0L
    private set
  /** Kept key units sent as primers to receivers that fell back from the steady stream */
  @Volatile
  var switchPrimers = 0L
    private set
  private var telemetrySequence = 0L
  private var nextTelemetryNs = 0L
  private var droppedOfClosed = 0L

  @Volatile
  var refusedProofs = 0L
    private set

  @Volatile
  var unexpectedRecords = 0L
    private set

  /** What is being relayed; the units of a received stream are never relayed (the controller sets [RelaySource.NONE]) */
  @Volatile
  var source: RelaySource = RelaySource.NONE

  /** "Relay quality" in Advanced: Automatic by default, Full stream is the off switch */
  @Volatile
  var quality: RelayQuality = RelayQuality.AUTOMATIC

  /** Whether the drone's motors run, from the phone's telemetry; null when unknown (the phase of a flight) */
  @Volatile
  var motorsOn: Boolean? = null

  // The steady stream, under [lock]
  private val droneRates = DroneRateMemory()
  private val steadyMemory = RelaySteadyMemory()
  private val encoderRate = RelayEncoderRate()
  private var lastSteady: ResolvedDescription? = null
  private val droneSent = ArrayDeque<LongArray>()
  private var nextDroneSecondNs = 0L
  private var steadyUnits = 0L

  val isRunning: Boolean get() = running

  val port: Int? get() = serverSocket?.localPort

  val headsetCount: Int get() = synchronized(lock) { headsets.size }

  /**
   * Listens on every interface, on [preferredPort] when it is free, else on any free port; returns the port. Already
   * running, it only takes the code and the screen codes.
   */
  fun start(
    code: String,
    preferredPort: Int = RelayWire.DEFAULT_PORT,
    bindAddress: InetAddress? = null,
    screens: List<RelayScreenCode> = emptyList(),
  ): Int {
    require(RelayWire.normalizeCode(code) == code) { "a code of the pairing alphabet" }
    serverSocket?.let { existing ->
      if (running) {
        setCode(code)
        setScreenCodes(screens)
        return existing.localPort
      }
    }
    val any = bindAddress ?: InetAddress.getByAddress(byteArrayOf(0, 0, 0, 0))
    val socket = runCatching { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(any, preferredPort)) } }
      .getOrElse { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(any, 0)) } }
    this.code = code
    screenCodes = validScreenCodes(screens)
    serverSocket = socket
    synchronized(lock) {
      // A receiver that needed the steady stream in a flight is remembered for this relay session only
      steadyMemory.clear()
      encoderRate.reset()
    }
    running = true
    nextTelemetryNs = clockNs()
    Thread({ acceptLoop(socket) }, "DjiRelayAccept").apply { isDaemon = true }.start()
    if (runTicker) {
      Thread({ tickLoop() }, "DjiRelayTick").apply { isDaemon = true }.start()
    }
    log("listening on port ${socket.localPort}")
    onChange()
    return socket.localPort
  }

  /** Stops: a bye to every headset, then the sockets close */
  fun stop(why: String = RelayWire.BYE_STOPPED) {
    if (!running) {
      return
    }
    running = false
    runCatching { serverSocket?.close() }
    serverSocket = null
    val leaving = synchronized(lock) { headsets.toList() }
    val body = RelayWire.jsonBody(buildJsonObject { put("why", why) })
    val now = clockNs()
    leaving.forEach { it.queue.finish(RelayWire.BYE, body, now) }
    // A headset whose writer is stuck does not hold the stop: its socket closes a second later anyway
    Thread({
      runCatching { Thread.sleep(1_000) }
      leaving.forEach { it.close("stopped") }
    }, "DjiRelayClose").apply { isDaemon = true }.start()
    log("stopped: $why")
    onChange()
  }

  /**
   * A new code: every headset of the old code is told so and leaves; each must prove the new code to come back. The TVs
   * that proved their own screen code stay.
   */
  fun setCode(next: String) {
    require(RelayWire.normalizeCode(next) == next) { "a code of the pairing alphabet" }
    if (next == code) {
      return
    }
    val leaving = synchronized(lock) {
      code = next
      headsets.filter { it.screenCodeId == null }
    }
    sayNewCode(leaving)
    onChange()
  }

  /**
   * The TVs the pilot added, each with its own code: a TV whose code was removed is told so (BYE newCode, which its
   * receiver reads as a refused code) and leaves; the others and the headsets stay. While the relay is off it only
   * replaces the list kept: the next [start] takes the list it is given, the phone's whole list, so that a TV removed
   * meanwhile is never welcomed.
   */
  fun setScreenCodes(next: List<RelayScreenCode>) {
    val kept = validScreenCodes(next)
    val leaving = synchronized(lock) {
      screenCodes = kept
      headsets.filter { headset -> headset.screenCodeId != null && kept.none { it.id == headset.screenCodeId } }
    }
    sayNewCode(leaving)
    if (leaving.isNotEmpty()) {
      log("${leaving.size} screen(s) removed, told to leave")
    }
    onChange()
  }

  /** The screen codes kept now, for the tests */
  internal fun screenCodesKept(): List<RelayScreenCode> = screenCodes

  private fun sayNewCode(leaving: List<RelayHeadset>) {
    if (leaving.isEmpty()) {
      return
    }
    val body = RelayWire.jsonBody(buildJsonObject { put("why", RelayWire.BYE_NEW_CODE) })
    val now = clockNs()
    leaving.forEach { it.queue.finish(RelayWire.BYE, body, now) }
  }

  /**
   * The code a hello proves: this phone's own first, then each screen code, every one compared in constant time
   * whatever matched before; null when none matches, which counts one failure whatever the number of codes
   */
  internal fun provedCode(
    own: String,
    screens: List<RelayScreenCode>,
    serverNonce: ByteArray,
    clientNonce: ByteArray,
    proof: ByteArray,
  ): ProvedCode? {
    var found: ProvedCode? = null
    val candidates = listOf(ProvedCode(own, null)) + screens.map { ProvedCode(it.code, it.id) }
    for (candidate in candidates) {
      val expected = RelayWire.proof(candidate.code, RelayWire.ROLE_HEADSET, serverNonce, clientNonce)
      if (RelayWire.proofMatches(expected, proof) && found == null) {
        found = candidate
      }
    }
    return found
  }

  // The relay half of the tee

  override fun submit(unit: AccessUnit, description: ResolvedDescription) {
    if (unit.isKey) {
      // Kept even before the relay runs: a headset that joins later starts its decoder from it
      synchronized(lock) {
        lastKey = KeptKey(unit, description.description)
      }
    }
    val relayed = source
    if (!running || relayed == RelaySource.NONE) {
      return
    }
    val now = clockNs()
    var flags = 0
    if (unit.isKey) flags = flags or RelayWire.UNIT_KEY
    if (unit.hasParameterSets) flags = flags or RelayWire.UNIT_IN_BAND
    if (relayed == RelaySource.REPLAY) flags = flags or RelayWire.UNIT_REPLAY
    var askSwitch = false
    synchronized(lock) {
      lastResolved = description
      droneSent.addLast(longArrayOf(now, unit.size.toLong()))
      trimDroneLocked(now)
      if (unit.isKey) {
        askSwitch = atDroneKeyLocked(now)
      }
      for (headset in headsets) {
        // A receiver on the phone's steady stream gets none of the drone's units
        if (headset.stream != RelayStream.FULL) {
          continue
        }
        if (unit.isKey || !description.description.sameSetsAs(headset.lastDescription)) {
          headset.queue.offerRecord(
            RelayWire.PARAMETERS,
            RelayWire.parametersFlag(description.source),
            RelayWire.parametersBody(description.description),
            now,
          )
          headset.lastDescription = description.description
        }
        headset.queue.offerUnit(unit, flags, headset.breakNext, now) { recoveryPrimer(description, relayed) }
        headset.breakNext = false
        headset.unitSinceReset = true
        headset.resetQueued = false
      }
    }
    if (askSwitch) {
      steady?.setNeeded(true, now)
      steady?.requestKey(RelayKeyCause.SWITCH, now)
    }
  }

  /**
   * Under [lock], at a drone key unit (a take off, a landing, the link start; p2/relay-bandwidth-2026-10-25.md, 7.5
   * item 3 and 7.7): a steady receiver goes back to the drone's stream at it when Automatic says so (30 s quiet, the
   * best second at least 1.5 times the drone's new rate) or the setting no longer asks for the steady stream; a
   * receiver that needed the steady stream in an earlier flight of this session starts the one taking off steady. True
   * when a switch to the steady stream is asked.
   */
  private fun atDroneKeyLocked(nowNs: Long): Boolean {
    val usable = steady?.usable == true
    val expected = droneRates.expected(motorsOn)
    var ask = false
    for (headset in headsets) {
      if (headset.stream == RelayStream.STEADY) {
        val target = relayTargetStream(quality, headset.steadyCapable, usable, headset.policy.stream)
        val back = quality == RelayQuality.AUTOMATIC &&
          headset.policy.backToFullAt(nowNs, expected, headset.stats.bestSecondBits(120, steadyOnly = true))
        if (back || target == RelayStream.FULL) {
          // The drone's parameter sets and this key unit go with BREAK: a new stream, as at every take off
          headset.queue.switchStream(toSteady = false, breakNext = headset.unitSinceReset)
          headset.recordSwitch(nowNs, RelayStream.FULL, if (back) RelaySwitchWhy.QUIET else RelaySwitchWhy.SETTING)
          headset.lastDescription = null
          headset.followLowWater(RelayWire.NOT_SENT_LOW_WATER_BYTES)
        }
      } else if (motorsOn == true && headset.pendingSteady == null && headset.steadyCapable && usable &&
        quality == RelayQuality.AUTOMATIC && headset.policy.stream == RelayStream.FULL &&
        steadyMemory.knows(steadyMemory.key(headset.name, headset.address))
      ) {
        headset.policy.goSteady()
        headset.pendingSteady = RelaySwitchWhy.MEMORY
        ask = true
      }
    }
    return ask
  }

  /**
   * A unit of the phone's steady stream (p2/relay-bandwidth-2026-10-25.md, 7.2 DjiRelayEnc), on the encoder's thread:
   * to every receiver on the steady stream, flagged as the phone's, with the parameter sets of the phone's encoder
   * before each key unit; a receiver waiting to switch to it switches at its key unit. A drop asks the encoder for a
   * key picture.
   */
  fun submitSteady(unit: AccessUnit, description: ResolvedDescription) {
    val relayed = source
    if (!running || relayed == RelaySource.NONE) {
      return
    }
    val now = clockNs()
    var flags = RelayWire.UNIT_PHONE
    if (unit.isKey) flags = flags or RelayWire.UNIT_KEY
    if (unit.hasParameterSets) flags = flags or RelayWire.UNIT_IN_BAND
    if (relayed == RelaySource.REPLAY) flags = flags or RelayWire.UNIT_REPLAY
    var dropped = false
    synchronized(lock) {
      lastSteady = description
      steadyUnits += 1
      for (headset in headsets) {
        if (headset.stream == RelayStream.FULL) {
          val why = headset.pendingSteady
          if (why == null || !unit.isKey) {
            continue
          }
          // Its full backlog goes, counted as a switch; the steady parameter sets and this key unit go with BREAK
          headset.queue.switchStream(toSteady = true, headset.steadyMaxAgeNs, breakNext = headset.unitSinceReset)
          headset.recordSwitch(now, RelayStream.STEADY, why)
          headset.pendingSteady = null
          headset.lastDescription = null
          headset.followLowWater(RelayLowWater.bytesFor(headset.rate.allowedBps))
        }
        val parameters = if (unit.isKey || !description.description.sameSetsAs(headset.lastDescription)) {
          RelayWire.parametersBody(description.description)
        } else {
          null
        }
        val offer = headset.queue.offerSteadyUnit(unit, flags, parameters, RelayWire.PARAMETERS_PHONE_ENCODER, now)
        if (offer.queued) {
          if (parameters != null) {
            headset.lastDescription = description.description
          }
          headset.unitSinceReset = true
          headset.resetQueued = false
        }
        if (offer.dropped) {
          dropped = true
        }
      }
    }
    if (dropped) {
      steady?.requestKey(RelayKeyCause.DROP, now)
    }
  }

  /**
   * Under [lock]: back to the drone's stream at once (the setting turned to Full stream, or the steady stream stopped):
   * the drone's parameter sets and the kept key unit as a primer, then the live units, as today
   */
  private fun fallbackToFullLocked(headset: RelayHeadset, why: RelaySwitchWhy, nowNs: Long) {
    headset.queue.switchStream(toSteady = false, breakNext = true)
    headset.recordSwitch(nowNs, RelayStream.FULL, why)
    headset.pendingSteady = null
    headset.policy.backToFull()
    headset.lastDescription = null
    headset.followLowWater(RelayWire.NOT_SENT_LOW_WATER_BYTES)
    val last = lastResolved ?: return
    headset.queue.offerRecord(
      RelayWire.PARAMETERS,
      RelayWire.parametersFlag(last.source),
      RelayWire.parametersBody(last.description),
      nowNs,
    )
    headset.lastDescription = last.description
    lastKey?.takeIf { it.description.sameSetsAs(last.description) }?.let { key ->
      var flags = RelayWire.UNIT_KEY or RelayWire.UNIT_PRIMER or RelayWire.UNIT_BREAK
      if (key.unit.hasParameterSets) flags = flags or RelayWire.UNIT_IN_BAND
      if (source == RelaySource.REPLAY) flags = flags or RelayWire.UNIT_REPLAY
      if (headset.queue.offerUnit(key.unit, flags, breakBefore = false, nowNs = nowNs)) {
        switchPrimers += 1
      }
    }
  }

  /** Under [lock]: the drone's units of the last second only */
  private fun trimDroneLocked(nowNs: Long) {
    while (droneSent.isNotEmpty() && nowNs - droneSent.first()[0] > 1_000_000_000L) {
      droneSent.removeFirst()
    }
  }

  /** What the drone sent in the last second, in bits */
  private fun droneBitsLocked(nowNs: Long): Long {
    trimDroneLocked(nowNs)
    return droneSent.sumOf { it[1] } * 8
  }

  /**
   * The steady stream on the tick (p2/relay-bandwidth-2026-10-25.md, 7.5 to 7.7): for each receiver that takes it,
   * Automatic's rules and the setting; the rate each steady receiver's link allows and the encoder's, its unsent bytes
   * bound, the drops the tick sees; then the transcoder's own watchdogs. Nothing here waits on a socket.
   */
  private fun manageStreams(nowNs: Long) {
    val source = steady ?: return
    val usable = source.usable
    val enabled = running && this.source != RelaySource.NONE && quality != RelayQuality.FULL
    var capable = false
    var needed = false
    var askSwitch = false
    var askDrop = false
    var slow = false
    val allowed = mutableListOf<Int>()
    synchronized(lock) {
      if (nowNs >= nextDroneSecondNs) {
        nextDroneSecondNs = nowNs + 1_000_000_000L
        droneRates.onSecond(droneBitsLocked(nowNs), motorsOn)
      }
      for (headset in headsets) {
        if (!headset.steadyCapable) {
          continue
        }
        capable = true
        val age = headset.queue.oldestUnitAgeNs(nowNs) ?: 0L
        if (headset.stream == RelayStream.STEADY) {
          if (!usable || quality == RelayQuality.FULL) {
            fallbackToFullLocked(
              headset,
              if (usable) RelaySwitchWhy.SETTING else RelaySwitchWhy.TRANSCODER,
              nowNs,
            )
            continue
          }
          needed = true
          if (headset.queue.checkSteadyAge(nowNs)) {
            askDrop = true
          }
          val drops = headset.queue.counters().steadyDrops
          val dropped = drops > headset.lastSteadyDrops
          headset.lastSteadyDrops = drops
          headset.policy.onSteadyTick(nowNs, age)
          headset.rate.onTick(nowNs, age, headset.bitsLastSecond(nowNs), headset.stats.takeLongestWrite(), dropped)
          headset.followLowWater(RelayLowWater.bytesFor(headset.rate.allowedBps))
          allowed += headset.rate.allowedBps
          if (headset.rate.slow) {
            slow = true
          }
        } else {
          val overloads = headset.queue.overloadCount
          val dropped = overloads > headset.lastOverloads
          headset.lastOverloads = overloads
          headset.stats.takeLongestWrite()
          if (!usable || !enabled) {
            headset.pendingSteady = null
            continue
          }
          if (headset.pendingSteady != null) {
            needed = true
            continue
          }
          val why = if (quality == RelayQuality.AUTOMATIC) headset.policy.onFullTick(nowNs, age, dropped) else null
          if (relayTargetStream(quality, true, true, headset.policy.stream) == RelayStream.STEADY) {
            headset.pendingSteady = why ?: RelaySwitchWhy.SETTING
            if (motorsOn == true && quality == RelayQuality.AUTOMATIC) {
              steadyMemory.remember(steadyMemory.key(headset.name, headset.address))
            }
            needed = true
            askSwitch = true
          }
        }
      }
    }
    source.setEnabled(enabled, nowNs)
    source.setCapableReceivers(capable, nowNs)
    source.setNeeded(needed, nowNs)
    if (askSwitch) {
      source.requestKey(RelayKeyCause.SWITCH, nowNs)
    }
    if (askDrop) {
      source.requestKey(RelayKeyCause.DROP, nowNs)
    }
    encoderRate.next(allowed, null, nowNs)?.let { source.setBitrate(it, nowNs) }
    source.setPictureRate(if (slow) 15 else 30, nowNs)
    source.tick(nowNs)
  }

  /**
   * Under [lock]: the kept key unit to send after a drop that left no key unit in a receiver's queue, flagged KEY,
   * PRIMER and BREAK, when it was decoded with the parameter sets of the units now sent
   */
  private fun recoveryPrimer(description: ResolvedDescription, relayed: RelaySource): RelayPrimer? {
    val key = lastKey ?: return null
    if (!key.description.sameSetsAs(description.description)) {
      return null
    }
    var flags = RelayWire.UNIT_KEY or RelayWire.UNIT_PRIMER or RelayWire.UNIT_BREAK
    if (key.unit.hasParameterSets) flags = flags or RelayWire.UNIT_IN_BAND
    if (relayed == RelaySource.REPLAY) flags = flags or RelayWire.UNIT_REPLAY
    return RelayPrimer(key.unit, flags)
  }

  /** A key unit kept from an earlier session of the remote: sent to a joining headset until a live one replaces it */
  override fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
    if (!unit.isKey) {
      return
    }
    synchronized(lock) {
      if (lastKey == null) {
        lastKey = KeptKey(unit, description.description)
      }
    }
  }

  /** A new source: every headset's decoder stops and waits for parameter sets again */
  override fun reset() {
    val now = clockNs()
    val body = RelayWire.jsonBody(buildJsonObject { put("why", "newSource") })
    synchronized(lock) {
      lastResolved = null
      lastKey = null
      lastSteady = null
      for (headset in headsets) {
        headset.queue.clearForReset()
        headset.lastDescription = null
        headset.breakNext = false
        headset.unitSinceReset = false
        if (!headset.resetQueued) {
          headset.queue.offerRecord(RelayWire.RESET, 0, body, now)
          headset.resetQueued = true
        }
      }
    }
  }

  /** The next unit does not continue the previous one sent: BREAK on it, for every headset that had one */
  override fun newStream() {
    synchronized(lock) {
      for (headset in headsets) {
        if (headset.unitSinceReset) {
          headset.breakNext = true
        }
      }
    }
  }

  override fun status(): DecoderStatus = DecoderStatus()

  // Time

  /**
   * Telemetry at 10 Hz while a source runs and once a second otherwise, and the watchdogs: a writer stalled for 3 s or
   * a headset silent for 5 s is closed. Run by the "DjiRelayTick" thread, or by a test with its own clock.
   */
  fun tick(nowNs: Long) {
    if (!running) {
      return
    }
    closeLateHandshakes(nowNs)
    if (nowNs >= nextTelemetryNs) {
      val interval = if (source == RelaySource.NONE) IDLE_TELEMETRY_INTERVAL_NS else TELEMETRY_INTERVAL_NS
      nextTelemetryNs = if (nowNs - nextTelemetryNs > interval) nowNs + interval else nextTelemetryNs + interval
      // No body is built for nobody: a relay left on with no headset costs a clock check
      val receivers = synchronized(lock) { headsets.toList() }
      if (receivers.isNotEmpty()) {
        val sequence = telemetrySequence++
        val body = runCatching { telemetry(sequence) }.getOrNull()
        if (body != null && body.size <= RelayWire.MAX_JSON_BYTES) {
          receivers.forEach { it.queue.offerTelemetry(body, nowNs) }
        }
      }
    }
    val current = synchronized(lock) { headsets.toList() }
    for (headset in current) {
      headset.sampleSecond(nowNs)
      val writing = headset.writeStartedNs
      if (writing != 0L && nowNs - writing > writerStallNs) {
        log("headset ${headset.number}: no write progress for ${(nowNs - writing) / 1_000_000} ms, closed")
        headset.close("stalled")
      } else if (nowNs - headset.lastPingNs > pingTimeoutMs * 1_000_000L) {
        headset.close("silent")
      }
    }
    manageStreams(nowNs)
  }

  /**
   * The connections still in their handshake [helloTimeoutMs] after their accept: closed, and counted as a failure of
   * their address. The read timeout of the handshake applies to each read only; a client that sends a byte now and
   * then would otherwise hold a handshake for an hour.
   */
  private fun closeLateHandshakes(nowNs: Long) {
    val late = synchronized(lock) {
      val expired = pending.filter { nowNs - it.startedNs >= helloTimeoutMs * 1_000_000L }
      pending.removeAll(expired)
      expired
    }
    for (handshake in late) {
      log("a handshake from ${handshake.address} passed its deadline, closed")
      fail(handshake.address, nowNs)
      runCatching { handshake.socket.close() }
    }
  }

  private fun tickLoop() {
    while (running) {
      val now = clockNs()
      tick(now)
      // With no headset there is nothing to send nor to watch but the handshakes: four times a second is enough
      val idle = synchronized(lock) { headsets.isEmpty() }
      val sleepMs = if (idle) 250L else ((nextTelemetryNs - clockNs()) / 1_000_000).coerceIn(5, 50)
      try {
        Thread.sleep(sleepMs)
      } catch (_: InterruptedException) {
        return
      }
    }
  }

  // Connections

  private fun acceptLoop(socket: ServerSocket) {
    while (running) {
      val client = try {
        socket.accept()
      } catch (_: IOException) {
        break
      }
      Thread({ serve(client) }, "DjiRelayIn-${numbers.get() + 1}").apply { isDaemon = true }.start()
    }
  }

  private fun serve(socket: Socket) {
    val address = socket.inetAddress?.hostAddress ?: "?"
    if (!running || !runCatching { addressRule(socket) }.getOrDefault(false)) {
      // Anything outside the local network is closed before a byte is sent
      runCatching { socket.close() }
      return
    }
    if (handshakes.incrementAndGet() > maxHandshakes) {
      handshakes.decrementAndGet()
      runCatching { socket.close() }
      return
    }
    val handshake = Handshake(socket, address, clockNs())
    val admitted = synchronized(lock) {
      if (pending.count { it.address == address } >= maxHandshakesPerAddress) {
        false
      } else {
        pending.add(handshake)
        true
      }
    }
    if (!admitted) {
      // One headset makes one connection at a time: more at once from one address hold slots the others need
      handshakes.decrementAndGet()
      runCatching { socket.close() }
      return
    }
    var inHandshake = true
    var primed = false
    var reservation = false
    var headset: RelayHeadset? = null
    try {
      socket.tcpNoDelay = true
      runCatching { socket.trafficClass = RelayWire.TRAFFIC_CLASS }
      val socketFacts = runCatching { socketTuning(socket) }.getOrDefault(RelaySocketFacts(null, null))
      socket.soTimeout = helloTimeoutMs
      val output = BufferedOutputStream(socket.getOutputStream(), RelayWire.STREAM_BUFFER_BYTES)
      val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 16 * 1024))
      if (blocked(address, clockNs())) {
        refuse(output, RelayWire.REFUSED_BLOCKED)
        return
      }
      val serverNonce = ByteArray(RelayWire.NONCE_BYTES).also { random.nextBytes(it) }
      RelayWire.write(output, RelayWire.CHALLENGE, 0, RelayWire.challengeBody(serverNonce))
      output.flush()
      val record = try {
        RelayWire.read(input, fromPhone = false)
      } catch (_: SocketTimeoutException) {
        refuse(output, RelayWire.REFUSED_TIMEOUT)
        return
      }
      if (record.type != RelayWire.HELLO) {
        unexpected("a ${"0x%02x".format(record.type)} before the hello")
        return
      }
      val hello = RelayWire.parseHello(record.body)
      if (hello.version != RelayWire.VERSION) {
        refuse(output, RelayWire.REFUSED_VERSION)
        return
      }
      val current = code ?: return
      val proved = provedCode(current, screenCodes, serverNonce, hello.clientNonce, hello.proof)
      if (proved == null) {
        refusedProofs += 1
        fail(address, clockNs())
        refuse(output, RelayWire.REFUSED_CODE)
        onChange()
        return
      }
      val full = synchronized(lock) {
        if (headsets.size + reserved >= maxHeadsets) {
          true
        } else {
          reserved += 1
          reservation = true
          false
        }
      }
      if (full) {
        refuse(output, RelayWire.REFUSED_FULL)
        return
      }
      val number = numbers.incrementAndGet()
      val name = (hello.json?.get("name") as? JsonPrimitive)?.contentOrNull?.filter { !it.isISOControl() }?.take(64)
      val app = (hello.json?.get("app") as? JsonPrimitive)?.contentOrNull?.filter { !it.isISOControl() }?.take(32)
      val kind = (hello.json?.get("kind") as? JsonPrimitive)?.contentOrNull?.takeIf { KIND.matches(it) }
      // A receiver of this build reads the unit header with the content clock, and says so
      val longHeader = (hello.json?.get("unitHeader") as? JsonPrimitive)?.intOrNull == RelayWire.UNIT_HEADER_LONG_BYTES
      // A receiver of the bandwidth build takes the phone's steady stream and sends the 96 byte ping, and says so
      val steadyAsked = (hello.json?.get("steady") as? JsonPrimitive)?.intOrNull == 1
      val steadyPings = (hello.json?.get("pingBytes") as? JsonPrimitive)?.intOrNull == RelayWire.PING_STEADY_BYTES
      val steadyOffered = steadyAsked && steady?.available == true
      val facts = welcomeFacts()
      val resolved = synchronized(lock) { lastResolved }
      val info = resolved?.description?.info
      val welcome = buildJsonObject {
        put("v", RelayWire.VERSION)
        put("phone", facts.phoneName)
        put("id", facts.phoneId)
        put("client", number)
        put("maxClients", maxHeadsets)
        put("source", source.wire)
        put("replayName", facts.replayName)
        put("codec", if (resolved == null) null else "h265")
        put("width", info?.width)
        put("height", info?.height)
        put("profile", info?.profileName)
        put("highTier", info?.highTier)
        put("level", info?.levelName)
        put("descriptionSource", resolved?.source?.name?.lowercase())
        put("telemetryHz", 10)
        put("pingMs", 500)
        if (longHeader) {
          put("unitHeader", RelayWire.UNIT_HEADER_LONG_BYTES)
        }
        // Pings with the receiver's own numbers are taken; a receiver of an earlier build ignores this
        put("pingBytes", if (steadyPings) RelayWire.PING_STEADY_BYTES else RelayWire.PING_LONG_BYTES)
        if (steadyOffered) {
          // This phone may send it the steady stream: units flagged as the phone's, parameter sets that change at a
          // BREAK
          put("steady", 1)
        }
      }
      // The phone proves the code this connection proved: a TV checks it with its own code
      val phoneProof = RelayWire.proof(proved.code, RelayWire.ROLE_PHONE, serverNonce, hello.clientNonce)
      RelayWire.write(output, RelayWire.WELCOME, 0, RelayWire.welcomeBody(phoneProof, welcome.toString()))
      output.flush()
      val joined = RelayHeadset(
        number,
        socket,
        output,
        address,
        name,
        app,
        clockNs,
        { gone, why -> forget(gone, why) },
        RelayQueue(queueMaxAgeNs ?: RelayQueue.maxAgeFor(kind), queueMaxBytes),
        screenCodeId = proved.screenId,
        kind = kind,
        unitHeaderBytes = if (longHeader) RelayWire.UNIT_HEADER_LONG_BYTES else RelayWire.UNIT_HEADER_BYTES,
        socketFacts = socketFacts,
        maxAgeNs = queueMaxAgeNs ?: RelayQueue.maxAgeFor(kind),
        steadyCapable = steadyOffered,
        pingBytes = if (steadyPings) RelayWire.PING_STEADY_BYTES else RelayWire.PING_LONG_BYTES,
        lowWaterTuning = lowWaterTuning,
      )
      var joinKey = false
      synchronized(lock) {
        reserved -= 1
        reservation = false
        // The code it proved must still be there: a new own code, or the TV removed, during the handshake
        val stillValid = if (proved.screenId == null) {
          code == current
        } else {
          screenCodes.any { it.id == proved.screenId && it.code == proved.code }
        }
        if (!running || !stillValid) {
          throw IOException("stopped during the handshake")
        }
        if (!pending.remove(handshake)) {
          // The tick closed it at its deadline meanwhile
          throw IOException("past the deadline of the handshake")
        }
        headsets.add(joined)
        // A receiver that takes the steady stream joins on it when the setting asks, or when it needed it in an earlier
        // flight of this session and the drone flies (p2/relay-bandwidth-2026-10-25.md, 7.5 item 1 and 7.7)
        val memory = quality == RelayQuality.AUTOMATIC && motorsOn == true &&
          steadyMemory.knows(steadyMemory.key(joined.name, joined.address))
        val wantsSteady = steadyOffered && steady?.usable == true && source != RelaySource.NONE &&
          (quality == RelayQuality.STEADY || memory)
        val why = if (quality == RelayQuality.STEADY) RelaySwitchWhy.SETTING else RelaySwitchWhy.MEMORY
        if (wantsSteady && memory) {
          joined.policy.goSteady()
        }
        if (wantsSteady && steady?.producing == true) {
          // No kept drone key picture, no primer: a key picture of the steady stream is asked for it
          joined.queue.switchStream(toSteady = true, joined.steadyMaxAgeNs, breakNext = false)
          joined.recordSwitch(clockNs(), RelayStream.STEADY, why)
          joined.followLowWater(RelayLowWater.bytesFor(joined.rate.allowedBps))
          joinKey = true
        } else if (wantsSteady) {
          // The encoder is made at this first need: the full stream until its first key unit
          joined.pendingSteady = why
          joinKey = true
        }
        // The last description the phone resolved goes first, so that a headset joining mid stream starts at once
        lastResolved?.takeIf { joined.stream == RelayStream.FULL }?.let { last ->
          joined.queue.offerRecord(
            RelayWire.PARAMETERS,
            RelayWire.parametersFlag(last.source),
            RelayWire.parametersBody(last.description),
            clockNs(),
          )
          joined.lastDescription = last.description
          // Then the last key unit of these parameter sets: the decoders of the Quest refuse every unit before a key
          // picture, and the remote sends one only when its encoder starts
          lastKey?.takeIf { it.description.sameSetsAs(last.description) }?.let { key ->
            var flags = RelayWire.UNIT_KEY or RelayWire.UNIT_PRIMER
            if (key.unit.hasParameterSets) flags = flags or RelayWire.UNIT_IN_BAND
            if (source == RelaySource.REPLAY) flags = flags or RelayWire.UNIT_REPLAY
            primed = joined.queue.offerUnit(key.unit, flags, breakBefore = false, nowNs = clockNs())
            primersSent += 1
          }
        }
      }
      headset = joined
      inHandshake = false
      handshakes.decrementAndGet()
      if (joinKey) {
        steady?.setNeeded(true, clockNs())
        steady?.requestKey(RelayKeyCause.JOIN, clockNs())
      }
      joined.startWriter()
      val who = if (proved.screenId == null) "headset" else "screen"
      log("$who $number joined from $address" + if (primed) ", the last key picture sent first" else "")
      onChange()
      socket.soTimeout = pingTimeoutMs
      readLoop(joined, input)
    } catch (error: RelayProtocolException) {
      unexpected(error.reason)
    } catch (_: IOException) {
      // The headset left, timed out or the phone stopped
    } catch (error: RuntimeException) {
      unexpected(error.javaClass.simpleName)
    } finally {
      if (inHandshake) {
        handshakes.decrementAndGet()
        synchronized(lock) { pending.remove(handshake) }
      }
      if (reservation) {
        synchronized(lock) { reserved -= 1 }
      }
      val joined = headset
      if (joined != null) {
        joined.close("reader ended")
      } else {
        runCatching { socket.close() }
      }
    }
  }

  /** The headset's records after the welcome: pings and a bye; anything else closes it */
  private fun readLoop(headset: RelayHeadset, input: DataInputStream) {
    while (!headset.closed) {
      val record = RelayWire.read(input, fromPhone = false)
      when (record.type) {
        RelayWire.PING -> {
          val received = clockNs()
          val ping = RelayWire.parsePing(record.body)
          headset.onPing(ping, received)
          // The send time is written by the writer when the pong leaves
          headset.queue.offerPong(RelayWire.pongBody(ping.sendNs, received, 0), received)
        }
        RelayWire.HEADSET_BYE -> return
        else -> {
          unexpected("a second hello")
          return
        }
      }
    }
  }

  private fun refuse(output: OutputStream, reason: String) {
    runCatching {
      RelayWire.write(output, RelayWire.REFUSED, 0, RelayWire.jsonBody(buildJsonObject { put("reason", reason) }))
      output.flush()
    }
  }

  private fun unexpected(what: String) {
    unexpectedRecords += 1
    log("connection closed: $what")
    onChange()
  }

  private fun forget(headset: RelayHeadset, why: String) {
    val removed = synchronized(lock) {
      val was = headsets.remove(headset)
      if (was) {
        droppedOfClosed += headset.queue.unitsDropped
        left.addLast(headset)
        while (left.size > LEFT_KEPT) {
          left.removeFirst()
        }
      }
      was
    }
    if (removed) {
      log("headset ${headset.number} left: $why")
      onChange()
    }
  }

  private fun blocked(address: String, nowNs: Long): Boolean = synchronized(lock) {
    val until = blockedUntil[address] ?: return false
    if (nowNs >= until) {
      blockedUntil.remove(address)
      return false
    }
    true
  }

  private fun fail(address: String, nowNs: Long) = synchronized(lock) {
    val times = failures.getOrPut(address) { ArrayDeque() }
    times.addLast(nowNs)
    while (times.isNotEmpty() && nowNs - times.first() > failureWindowNs) {
      times.removeFirst()
    }
    if (times.size >= failureLimit) {
      blockedUntil[address] = nowNs + blockNs
      times.clear()
    }
    // Forget the addresses that stopped failing long ago
    if (failures.size > 256) {
      failures.entries.removeAll { (_, list) -> list.isEmpty() || nowNs - list.last() > failureWindowNs }
    }
  }

  fun snapshot(nowNs: Long = clockNs()): RelaySendingSnapshot {
    val rows: List<RelayHeadsetRow>
    val dropped: Long
    val droneMegabits: Double
    synchronized(lock) {
      rows = headsets.map { headset ->
        RelayHeadsetRow(
          address = headset.address,
          name = headset.name,
          connectedForMs = (nowNs - headset.connectedAtNs) / 1_000_000,
          picturesShownPerSecond = headset.shownPer10s.takeIf { it >= 0 }?.let { it / 10.0 },
          relayDelayMs = headset.relayDelayMedianUs.takeIf { it >= 0 }?.let { it / 1000.0 },
          droppedUnits = headset.queue.unitsDropped,
          megabitsPerSecond = headset.megabitsPerSecond(nowNs),
          screenCodeId = headset.screenCodeId,
          kind = headset.kind,
          queueAgeMs = headset.queue.oldestUnitAgeNs(nowNs)?.let { it / 1e6 },
          queueMaxAgeMs = headset.queue.counters().maxAgeNs / 1e6,
          dropEvents = headset.queue.overloadCount,
          writeStalls = headset.stats.writeStalls200,
          writeP95Ms = headset.stats.writeP95Ms,
          sendBufferBytes = headset.socketFacts.sendBufferBytes,
          receiver = headset.stats.receiverNumbers,
          stream = headset.stream.wire,
          steadyCapable = headset.steadyCapable,
          streamForMs = headset.streamSinceNs.takeIf { it > 0 }?.let { (nowNs - it) / 1_000_000 },
          bestSecondMegabits = headset.stats.bestSecondBits(120) / 1e6,
          allowedMegabits = if (headset.stream == RelayStream.STEADY) headset.rate.allowedBps / 1e6 else null,
          network = headset.stats.receiverNetwork,
        )
      }
      dropped = droppedOfClosed + headsets.sumOf { it.queue.unitsDropped }
      droneMegabits = droneBitsLocked(nowNs) / 1e6
    }
    return RelaySendingSnapshot(
      on = running,
      port = if (running) port else null,
      source = source,
      headsets = rows,
      refusedProofs = refusedProofs,
      unexpectedRecords = unexpectedRecords,
      unitsDropped = dropped,
      primersSent = primersSent + headsetsAndLeft().sumOf { it.queue.counters().recoveryPrimers },
      quality = quality,
      steadyLine = steady?.line(nowNs),
      droneMegabitsPerSecond = droneMegabits,
    )
  }

  private fun headsetsAndLeft(): List<RelayHeadset> = synchronized(lock) { left.toList() + headsets.toList() }

  /**
   * The relay section of the phone's export (p2/relay-smoothness-2026-10-25.md, 6.1): the totals, and for every
   * receiver of this run of the relay, those that left included, what was sent, dropped and measured, with its timeline
   */
  fun report(nowNs: Long = clockNs()): JsonObject {
    val receivers = headsetsAndLeft()
    return buildJsonObject {
      put("on", running)
      put("port", if (running) port else null)
      put("source", source.wire)
      put("refusedProofs", refusedProofs)
      put("unexpectedRecords", unexpectedRecords)
      put("unitsDropped", unitsDropped)
      put("joinPrimersSent", primersSent)
      put("notSentLowWaterAsked", RelayWire.NOT_SENT_LOW_WATER_BYTES)
      put("fallbackSendBufferAsked", RelayWire.FALLBACK_SEND_BUFFER_BYTES)
      // The steady stream (p2/relay-bandwidth-2026-10-25.md, 7.10)
      put("quality", quality.wire)
      put("motorsOn", motorsOn)
      put("steadyUnits", synchronized(lock) { steadyUnits })
      put("switchPrimersSent", switchPrimers)
      put("droneMegabitsPerSecondNow", synchronized(lock) { droneBitsLocked(nowNs) } / 1e6)
      put("transcoder", steady?.report(nowNs) ?: JsonNull)
      put("receivers", buildJsonArray { receivers.forEach { add(it.report(nowNs)) } })
    }
  }

  /** Connections in their handshake, for the tests */
  internal fun handshakesInProgress(): Int = synchronized(lock) { pending.size }

  /** Records waiting in every headset's queue, for the tests */
  internal fun queuedRecords(): Int = synchronized(lock) { headsets.sumOf { it.queue.size } }

  /** Headsets whose writer is inside a record, for the tests of the stall watchdog */
  internal fun writersInARecord(): Int = synchronized(lock) { headsets.count { it.writeStartedNs != 0L } }

  /** Units dropped for every headset since the relay started, for the telemetry record */
  val unitsDropped: Long get() = synchronized(lock) { droppedOfClosed + headsets.sumOf { it.queue.unitsDropped } }
}
