package app.alextran.immich.djilink

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/** Where the headset stands with the phone it receives from; the page words each one */
enum class RelayReceiveState {
  IDLE,
  CONNECTING,
  CHECKING_CODE,
  RECEIVING,

  /** The connection was lost: trying again */
  LOST,

  /** The phone refused the code, or made a new one: the code is asked again */
  WRONG_CODE,

  /** The phone already sends to as many headsets as it takes: trying again every 10 s */
  FULL,

  /** Too many wrong codes from this address: trying again every 10 s */
  BLOCKED,

  /** The phone runs another version of the relay protocol */
  OTHER_VERSION,

  /** The phone did not prove the code: nothing it sends is shown */
  PHONE_UNPROVEN,

  /** Refused here: a remote is open on this device's cable */
  BUSY,
}

/** What the phone said in its welcome */
data class RelayWelcome(
  val phoneName: String?,
  val phoneId: String?,
  val source: String,
  val replayName: String?,
)

/** The receiver as the page shows it */
data class RelayReceiveSnapshot(
  val state: RelayReceiveState,
  val phoneName: String?,
  val phoneId: String?,
  val host: String?,
  val port: Int?,
  /** cable, replay or none, from the phone's last telemetry or its welcome */
  val phoneSource: String,
  val replayName: String?,
  val replayPositionMs: Long?,
  val reconnectInMs: Long?,
  /** Connection attempts that failed in a row, for the fallback to the announced address */
  val failures: Int,
  val units: Long,
  /** Pictures the phone dropped for this headset because the Wi-Fi could not keep up: the sequence gaps */
  val lostOnWifi: Long,
  val breaks: Long,
  val latency: RelayLatencyNumbers,
  val telemetry: RelayTelemetryRecord?,
  val telemetryAgeMs: Long?,
  val lastUnitAgoMs: Long?,
)

/**
 * The headset side of relay protocol 1 ([RelayWire]), in the main source set so that a phone can receive too.
 *
 * One reader thread "DjiRelayReceiver" connects (3 s), answers the challenge with a proof of the code, checks the
 * phone's proof before anything is shown, then reads the records: parameter sets and units go to the [Listener] (the
 * controller's own video pipeline and decoder, the path of a cable unit), resets stop the decoder until the next
 * parameter sets, telemetry is kept with its arrival time, pongs align the clocks ([ClockOffset]). A thread
 * "DjiRelayPing" sends a ping every 500 ms.
 *
 * Nothing it sends can reach the remote: its records are the hello, the pings and the bye.
 *
 * Liveness: the phone sends telemetry at least once a second, so 2 s without a record is a lost connection. It connects
 * again after 0.5 s, 1 s and 2 s, then every 2 s, for as long as it is not told to stop; a wrong code, a new code on the
 * phone, another version and a phone that did not prove the code stop the retries; a full phone or a blocked address
 * is tried again every 10 s.
 */
class RelayReceiver(
  private val listener: Listener,
  private val clockNs: () -> Long = { System.nanoTime() },
  private val random: SecureRandom = SecureRandom(),
  private val connectTimeoutMs: Int = 3_000,
  private val handshakeTimeoutMs: Int = 5_000,
  private val silenceMs: Int = 2_000,
  private val pingIntervalMs: Long = 500,
  private val retryDelaysMs: List<Long> = listOf(500, 1_000, 2_000),
  private val busyRetryMs: Long = 10_000,
) {
  interface Listener {
    /** The phone proved the code: a new source for the pipeline */
    fun onConnected(welcome: RelayWelcome)

    fun onParameters(description: StreamDescription, source: DescriptionSource, arrivalNs: Long)

    fun onUnit(unit: AccessUnit, header: RelayUnitHeader, flags: Int, arrivalNs: Long)

    /** The phone's source changed: the decoder stops and waits for parameter sets */
    fun onReset()

    /** A connection that had been welcomed ended */
    fun onDisconnected()

    fun onChanged()

    /**
     * The reception stopped on its own, with no retry: a refused code or a new one on the phone, another version, a
     * phone that did not prove the code. Called once, after [RelayReceiver.active] became false, before [onChanged].
     */
    fun onEnded(state: RelayReceiveState) = Unit

    /** Pictures shown here in the last 10 s, for the pings; -1 when unknown */
    fun shownPer10s(): Int = -1

    /** Each telemetry record as it arrives; the receiver keeps the last one for the snapshot anyway */
    fun onTelemetry(record: RelayTelemetryRecord) = Unit

    /** Every record after the welcome as it was read, for the reception record of a bug report; on the reader thread */
    fun onRecord(record: RelayRecord, arrivalNs: Long) = Unit
  }

  private class Target(
    val host: String,
    val port: Int,
    val code: String,
    val phoneId: String?,
    val headsetName: String,
    val appVersion: String,
    val kind: String?,
  )

  private enum class Outcome { LOST, LOST_AFTER_WELCOME, WRONG_CODE, FULL, BLOCKED, OTHER_VERSION, PHONE_UNPROVEN, TIMEOUT }

  private val lock = Object()
  private val outputLock = Any()
  private var generation = 0
  private var target: Target? = null
  private var socket: Socket? = null
  private var output: OutputStream? = null

  @Volatile
  var state: RelayReceiveState = RelayReceiveState.IDLE
    private set

  @Volatile
  private var welcome: RelayWelcome? = null

  @Volatile
  private var reconnectAtNs: Long? = null

  @Volatile
  private var failures = 0

  val clock = ClockOffset()
  val latency = RelayLatency()

  private val countsLock = Any()
  private var units = 0L
  private var lostOnWifi = 0L
  private var breaks = 0L
  private var lastSequence: Long? = null
  private var lastUnitNs: Long? = null
  private var telemetry: RelayTelemetryRecord? = null
  private var telemetryAtNs: Long? = null

  /** True from [connect] to [disconnect] or a state that stops the retries */
  val active: Boolean get() = synchronized(lock) { target != null }

  /**
   * Starts receiving from [host]:[port] with [code]; a running connection to another phone or address stops first.
   * The host must be an IPv4 literal of the local network; the caller checked it. [kind] goes in the hello when set
   * ("tv" on a TV, for the phone's list); a headset says nothing, as before.
   */
  fun connect(
    host: String,
    port: Int,
    code: String,
    phoneId: String?,
    headsetName: String,
    appVersion: String,
    kind: String? = null,
  ) {
    val next = Target(host, port, code, phoneId, headsetName, appVersion, kind)
    val mine: Int
    synchronized(lock) {
      generation += 1
      mine = generation
      closeCurrent(sendBye = true)
      target = next
      welcome = null
      failures = 0
      reconnectAtNs = null
      lock.notifyAll()
    }
    synchronized(countsLock) {
      units = 0
      lostOnWifi = 0
      breaks = 0
      lastSequence = null
      lastUnitNs = null
      telemetry = null
      telemetryAtNs = null
    }
    clock.reset()
    latency.reset()
    setStateFor(mine, RelayReceiveState.CONNECTING)
    Thread({ run(next, mine) }, "DjiRelayReceiver").apply { isDaemon = true }.start()
  }

  /** Stops receiving: a bye to the phone, the socket closes, no retry */
  fun disconnect() {
    synchronized(lock) {
      generation += 1
      target = null
      reconnectAtNs = null
      closeCurrent(sendBye = true)
      state = RelayReceiveState.IDLE
      lock.notifyAll()
    }
    runCatching { listener.onChanged() }
  }

  private fun current(mine: Int): Boolean = synchronized(lock) { generation == mine && target != null }

  private fun run(target: Target, mine: Int) {
    while (current(mine)) {
      setStateFor(mine, RelayReceiveState.CONNECTING)
      val outcome = session(target, mine)
      if (!current(mine)) {
        return
      }
      val wait: Long = when (outcome) {
        Outcome.WRONG_CODE, Outcome.OTHER_VERSION, Outcome.PHONE_UNPROVEN -> {
          val ended = when (outcome) {
            Outcome.WRONG_CODE -> RelayReceiveState.WRONG_CODE
            Outcome.OTHER_VERSION -> RelayReceiveState.OTHER_VERSION
            else -> RelayReceiveState.PHONE_UNPROVEN
          }
          // The state and the end in one step: whoever hears of it sees a receiver that is no longer active
          val stillMine = synchronized(lock) {
            if (generation != mine) {
              false
            } else {
              state = ended
              this.target = null
              reconnectAtNs = null
              true
            }
          }
          if (stillMine) {
            runCatching { listener.onEnded(ended) }
            runCatching { listener.onChanged() }
          }
          return
        }
        Outcome.FULL, Outcome.BLOCKED -> {
          setStateFor(mine, if (outcome == Outcome.FULL) RelayReceiveState.FULL else RelayReceiveState.BLOCKED)
          busyRetryMs
        }
        Outcome.LOST_AFTER_WELCOME -> {
          failures = 1
          setStateFor(mine, RelayReceiveState.LOST)
          retryDelaysMs.first()
        }
        Outcome.LOST, Outcome.TIMEOUT -> {
          failures += 1
          setStateFor(mine, RelayReceiveState.LOST)
          retryDelaysMs[(failures - 1).coerceIn(0, retryDelaysMs.size - 1)]
        }
      }
      reconnectAtNs = clockNs() + wait * 1_000_000
      listener.onChanged()
      synchronized(lock) {
        val deadline = System.nanoTime() + wait * 1_000_000
        while (generation == mine && this.target != null) {
          val left = (deadline - System.nanoTime()) / 1_000_000
          if (left <= 0) {
            break
          }
          try {
            lock.wait(left)
          } catch (_: InterruptedException) {
            return
          }
        }
      }
      reconnectAtNs = null
    }
  }

  private fun session(target: Target, mine: Int): Outcome {
    val connection = Socket()
    var welcomed = false
    var pinger: Thread? = null
    synchronized(lock) {
      if (generation != mine) {
        return Outcome.LOST
      }
      socket = connection
    }
    try {
      connection.tcpNoDelay = true
      runCatching { connection.trafficClass = RelayWire.TRAFFIC_CLASS }
      connection.connect(InetSocketAddress(target.host, target.port), connectTimeoutMs)
      connection.soTimeout = handshakeTimeoutMs
      val input = DataInputStream(BufferedInputStream(connection.getInputStream(), 64 * 1024))
      val out = BufferedOutputStream(connection.getOutputStream(), 4 * 1024)
      synchronized(lock) {
        if (generation != mine) {
          return Outcome.LOST
        }
        output = out
      }
      setStateFor(mine, RelayReceiveState.CHECKING_CODE)
      var record = RelayWire.read(input, fromPhone = true)
      if (record.type == RelayWire.REFUSED) {
        return refusal(record)
      }
      if (record.type != RelayWire.CHALLENGE) {
        return Outcome.LOST
      }
      val (version, serverNonce) = RelayWire.parseChallenge(record.body)
      if (version != RelayWire.VERSION) {
        return Outcome.OTHER_VERSION
      }
      val clientNonce = ByteArray(RelayWire.NONCE_BYTES).also { random.nextBytes(it) }
      val proof = RelayWire.proof(target.code, RelayWire.ROLE_HEADSET, serverNonce, clientNonce)
      val hello = buildJsonObject {
        put("name", target.headsetName)
        put("app", target.appVersion)
        target.kind?.let { put("kind", it) }
      }
      synchronized(outputLock) {
        RelayWire.write(out, RelayWire.HELLO, 0, RelayWire.helloBody(clientNonce, proof, hello.toString()))
        out.flush()
      }
      record = RelayWire.read(input, fromPhone = true)
      if (record.type == RelayWire.REFUSED) {
        return refusal(record)
      }
      if (record.type != RelayWire.WELCOME) {
        return Outcome.LOST
      }
      val expected = RelayWire.proof(target.code, RelayWire.ROLE_PHONE, serverNonce, clientNonce)
      if (!RelayWire.proofMatches(expected, record.body.copyOfRange(0, RelayWire.PROOF_BYTES))) {
        // A device that announces itself as a sending phone without knowing the code: nothing it sends is shown
        return Outcome.PHONE_UNPROVEN
      }
      val json = RelayWire.parseJson(record.body, RelayWire.PROOF_BYTES)
      val said = RelayWelcome(
        phoneName = json.text("phone"),
        phoneId = json.text("id") ?: target.phoneId,
        source = json.text("source") ?: "none",
        replayName = json.text("replayName"),
      )
      if (!current(mine)) {
        return Outcome.LOST
      }
      welcome = said
      welcomed = true
      failures = 0
      // The sequence is per connection: a new one starts again from 0
      synchronized(countsLock) { lastSequence = null }
      listener.onConnected(said)
      setStateFor(mine, RelayReceiveState.RECEIVING)
      connection.soTimeout = silenceMs
      pinger = Thread({ pingLoop(out, mine) }, "DjiRelayPing").apply {
        isDaemon = true
        start()
      }
      while (current(mine)) {
        record = RelayWire.read(input, fromPhone = true)
        val arrival = clockNs()
        listener.onRecord(record, arrival)
        when (record.type) {
          RelayWire.PARAMETERS -> {
            val description = RelayWire.parseParameters(record.body) ?: continue
            val source = RelayWire.sourceOfParametersFlag(record.flags) ?: DescriptionSource.SESSION
            listener.onParameters(description, source, arrival)
          }
          RelayWire.UNIT -> onUnit(record, arrival)
          RelayWire.RESET -> listener.onReset()
          RelayWire.TELEMETRY -> RelayTelemetry.parseBody(record.body)?.let { parsed ->
            synchronized(countsLock) {
              telemetry = parsed
              telemetryAtNs = arrival
            }
            listener.onTelemetry(parsed)
          }
          RelayWire.PONG -> {
            val pong = RelayWire.parsePong(record.body)
            clock.onPong(pong.pingSendNs, pong.receivedNs, pong.sentNs, arrival)
          }
          RelayWire.BYE -> {
            val why = RelayWire.parseJson(record.body).text("why")
            return if (why == RelayWire.BYE_NEW_CODE) Outcome.WRONG_CODE else Outcome.LOST_AFTER_WELCOME
          }
          // A second challenge, welcome or refusal after the welcome is not this protocol
          else -> return Outcome.LOST_AFTER_WELCOME
        }
      }
      return Outcome.LOST_AFTER_WELCOME
    } catch (_: SocketTimeoutException) {
      return if (welcomed) Outcome.LOST_AFTER_WELCOME else Outcome.TIMEOUT
    } catch (_: IOException) {
      return if (welcomed) Outcome.LOST_AFTER_WELCOME else Outcome.LOST
    } catch (_: RelayProtocolException) {
      return if (welcomed) Outcome.LOST_AFTER_WELCOME else Outcome.LOST
    } finally {
      pinger?.interrupt()
      synchronized(lock) {
        if (socket === connection) {
          socket = null
          output = null
        }
      }
      runCatching { connection.close() }
      if (welcomed) {
        runCatching { listener.onDisconnected() }
      }
    }
  }

  private fun onUnit(record: RelayRecord, arrivalNs: Long) {
    val header = RelayWire.parseUnitHeader(record.body)
    val unit = RelayWire.accessUnitOf(record.body, arrivalNs)
    synchronized(countsLock) {
      val previous = lastSequence
      if (previous != null) {
        val gap = (header.sequence - previous - 1) and 0xFFFF_FFFFL
        if (gap in 1 until 0x8000_0000L) {
          lostOnWifi += gap
        }
      }
      if ((record.flags and RelayWire.UNIT_BREAK) != 0) {
        breaks += 1
      }
      lastSequence = header.sequence
      units += 1
      lastUnitNs = arrivalNs
    }
    // A primer is an old picture: its times would read as a delay of the radio
    if ((record.flags and RelayWire.UNIT_PRIMER) == 0) {
      latency.onUnit(arrivalNs, header)
    }
    listener.onUnit(unit, header, record.flags, arrivalNs)
  }

  private fun refusal(record: RelayRecord): Outcome = when (RelayWire.parseJson(record.body).text("reason")) {
    RelayWire.REFUSED_CODE -> Outcome.WRONG_CODE
    RelayWire.REFUSED_FULL -> Outcome.FULL
    RelayWire.REFUSED_BLOCKED -> Outcome.BLOCKED
    RelayWire.REFUSED_VERSION -> Outcome.OTHER_VERSION
    else -> Outcome.TIMEOUT
  }

  private fun pingLoop(out: OutputStream, mine: Int) {
    while (current(mine)) {
      try {
        Thread.sleep(pingIntervalMs)
      } catch (_: InterruptedException) {
        return
      }
      val delayUs = latency.numbers(clockNs(), clock).relayDelayMedianMs
        ?.let { (it * 1000).toLong().coerceIn(0, Int.MAX_VALUE.toLong()).toInt() } ?: -1
      val shown = runCatching { listener.shownPer10s() }.getOrDefault(-1)
      try {
        synchronized(outputLock) {
          RelayWire.write(out, RelayWire.PING, 0, RelayWire.pingBody(clockNs(), delayUs, shown))
          out.flush()
        }
      } catch (_: IOException) {
        return
      }
    }
  }

  /** Under [lock]: the bye goes on a thread of its own, never on the caller's (the main thread cannot write a socket) */
  private fun closeCurrent(sendBye: Boolean) {
    val open = socket ?: return
    val out = output
    socket = null
    output = null
    Thread({
      if (sendBye && out != null) {
        runCatching {
          synchronized(outputLock) {
            RelayWire.write(out, RelayWire.HEADSET_BYE, 0, ByteArray(0))
            out.flush()
          }
        }
      }
      runCatching { open.close() }
    }, "DjiRelayBye").apply { isDaemon = true }.start()
  }

  private fun setState(next: RelayReceiveState) {
    state = next
    runCatching { listener.onChanged() }
  }

  /** A state of the session [mine], dropped once a newer connect or a disconnect replaced it */
  private fun setStateFor(mine: Int, next: RelayReceiveState) {
    synchronized(lock) {
      if (generation != mine) {
        return
      }
      state = next
    }
    runCatching { listener.onChanged() }
  }

  /** Marks the receiver refused before it started: a remote is open on this device's cable */
  fun refuseBusy() {
    disconnect()
    setState(RelayReceiveState.BUSY)
  }

  fun snapshot(nowNs: Long = clockNs()): RelayReceiveSnapshot {
    val target = synchronized(lock) { this.target }
    val said = welcome
    synchronized(countsLock) {
      val last = telemetry
      return RelayReceiveSnapshot(
        state = state,
        phoneName = said?.phoneName,
        phoneId = said?.phoneId ?: target?.phoneId,
        host = target?.host,
        port = target?.port,
        phoneSource = last?.link?.source ?: said?.source ?: "none",
        replayName = last?.link?.replayName ?: said?.replayName,
        replayPositionMs = last?.link?.replayPositionMs,
        reconnectInMs = reconnectAtNs?.let { ((it - nowNs) / 1_000_000).coerceAtLeast(0) },
        failures = failures,
        units = units,
        lostOnWifi = lostOnWifi,
        breaks = breaks,
        latency = latency.numbers(nowNs, clock),
        telemetry = last,
        telemetryAgeMs = telemetryAtNs?.let { (nowNs - it) / 1_000_000 },
        lastUnitAgoMs = lastUnitNs?.let { (nowNs - it) / 1_000_000 },
      )
    }
  }

  private fun JsonObject?.text(name: String): String? = (this?.get(name) as? JsonPrimitive)?.contentOrNull
}
