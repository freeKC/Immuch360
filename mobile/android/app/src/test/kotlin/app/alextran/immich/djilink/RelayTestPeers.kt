package app.alextran.immich.djilink

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonPrimitive

/** A headset written for the tests from section 4 of the design: it speaks the protocol by hand over a real socket */
class TestHeadset(port: Int, private val timeoutMs: Int = 5_000) : AutoCloseable {
  val socket = Socket().apply {
    connect(InetSocketAddress(InetAddress.getLoopbackAddress(), port), timeoutMs)
    soTimeout = timeoutMs
    tcpNoDelay = true
  }
  val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
  val output: OutputStream = BufferedOutputStream(socket.getOutputStream())
  var serverNonce = ByteArray(0)
  val clientNonce = ByteArray(RelayWire.NONCE_BYTES) { (it * 7).toByte() }

  fun read(): RelayRecord = RelayWire.read(input, fromPhone = true)

  fun send(type: Int, body: ByteArray, flags: Int = 0) {
    RelayWire.write(output, type, flags, body)
    output.flush()
  }

  fun challenge(): RelayRecord {
    val record = read()
    if (record.type == RelayWire.CHALLENGE) {
      serverNonce = RelayWire.parseChallenge(record.body).second
    }
    return record
  }

  /** [extra]: more fields of the hello's JSON, written as they go after a comma */
  fun hello(code: String, name: String = "Quest 3", kind: String? = null, extra: String = "") {
    val proof = RelayWire.proof(code, RelayWire.ROLE_HEADSET, serverNonce, clientNonce)
    val said = (if (kind == null) "" else ",\"kind\":\"$kind\"") + (if (extra.isEmpty()) "" else ",$extra")
    send(RelayWire.HELLO, RelayWire.helloBody(clientNonce, proof, """{"name":"$name","app":"test"$said}"""))
  }

  /** The whole handshake: the record that answers the hello (WELCOME or REFUSED) */
  fun join(code: String, name: String = "Quest 3", kind: String? = null, extra: String = ""): RelayRecord {
    challenge()
    hello(code, name, kind, extra)
    return read()
  }

  fun welcomeProved(record: RelayRecord, code: String): Boolean =
    record.type == RelayWire.WELCOME && RelayWire.proofMatches(
      RelayWire.proof(code, RelayWire.ROLE_PHONE, serverNonce, clientNonce),
      record.body.copyOfRange(0, RelayWire.PROOF_BYTES),
    )

  fun ping(sendNs: Long = System.nanoTime()) = send(RelayWire.PING, RelayWire.pingBody(sendNs, 12_000, 290))

  /** Reads until a record of [type] comes, the others kept in [seen] */
  fun readUntil(type: Int, seen: MutableList<RelayRecord> = mutableListOf()): RelayRecord {
    while (true) {
      val record = read()
      if (record.type == type) {
        return record
      }
      seen += record
    }
  }

  /** True when the phone closed the connection: the next read ends */
  fun closedByPhone(): Boolean = try {
    while (true) {
      read()
    }
    @Suppress("UNREACHABLE_CODE")
    false
  } catch (_: java.io.EOFException) {
    true
  } catch (_: java.net.SocketException) {
    true
  }

  override fun close() {
    runCatching { socket.close() }
  }
}

fun reason(record: RelayRecord): String? =
  (RelayWire.parseJson(record.body)?.get("reason") as? JsonPrimitive)?.content

/**
 * A phone written for the tests: it listens on loopback and answers each connection with the script it is given. The
 * script sees the socket's streams and returns when that connection should close.
 */
class TestPhone(private val script: TestPhone.Connection.() -> Unit) : AutoCloseable {
  class Connection(val socket: Socket, val code: String) {
    val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
    val output: OutputStream = BufferedOutputStream(socket.getOutputStream())
    val serverNonce = ByteArray(RelayWire.NONCE_BYTES) { (it + 3).toByte() }
    var hello: RelayHello? = null

    fun send(type: Int, body: ByteArray, flags: Int = 0) {
      synchronized(output) {
        RelayWire.write(output, type, flags, body)
        output.flush()
      }
    }

    fun read(): RelayRecord = RelayWire.read(input, fromPhone = false)

    fun challenge() = send(RelayWire.CHALLENGE, RelayWire.challengeBody(serverNonce))

    /** Challenge, hello, welcome with the proof of [proofCode] (the right code by default) */
    fun welcome(proofCode: String = code, json: String = """{"v":1,"phone":"Galaxy S24+","id":"3f9c0a1b2c3d4e5f","source":"replay"}""") {
      challenge()
      val record = read()
      hello = RelayWire.parseHello(record.body)
      val proof = RelayWire.proof(proofCode, RelayWire.ROLE_PHONE, serverNonce, hello!!.clientNonce)
      send(RelayWire.WELCOME, RelayWire.welcomeBody(proof, json))
    }

    fun refuse(reason: String) {
      challenge()
      read()
      send(RelayWire.REFUSED, """{"reason":"$reason"}""".toByteArray())
    }
  }

  val server = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
  val port: Int get() = server.localPort
  val connections = LinkedBlockingQueue<Long>()
  var code = "K7M2Q9XRTH"

  @Volatile
  private var open = true

  init {
    Thread({
      while (open) {
        val socket = runCatching { server.accept() }.getOrNull() ?: break
        connections.add(System.nanoTime())
        Thread({
          runCatching { Connection(socket, code).script() }
          runCatching { socket.close() }
        }, "TestPhoneConnection").apply { isDaemon = true }.start()
      }
    }, "TestPhone").apply { isDaemon = true }.start()
  }

  /** The time of the next connection, waiting up to [timeoutMs] */
  fun nextConnection(timeoutMs: Long = 5_000): Long? = connections.poll(timeoutMs, TimeUnit.MILLISECONDS)

  override fun close() {
    open = false
    runCatching { server.close() }
  }
}

/** What a receiver's listener saw */
open class RecordingReceiverListener : RelayReceiver.Listener {
  val events = LinkedBlockingQueue<String>()
  val units = mutableListOf<Pair<AccessUnit, RelayUnitHeader>>()

  /** The sequences of the units that came with BREAK */
  val breaks = java.util.concurrent.CopyOnWriteArrayList<Long>()
  val parameters = mutableListOf<Pair<StreamDescription, DescriptionSource>>()

  override fun onConnected(welcome: RelayWelcome) {
    events.add("connected ${welcome.phoneName}")
  }

  override fun onParameters(description: StreamDescription, source: DescriptionSource, arrivalNs: Long) {
    synchronized(parameters) { parameters += description to source }
    events.add("parameters")
  }

  override fun onUnit(unit: AccessUnit, header: RelayUnitHeader, flags: Int, arrivalNs: Long) {
    synchronized(units) { units += unit to header }
    if ((flags and RelayWire.UNIT_BREAK) != 0) {
      breaks += header.sequence
    }
    events.add("unit ${header.sequence}")
  }

  override fun onReset() {
    events.add("reset")
  }

  override fun onDisconnected() {
    events.add("disconnected")
  }

  override fun onChanged() = Unit

  fun await(prefix: String, timeoutMs: Long = 5_000): String? {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (true) {
      val left = deadline - System.currentTimeMillis()
      if (left <= 0) {
        return null
      }
      val event = events.poll(left, TimeUnit.MILLISECONDS) ?: return null
      if (event.startsWith(prefix)) {
        return event
      }
    }
  }
}

/** Waits up to [timeoutMs] for [condition] */
fun eventually(timeoutMs: Long = 5_000, condition: () -> Boolean): Boolean {
  val deadline = System.currentTimeMillis() + timeoutMs
  while (System.currentTimeMillis() < deadline) {
    if (condition()) {
      return true
    }
    Thread.sleep(10)
  }
  return condition()
}
