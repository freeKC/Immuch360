package app.alextran.immich.djilink

import java.io.DataInputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.Json

/**
 * Relay protocol 1: the phone sends the drone's picture and flight values, as it received them, to Immuch360 on a
 * headset of the same local network. Written for this app (p2/design-stage2b.md, section 4); it carries the access
 * units and the values stage 2 already reads and no identifier of the drone's own protocol.
 *
 * TCP over IPv4, one connection per headset, the phone listening. Everything is big endian. Each record is an 8 byte
 * header (type, flags, two reserved bytes, body length) and its body. The phone speaks first with a challenge; the
 * headset answers with a hello that proves it knows the code; the phone proves it back in its welcome. From then on
 * the phone sends parameter sets, units, resets, telemetry and pongs, and the headset sends pings. The headset can send
 * three records and nothing else: [HELLO], [PING] and [HEADSET_BYE]. There is no command record: nothing a headset
 * sends reaches the remote or the aircraft.
 *
 * Proofs: HMAC-SHA256 keyed by the normalised code over the label, a role byte and both nonces. The code itself never
 * crosses the network. Known answers in src/test/resources/djilink/relay-vectors.json, made by make_relay_vectors.py
 * beside it, written apart from this code.
 */
object RelayWire {
  const val VERSION = 1
  val MAGIC: ByteArray = byteArrayOf('I'.code.toByte(), 'M'.code.toByte(), 'R'.code.toByte(), '1'.code.toByte())

  /** 8360 is the phone share, 8361 the pairing */
  const val DEFAULT_PORT = 8362
  const val HEADER_BYTES = 8
  const val NONCE_BYTES = 16
  const val PROOF_BYTES = 32
  const val UNIT_HEADER_BYTES = 32

  /**
   * The unit header with the content clock after the 32 bytes: sent only to a receiver whose hello says it reads it
   * (`"unitHeader": 40`), and said so in the welcome; a receiver of an earlier build gets the 32 bytes as before
   */
  const val UNIT_HEADER_LONG_BYTES = 40
  const val MAX_UNIT_BYTES = AccessUnitAssembler.MAX_UNIT_BYTES
  const val MAX_JSON_BYTES = 64 * 1024
  const val MAX_HELLO_BYTES = 1024
  const val MAX_PARAMETERS_BYTES = 64 * 1024
  const val CHALLENGE_BYTES = 4 + 1 + NONCE_BYTES
  const val HELLO_MIN_BYTES = 4 + 1 + NONCE_BYTES + PROOF_BYTES
  const val PING_BYTES = 16

  /**
   * A ping with the receiver's own numbers after the 16 bytes ([RelayPingNumbers]): sent only when the welcome says the
   * phone takes it (`"pingBytes": 64`); the phone takes either length
   */
  const val PING_LONG_BYTES = 64

  /**
   * The long ping with this receiver's own network after the 64 bytes ([RelayPingNetwork]): sent only when the welcome
   * says the phone takes it (`"pingBytes": 96`, given to a hello that asked for it); the phone takes the three lengths
   * (p2/relay-bandwidth-2026-10-25.md, 7.8)
   */
  const val PING_STEADY_BYTES = 96
  const val PONG_BYTES = 24
  const val LABEL = "immuch360 drone relay 1"
  const val ROLE_HEADSET = 1
  const val ROLE_PHONE = 2

  /** DSCP CS5, which Wi-Fi multimedia maps to its video access category (RFC 8325); harmless where it is ignored */
  const val TRAFFIC_CLASS = 0xA0

  /**
   * The send buffer is no longer pinned: the kernel tunes it, and only the bytes it holds unsent are bounded, to this
   * (TCP_NOTSENT_LOWAT), so that a backlog waits in the queue of the receiver where it is aged and measured. Where the
   * option is refused, [FALLBACK_SEND_BUFFER_BYTES] is asked instead: 230 ms of the 17.9 Mbit/s of a flight.
   */
  const val NOT_SENT_LOW_WATER_BYTES = 256 * 1024
  const val FALLBACK_SEND_BUFFER_BYTES = 512 * 1024

  /** The write buffer in front of the socket, and the read buffer of a receiver */
  const val STREAM_BUFFER_BYTES = 64 * 1024

  // Records from the phone
  const val CHALLENGE = 0x01
  const val WELCOME = 0x02
  const val REFUSED = 0x03
  const val PARAMETERS = 0x10
  const val UNIT = 0x11
  const val RESET = 0x12
  const val TELEMETRY = 0x20
  const val PONG = 0x21
  const val BYE = 0x22

  // Records from the headset: the complete list
  const val HELLO = 0x81
  const val PING = 0x82
  const val HEADSET_BYE = 0x83

  // Flags of a UNIT record
  const val UNIT_KEY = 0x01
  const val UNIT_IN_BAND = 0x02
  const val UNIT_BREAK = 0x04
  const val UNIT_REPLAY = 0x08

  /**
   * The last key unit the phone saw, sent once right after the parameter sets to a headset that joins mid stream: an
   * old picture to start the decoder from, never a live one ([KeyPrimer]). It takes the next sequence number like any
   * unit. A headset of an earlier build reads it as a key unit.
   */
  const val UNIT_PRIMER = 0x10

  /**
   * A unit of the phone's own steady stream (p2/relay-bandwidth-2026-10-25.md, 7.8): encoded again on the phone for a
   * receiver whose Wi-Fi cannot carry the drone's stream. Sent only to a receiver whose hello says `"steady": 1`.
   */
  const val UNIT_PHONE = 0x20

  // The reasons of REFUSED and BYE
  const val REFUSED_CODE = "code"
  const val REFUSED_BLOCKED = "blocked"
  const val REFUSED_FULL = "full"
  const val REFUSED_VERSION = "version"
  const val REFUSED_TIMEOUT = "timeout"
  const val BYE_STOPPED = "stopped"
  const val BYE_NEW_CODE = "newCode"
  const val BYE_CLOSING = "closing"

  /** The pairing alphabet: no 0, O, 1, I nor L */
  const val CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
  const val CODE_LENGTH = 10

  /** The flags of a PARAMETERS record: where the phone's description comes from */
  fun parametersFlag(source: DescriptionSource): Int = when (source) {
    DescriptionSource.SESSION -> 1
    DescriptionSource.CACHE -> 2
    DescriptionSource.PROFILE -> 3
  }

  /**
   * The flag of the PARAMETERS record of the phone's steady stream: its own encoder made them. A receiver of an earlier
   * build never gets it; one of this build reads it as a session description.
   */
  const val PARAMETERS_PHONE_ENCODER = 4

  fun sourceOfParametersFlag(flag: Int): DescriptionSource? = when (flag) {
    1 -> DescriptionSource.SESSION
    2 -> DescriptionSource.CACHE
    3 -> DescriptionSource.PROFILE
    PARAMETERS_PHONE_ENCODER -> DescriptionSource.SESSION
    else -> null
  }

  /** The body sizes a record of [type] may have when the phone sends it; null for a type the phone never sends */
  fun bodyRangeFromPhone(type: Int): IntRange? = when (type) {
    CHALLENGE -> CHALLENGE_BYTES..CHALLENGE_BYTES
    WELCOME -> PROOF_BYTES..(PROOF_BYTES + MAX_JSON_BYTES)
    REFUSED, RESET, BYE, TELEMETRY -> 0..MAX_JSON_BYTES
    PARAMETERS -> 0..MAX_PARAMETERS_BYTES
    UNIT -> UNIT_HEADER_BYTES..(UNIT_HEADER_LONG_BYTES + MAX_UNIT_BYTES)
    PONG -> PONG_BYTES..PONG_BYTES
    else -> null
  }

  /** The body sizes a record of [type] may have when the headset sends it; null for anything else, which closes */
  fun bodyRangeFromHeadset(type: Int): IntRange? = when (type) {
    HELLO -> HELLO_MIN_BYTES..MAX_HELLO_BYTES
    PING -> PING_BYTES..PING_STEADY_BYTES
    HEADSET_BYE -> 0..0
    else -> null
  }

  /** Checks a header read from the other side; throws when the type is not allowed or the length is out of range */
  fun check(type: Int, length: Long, fromPhone: Boolean) {
    val range = (if (fromPhone) bodyRangeFromPhone(type) else bodyRangeFromHeadset(type))
      ?: throw RelayProtocolException("unexpectedType", type)
    if (length < range.first || length > range.last) {
      throw RelayProtocolException("badLength", type)
    }
    if (!fromPhone && type == PING && length != PING_BYTES.toLong() && length != PING_LONG_BYTES.toLong() &&
      length != PING_STEADY_BYTES.toLong()
    ) {
      throw RelayProtocolException("badLength", type)
    }
  }

  /** A short name of a record type, for the exports */
  fun typeName(type: Int): String = when (type) {
    CHALLENGE -> "challenge"
    WELCOME -> "welcome"
    REFUSED -> "refused"
    PARAMETERS -> "parameters"
    UNIT -> "unit"
    RESET -> "reset"
    TELEMETRY -> "telemetry"
    PONG -> "pong"
    BYE -> "bye"
    HELLO -> "hello"
    PING -> "ping"
    HEADSET_BYE -> "headsetBye"
    else -> "type$type"
  }

  fun header(type: Int, flags: Int, length: Int): ByteArray {
    val out = ByteArray(HEADER_BYTES)
    out[0] = type.toByte()
    out[1] = flags.toByte()
    putU32(out, 4, length.toLong())
    return out
  }

  /** One record as one array: header and body */
  fun record(type: Int, flags: Int, body: ByteArray): ByteArray = header(type, flags, body.size) + body

  fun write(out: OutputStream, type: Int, flags: Int, body: ByteArray) {
    out.write(header(type, flags, body.size))
    out.write(body)
  }

  /**
   * Reads one record with blocking reads, the header checked before the body is read, so that a length above the
   * limits never allocates anything
   */
  fun read(input: DataInputStream, fromPhone: Boolean): RelayRecord {
    val head = ByteArray(HEADER_BYTES)
    input.readFully(head)
    val type = head[0].toInt() and 0xFF
    val flags = head[1].toInt() and 0xFF
    val length = u32(head, 4)
    check(type, length, fromPhone)
    val body = ByteArray(length.toInt())
    input.readFully(body)
    return RelayRecord(type, flags, body)
  }

  // Bodies

  fun challengeBody(serverNonce: ByteArray): ByteArray {
    require(serverNonce.size == NONCE_BYTES)
    return MAGIC + byteArrayOf(VERSION.toByte()) + serverNonce
  }

  /** The version and the server nonce of a challenge; throws when it is not one of this protocol's */
  fun parseChallenge(body: ByteArray): Pair<Int, ByteArray> {
    if (body.size != CHALLENGE_BYTES || !body.copyOfRange(0, 4).contentEquals(MAGIC)) {
      throw RelayProtocolException("badChallenge", CHALLENGE)
    }
    return (body[4].toInt() and 0xFF) to body.copyOfRange(5, 5 + NONCE_BYTES)
  }

  fun helloBody(clientNonce: ByteArray, proof: ByteArray, json: String): ByteArray {
    require(clientNonce.size == NONCE_BYTES && proof.size == PROOF_BYTES)
    return MAGIC + byteArrayOf(VERSION.toByte()) + clientNonce + proof + json.toByteArray(Charsets.UTF_8)
  }

  fun parseHello(body: ByteArray): RelayHello {
    if (body.size < HELLO_MIN_BYTES || !body.copyOfRange(0, 4).contentEquals(MAGIC)) {
      throw RelayProtocolException("badHello", HELLO)
    }
    var at = 5
    val nonce = body.copyOfRange(at, at + NONCE_BYTES)
    at += NONCE_BYTES
    val proof = body.copyOfRange(at, at + PROOF_BYTES)
    at += PROOF_BYTES
    val json = parseJson(body, at)
    return RelayHello(body[4].toInt() and 0xFF, nonce, proof, json)
  }

  fun welcomeBody(proof: ByteArray, json: String): ByteArray {
    require(proof.size == PROOF_BYTES)
    return proof + json.toByteArray(Charsets.UTF_8)
  }

  /**
   * A ping of 16 bytes, of [PING_LONG_BYTES] with the receiver's [numbers], or of [PING_STEADY_BYTES] with its
   * [network] too (its numbers then -1 when not given)
   */
  fun pingBody(
    sendNs: Long,
    relayDelayMedianUs: Int,
    shownPer10s: Int,
    numbers: RelayPingNumbers? = null,
    network: RelayPingNetwork? = null,
  ): ByteArray {
    val size = when {
      network != null -> PING_STEADY_BYTES
      numbers != null -> PING_LONG_BYTES
      else -> PING_BYTES
    }
    val out = ByteArray(size)
    putI64(out, 0, sendNs)
    putI32(out, 8, relayDelayMedianUs)
    putI32(out, 12, shownPer10s)
    if (size >= PING_LONG_BYTES) {
      val said = numbers ?: RelayPingNumbers()
      said.values().forEachIndexed { index, value -> putI32(out, PING_BYTES + 4 * index, value) }
    }
    network?.values()?.forEachIndexed { index, value -> putI32(out, PING_LONG_BYTES + 4 * index, value) }
    return out
  }

  fun parsePing(body: ByteArray): RelayPing {
    if (body.size != PING_BYTES && body.size != PING_LONG_BYTES && body.size != PING_STEADY_BYTES) {
      throw RelayProtocolException("badLength", PING)
    }
    val numbers = if (body.size >= PING_LONG_BYTES) {
      RelayPingNumbers.of(IntArray(RelayPingNumbers.COUNT) { i32(body, PING_BYTES + 4 * it) })
    } else {
      null
    }
    val network = if (body.size == PING_STEADY_BYTES) {
      RelayPingNetwork.of(IntArray(RelayPingNetwork.COUNT) { i32(body, PING_LONG_BYTES + 4 * it) })
    } else {
      null
    }
    return RelayPing(i64(body, 0), i32(body, 8), i32(body, 12), numbers, network)
  }

  fun pongBody(pingSendNs: Long, receivedNs: Long, sentNs: Long): ByteArray {
    val out = ByteArray(PONG_BYTES)
    putI64(out, 0, pingSendNs)
    putI64(out, 8, receivedNs)
    putI64(out, 16, sentNs)
    return out
  }

  fun parsePong(body: ByteArray): RelayPong {
    if (body.size != PONG_BYTES) {
      throw RelayProtocolException("badLength", PONG)
    }
    return RelayPong(i64(body, 0), i64(body, 8), i64(body, 16))
  }

  /** The header of [UNIT_HEADER_BYTES], or of [UNIT_HEADER_LONG_BYTES] with the content clock */
  fun unitHeader(header: RelayUnitHeader, bytes: Int = UNIT_HEADER_BYTES): ByteArray {
    require(bytes == UNIT_HEADER_BYTES || bytes == UNIT_HEADER_LONG_BYTES)
    val out = ByteArray(bytes)
    putU32(out, 0, header.sequence and 0xFFFF_FFFFL)
    putI64(out, 4, header.firstArrivalNs)
    putI64(out, 12, header.lastArrivalNs)
    putI64(out, 20, header.sendNs)
    putI32(out, 28, header.pictureCounter)
    if (bytes == UNIT_HEADER_LONG_BYTES) {
      putI64(out, 32, header.contentMs)
    }
    return out
  }

  fun parseUnitHeader(body: ByteArray, bytes: Int = UNIT_HEADER_BYTES): RelayUnitHeader {
    if (body.size < bytes) {
      throw RelayProtocolException("badLength", UNIT)
    }
    val content = if (bytes >= UNIT_HEADER_LONG_BYTES) i64(body, 32) else -1L
    return RelayUnitHeader(u32(body, 0), i64(body, 4), i64(body, 12), i64(body, 20), i32(body, 28), content)
  }

  /** The VPS, SPS and PPS behind their start codes, as a decoder takes them */
  fun parametersBody(description: StreamDescription): ByteArray = description.configuration()

  /** The three sets of a PARAMETERS body, null when one is missing or the SPS does not parse */
  fun parseParameters(body: ByteArray): StreamDescription? {
    var vps: ByteArray? = null
    var sps: ByteArray? = null
    var pps: ByteArray? = null
    for (nal in AnnexB.split(body)) {
      if (nal.size < 2) {
        continue
      }
      val bytes = body.copyOfRange(nal.offset, nal.end)
      when (HevcNal.type(bytes[0].toInt() and 0xFF)) {
        HevcNal.VPS -> vps = bytes
        HevcNal.SPS -> sps = bytes
        HevcNal.PPS -> pps = bytes
      }
    }
    val s = sps ?: return null
    val info = HevcSpsReader.parse(s, 0, s.size) ?: return null
    return StreamDescription(vps ?: return null, s, pps ?: return null, info)
  }

  /**
   * The access unit of a UNIT body: the bytes as the phone received them, cut into NAL units with the Annex B split.
   * The headset has no assembler: the unit is whole, so nothing waits for the next one.
   */
  fun accessUnitOf(body: ByteArray, arrivalNs: Long, headerBytes: Int = UNIT_HEADER_BYTES): AccessUnit =
    annexBUnit(body.copyOfRange(headerBytes, body.size), arrivalNs)

  /** An access unit of Annex B [bytes], whole, arrived at [arrivalNs] */
  fun annexBUnit(bytes: ByteArray, arrivalNs: Long): AccessUnit {
    val nals = AnnexB.split(bytes)
    return AccessUnit(
      bytes = bytes,
      nalTypes = IntArray(nals.size) { HevcNal.type(bytes[nals[it].offset].toInt() and 0xFF) },
      nalOffsets = IntArray(nals.size) { nals[it].offset },
      firstArrivalNs = arrivalNs,
      lastArrivalNs = arrivalNs,
      closedBy = AccessUnitClose.BOUNDARY,
    )
  }

  fun jsonBody(json: JsonObject): ByteArray = json.toString().toByteArray(Charsets.UTF_8)

  /** The JSON object from [from] to the end, null when it is not one */
  fun parseJson(body: ByteArray, from: Int = 0): JsonObject? = runCatching {
    Json.parseToJsonElement(String(body, from, body.size - from, Charsets.UTF_8)).jsonObject
  }.getOrNull()

  // Proofs

  /** HMAC-SHA256 keyed by the normalised code over the label, the role byte and both nonces */
  fun proof(code: String, role: Int, serverNonce: ByteArray, clientNonce: ByteArray): ByteArray {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(code.toByteArray(Charsets.UTF_8), "HmacSHA256"))
    mac.update(LABEL.toByteArray(Charsets.UTF_8))
    mac.update(role.toByte())
    mac.update(serverNonce)
    mac.update(clientNonce)
    return mac.doFinal()
  }

  /** In constant time */
  fun proofMatches(expected: ByteArray, given: ByteArray): Boolean = MessageDigest.isEqual(expected, given)

  /** The code as typed, in capitals without spaces and dashes; null when it cannot be a code of the pairing alphabet */
  fun normalizeCode(typed: String): String? {
    val code = typed.filter { !it.isWhitespace() && it != '-' }.uppercase()
    if (code.length != CODE_LENGTH || code.any { it !in CODE_ALPHABET }) {
      return null
    }
    return code
  }

  // Addresses

  /** Loopback, 10/8, 172.16/12, 192.168/16 and 169.254/16: the local network, IPv4 only */
  fun isLocalNetworkAddress(address: InetAddress?): Boolean {
    if (address !is Inet4Address) {
      return false
    }
    val bytes = address.address.map { it.toInt() and 0xFF }
    return bytes[0] == 127 ||
      bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] in 16..31) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254)
  }

  /** A host written as four plain decimal numbers of the local network ([isLocalNetworkAddress]), loopback included */
  fun isLocalIPv4Literal(host: String): Boolean {
    val parts = host.split('.')
    if (parts.size != 4 || parts.any { !Regex("^(0|[1-9][0-9]{0,2})$").matches(it) || it.toInt() > 255 }) {
      return false
    }
    val bytes = parts.map { it.toInt() }
    return bytes[0] == 127 ||
      bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] in 16..31) ||
      (bytes[0] == 192 && bytes[1] == 168) ||
      (bytes[0] == 169 && bytes[1] == 254)
  }

  /** The interfaces of mobile data and VPNs, the skip list of the phone share's addresses */
  private val SKIPPED_INTERFACES = listOf("rmnet", "ccmni", "pdp", "tun", "ppp", "wg", "ipsec", "clat", "v4-", "dummy")

  fun isSkippedInterface(name: String?): Boolean {
    val lower = name?.lowercase() ?: return false
    return SKIPPED_INTERFACES.any { lower.startsWith(it) }
  }

  // Numbers

  fun putU32(out: ByteArray, at: Int, value: Long) {
    out[at] = (value ushr 24).toByte()
    out[at + 1] = (value ushr 16).toByte()
    out[at + 2] = (value ushr 8).toByte()
    out[at + 3] = value.toByte()
  }

  fun putI32(out: ByteArray, at: Int, value: Int) = putU32(out, at, value.toLong())

  fun putI64(out: ByteArray, at: Int, value: Long) {
    for (index in 0 until 8) {
      out[at + index] = (value ushr (56 - 8 * index)).toByte()
    }
  }

  fun u32(bytes: ByteArray, at: Int): Long =
    ((bytes[at].toLong() and 0xFF) shl 24) or ((bytes[at + 1].toLong() and 0xFF) shl 16) or
      ((bytes[at + 2].toLong() and 0xFF) shl 8) or (bytes[at + 3].toLong() and 0xFF)

  fun i32(bytes: ByteArray, at: Int): Int = u32(bytes, at).toInt()

  fun i64(bytes: ByteArray, at: Int): Long {
    var value = 0L
    for (index in 0 until 8) {
      value = (value shl 8) or (bytes[at + index].toLong() and 0xFF)
    }
    return value
  }
}

/** A record that breaks the rules of the protocol: the connection that sent it closes */
class RelayProtocolException(val reason: String, val type: Int) : Exception("$reason (type 0x%02x)".format(type))

class RelayRecord(val type: Int, val flags: Int, val body: ByteArray)

class RelayHello(val version: Int, val clientNonce: ByteArray, val proof: ByteArray, val json: JsonObject?)

data class RelayPing(
  val sendNs: Long,
  val relayDelayMedianUs: Int,
  val shownPer10s: Int,
  /** The receiver's own numbers, in a ping of [RelayWire.PING_LONG_BYTES]; null in a short one */
  val numbers: RelayPingNumbers? = null,
  /** The receiver's own network, in a ping of [RelayWire.PING_STEADY_BYTES]; null in a shorter one */
  val network: RelayPingNetwork? = null,
)

/**
 * What a receiver says of its own picture in a long ping, so that the phone's export holds both ends: twelve signed 32
 * bit numbers after the 16 bytes of the ping, -1 when unknown. Counts are since the receiver connected.
 */
data class RelayPingNumbers(
  val bufferTargetMs: Int = -1,
  val bufferNowMs: Int = -1,
  val freezes: Int = -1,
  val longestFreezeMs: Int = -1,
  val renderSkips: Int = -1,
  val lateUnits: Int = -1,
  val decoderStalls: Int = -1,
  val sequenceGaps: Int = -1,
  val primersUsed: Int = -1,
  /** The round trip of its last ping, in microseconds */
  val roundTripUs: Int = -1,
  /** Phone receive to picture shown there, median of its last 10 s */
  val phoneToShownMs: Int = -1,
  val safetyFlushes: Int = -1,
) {
  companion object {
    const val COUNT = 12

    fun of(values: IntArray): RelayPingNumbers = RelayPingNumbers(
      values[0], values[1], values[2], values[3], values[4], values[5],
      values[6], values[7], values[8], values[9], values[10], values[11],
    )
  }

  fun values(): IntArray = intArrayOf(
    bufferTargetMs, bufferNowMs, freezes, longestFreezeMs, renderSkips, lateUnits,
    decoderStalls, sequenceGaps, primersUsed, roundTripUs, phoneToShownMs, safetyFlushes,
  )
}

/**
 * What a receiver says of its own network in a ping of [RelayWire.PING_STEADY_BYTES] (p2/relay-bandwidth-2026-10-25.md,
 * 7.8 item 4), so that the phone's export says which of the two Wi-Fi hops is weak: eight signed 32 bit numbers after
 * the 64 bytes, -1 when unknown. A state, never a request: the phone decides what it sends.
 */
data class RelayPingNetwork(
  /** [TRANSPORT_WIFI], [TRANSPORT_ETHERNET], [TRANSPORT_OTHER], or -1 */
  val transport: Int = -1,
  val frequencyMhz: Int = -1,
  val linkMbps: Int = -1,
  val rssiDbm: Int = -1,
  /** Bytes of the relay read in the last second */
  val bytesLastSecond: Int = -1,
  /** The longest wait between two records read in the last second, in milliseconds */
  val longestReadGapMs: Int = -1,
  val spare1: Int = -1,
  val spare2: Int = -1,
) {
  companion object {
    const val COUNT = 8
    const val TRANSPORT_WIFI = 1
    const val TRANSPORT_ETHERNET = 2
    const val TRANSPORT_OTHER = 3

    fun of(values: IntArray): RelayPingNetwork =
      RelayPingNetwork(values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7])

    /** The transport as [NetworkFacts] names it */
    fun transportOf(name: String?): Int = when (name) {
      "wifi" -> TRANSPORT_WIFI
      "ethernet" -> TRANSPORT_ETHERNET
      null -> -1
      else -> TRANSPORT_OTHER
    }

    fun transportName(value: Int): String? = when (value) {
      TRANSPORT_WIFI -> "wifi"
      TRANSPORT_ETHERNET -> "ethernet"
      TRANSPORT_OTHER -> "other"
      else -> null
    }
  }

  fun values(): IntArray =
    intArrayOf(transport, frequencyMhz, linkMbps, rssiDbm, bytesLastSecond, longestReadGapMs, spare1, spare2)

  /** 2.4, 5 or 6 (GHz), from the frequency */
  val band: String? get() = frequencyMhz.takeIf { it > 0 }?.let { NetworkFacts.bandOf(it) }
}

data class RelayPong(val pingSendNs: Long, val receivedNs: Long, val sentNs: Long)

/** The 32 or 40 bytes before the bytes of a unit: all times on the phone's clock */
data class RelayUnitHeader(
  /** +1 per unit sent to this headset, 0 for the first after the welcome; a jump means units were dropped for it */
  val sequence: Long,
  /** The first fragment of the unit arrived (the USB read, or the player's feed of a capture) */
  val firstArrivalNs: Long,
  /** The last fragment arrived: the phone receive time */
  val lastArrivalNs: Long,
  /** The phone started writing this record to the socket */
  val sendNs: Long,
  /** The SEI 240 picture counter of the unit, -1 when it has none */
  val pictureCounter: Int,
  /** The content clock the phone unwrapped, in milliseconds; -1 when it has none or the header is the short one */
  val contentMs: Long = -1,
)

/**
 * Cuts a byte stream into records whatever its split, checking each header as soon as it is complete: the decoder of
 * the tests, and of anything that reads without blocking.
 */
class RelayRecordDecoder(private val fromPhone: Boolean) {
  private var buffer = ByteArray(4096)
  private var length = 0

  fun offer(bytes: ByteArray, from: Int = 0, count: Int = bytes.size - from): List<RelayRecord> {
    ensure(length + count)
    System.arraycopy(bytes, from, buffer, length, count)
    length += count
    val out = mutableListOf<RelayRecord>()
    var at = 0
    while (length - at >= RelayWire.HEADER_BYTES) {
      val type = buffer[at].toInt() and 0xFF
      val flags = buffer[at + 1].toInt() and 0xFF
      val bodyLength = RelayWire.u32(buffer, at + 4)
      RelayWire.check(type, bodyLength, fromPhone)
      val end = at + RelayWire.HEADER_BYTES + bodyLength.toInt()
      if (end > length) {
        break
      }
      out.add(RelayRecord(type, flags, buffer.copyOfRange(at + RelayWire.HEADER_BYTES, end)))
      at = end
    }
    if (at > 0) {
      System.arraycopy(buffer, at, buffer, 0, length - at)
      length -= at
    }
    return out
  }

  /** Bytes of a record not yet complete */
  val pending: Int get() = length

  private fun ensure(size: Int) {
    if (size > buffer.size) {
      buffer = buffer.copyOf(maxOf(size, buffer.size * 2))
    }
  }
}
