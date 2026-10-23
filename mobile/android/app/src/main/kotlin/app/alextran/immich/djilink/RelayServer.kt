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
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
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

/** One headset as the phone's page shows it */
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
)

data class RelaySendingSnapshot(
  val on: Boolean,
  val port: Int?,
  val source: RelaySource,
  val headsets: List<RelayHeadsetRow>,
  val refusedProofs: Long,
  val unexpectedRecords: Long,
  val unitsDropped: Long,
)

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
 * is neither mobile data nor a VPN; a headset that proves the code within [helloTimeoutMs]; at most [maxHandshakes]
 * handshakes at once and [maxHeadsets] headsets; [failureLimit] wrong proofs from one address within [failureWindowNs]
 * block it for [blockNs] (the phone share's numbers).
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
  private val failureLimit: Int = 10,
  private val failureWindowNs: Long = 60_000_000_000L,
  private val blockNs: Long = 60_000_000_000L,
  /** The TELEMETRY body of tick [sequence]; null sends none */
  private val telemetry: (sequence: Long) -> ByteArray? = { null },
  private val welcomeFacts: () -> RelayWelcomeFacts = { RelayWelcomeFacts("phone", null, null) },
  private val onChange: () -> Unit = {},
  /** False in the tests that drive [tick] themselves */
  private val runTicker: Boolean = true,
  private val queueMaxAgeNs: Long = RelayQueue.MAX_AGE_NS,
  private val queueMaxBytes: Long = RelayQueue.MAX_BYTES,
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

    private fun log(message: String) {
      runCatching { android.util.Log.i(TAG, message) }
    }
  }

  private val lock = Any()
  private val headsets = mutableListOf<RelayHeadset>()
  private var reserved = 0
  private val handshakes = AtomicInteger()
  private val numbers = AtomicInteger()
  private val failures = HashMap<String, ArrayDeque<Long>>()
  private val blockedUntil = HashMap<String, Long>()

  @Volatile
  private var serverSocket: ServerSocket? = null

  @Volatile
  private var code: String? = null

  @Volatile
  private var running = false

  /** The last description the phone resolved: sent to a headset right after its welcome */
  private var lastResolved: ResolvedDescription? = null
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

  val isRunning: Boolean get() = running

  val port: Int? get() = serverSocket?.localPort

  val headsetCount: Int get() = synchronized(lock) { headsets.size }

  /**
   * Listens on every interface, on [preferredPort] when it is free, else on any free port; returns the port. Already
   * running, it only takes the code.
   */
  fun start(code: String, preferredPort: Int = RelayWire.DEFAULT_PORT, bindAddress: InetAddress? = null): Int {
    require(RelayWire.normalizeCode(code) == code) { "a code of the pairing alphabet" }
    serverSocket?.let { existing ->
      if (running) {
        setCode(code)
        return existing.localPort
      }
    }
    val any = bindAddress ?: InetAddress.getByAddress(byteArrayOf(0, 0, 0, 0))
    val socket = runCatching { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(any, preferredPort)) } }
      .getOrElse { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(any, 0)) } }
    this.code = code
    serverSocket = socket
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

  /** A new code: every headset is told so and leaves; each must prove the new code to come back */
  fun setCode(next: String) {
    require(RelayWire.normalizeCode(next) == next) { "a code of the pairing alphabet" }
    if (next == code) {
      return
    }
    code = next
    val leaving = synchronized(lock) { headsets.toList() }
    val body = RelayWire.jsonBody(buildJsonObject { put("why", RelayWire.BYE_NEW_CODE) })
    val now = clockNs()
    leaving.forEach { it.queue.finish(RelayWire.BYE, body, now) }
    onChange()
  }

  // The relay half of the tee

  override fun submit(unit: AccessUnit, description: ResolvedDescription) {
    val relayed = source
    if (!running || relayed == RelaySource.NONE) {
      return
    }
    val now = clockNs()
    var flags = 0
    if (unit.isKey) flags = flags or RelayWire.UNIT_KEY
    if (unit.hasParameterSets) flags = flags or RelayWire.UNIT_IN_BAND
    if (relayed == RelaySource.REPLAY) flags = flags or RelayWire.UNIT_REPLAY
    synchronized(lock) {
      lastResolved = description
      for (headset in headsets) {
        if (unit.isKey || !description.description.sameSetsAs(headset.lastDescription)) {
          headset.queue.offerRecord(
            RelayWire.PARAMETERS,
            RelayWire.parametersFlag(description.source),
            RelayWire.parametersBody(description.description),
            now,
          )
          headset.lastDescription = description.description
        }
        headset.queue.offerUnit(unit, flags, headset.breakNext, now)
        headset.breakNext = false
        headset.unitSinceReset = true
        headset.resetQueued = false
      }
    }
  }

  /** A new source: every headset's decoder stops and waits for parameter sets again */
  override fun reset() {
    val now = clockNs()
    val body = RelayWire.jsonBody(buildJsonObject { put("why", "newSource") })
    synchronized(lock) {
      lastResolved = null
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
    if (nowNs >= nextTelemetryNs) {
      val interval = if (source == RelaySource.NONE) IDLE_TELEMETRY_INTERVAL_NS else TELEMETRY_INTERVAL_NS
      nextTelemetryNs = if (nowNs - nextTelemetryNs > interval) nowNs + interval else nextTelemetryNs + interval
      val sequence = telemetrySequence++
      val body = runCatching { telemetry(sequence) }.getOrNull()
      if (body != null && body.size <= RelayWire.MAX_JSON_BYTES) {
        synchronized(lock) { headsets.toList() }.forEach { it.queue.offerTelemetry(body, nowNs) }
      }
    }
    val current = synchronized(lock) { headsets.toList() }
    for (headset in current) {
      val writing = headset.writeStartedNs
      if (writing != 0L && nowNs - writing > writerStallNs) {
        log("headset ${headset.number}: no write progress for ${(nowNs - writing) / 1_000_000} ms, closed")
        headset.close("stalled")
      } else if (nowNs - headset.lastPingNs > pingTimeoutMs * 1_000_000L) {
        headset.close("silent")
      }
    }
  }

  private fun tickLoop() {
    while (running) {
      val now = clockNs()
      tick(now)
      val sleepMs = ((nextTelemetryNs - clockNs()) / 1_000_000).coerceIn(5, 50)
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
    var inHandshake = true
    var reservation = false
    var headset: RelayHeadset? = null
    try {
      socket.tcpNoDelay = true
      runCatching { socket.trafficClass = RelayWire.TRAFFIC_CLASS }
      runCatching { socket.sendBufferSize = RelayWire.SEND_BUFFER_BYTES }
      socket.soTimeout = helloTimeoutMs
      val output = BufferedOutputStream(socket.getOutputStream(), RelayWire.SEND_BUFFER_BYTES)
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
      val expected = RelayWire.proof(current, RelayWire.ROLE_HEADSET, serverNonce, hello.clientNonce)
      if (!RelayWire.proofMatches(expected, hello.proof)) {
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
      }
      val phoneProof = RelayWire.proof(current, RelayWire.ROLE_PHONE, serverNonce, hello.clientNonce)
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
        RelayQueue(queueMaxAgeNs, queueMaxBytes),
      )
      synchronized(lock) {
        reserved -= 1
        reservation = false
        if (!running || code != current) {
          throw IOException("stopped during the handshake")
        }
        headsets.add(joined)
        // The last description the phone resolved goes first, so that a headset joining mid stream starts at once
        lastResolved?.let { last ->
          joined.queue.offerRecord(
            RelayWire.PARAMETERS,
            RelayWire.parametersFlag(last.source),
            RelayWire.parametersBody(last.description),
            clockNs(),
          )
          joined.lastDescription = last.description
        }
      }
      headset = joined
      inHandshake = false
      handshakes.decrementAndGet()
      joined.startWriter()
      log("headset $number joined from $address")
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
          headset.lastPingNs = received
          headset.relayDelayMedianUs = ping.relayDelayMedianUs
          headset.shownPer10s = ping.shownPer10s
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
        )
      }
      dropped = droppedOfClosed + headsets.sumOf { it.queue.unitsDropped }
    }
    return RelaySendingSnapshot(
      on = running,
      port = if (running) port else null,
      source = source,
      headsets = rows,
      refusedProofs = refusedProofs,
      unexpectedRecords = unexpectedRecords,
      unitsDropped = dropped,
    )
  }

  /** Records waiting in every headset's queue, for the tests */
  internal fun queuedRecords(): Int = synchronized(lock) { headsets.sumOf { it.queue.size } }

  /** Headsets whose writer is inside a record, for the tests of the stall watchdog */
  internal fun writersInARecord(): Int = synchronized(lock) { headsets.count { it.writeStartedNs != 0L } }

  /** Units dropped for every headset since the relay started, for the telemetry record */
  val unitsDropped: Long get() = synchronized(lock) { droppedOfClosed + headsets.sumOf { it.queue.unitsDropped } }
}
