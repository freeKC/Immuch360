package app.alextran.immich.djilink

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.net.InetAddress

/** The records of relay protocol 1: every one round trips, the limits hold, any split of the bytes reads the same */
class RelayWireTest {
  private fun nonce(seed: Int) = ByteArray(RelayWire.NONCE_BYTES) { (seed + it).toByte() }

  private fun decodeAll(bytes: ByteArray, fromPhone: Boolean, step: Int): List<RelayRecord> {
    val decoder = RelayRecordDecoder(fromPhone)
    val out = mutableListOf<RelayRecord>()
    var at = 0
    while (at < bytes.size) {
      val count = minOf(step, bytes.size - at)
      out += decoder.offer(bytes, at, count)
      at += count
    }
    assertEquals(0, decoder.pending)
    return out
  }

  private fun phoneStream(): ByteArray {
    val out = ByteArrayOutputStream()
    val description = ProfileRegistry.seed20261023!!
    val unit = HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(7))
    RelayWire.write(out, RelayWire.CHALLENGE, 0, RelayWire.challengeBody(nonce(1)))
    RelayWire.write(out, RelayWire.WELCOME, 0, RelayWire.welcomeBody(ByteArray(32) { 9 }, """{"v":1}"""))
    RelayWire.write(out, RelayWire.PARAMETERS, 1, RelayWire.parametersBody(description))
    val header = RelayUnitHeader(5, 1_000, 2_000, 3_000, 7)
    RelayWire.write(out, RelayWire.UNIT, RelayWire.UNIT_KEY, RelayWire.unitHeader(header) + unit.bytes)
    RelayWire.write(out, RelayWire.RESET, 0, """{"why":"newSource"}""".toByteArray())
    RelayWire.write(out, RelayWire.TELEMETRY, 0, """{"t":1}""".toByteArray())
    RelayWire.write(out, RelayWire.PONG, 0, RelayWire.pongBody(1, 2, 3))
    RelayWire.write(out, RelayWire.BYE, 0, """{"why":"stopped"}""".toByteArray())
    return out.toByteArray()
  }

  @Test
  fun everyRecordOfThePhoneRoundTripsWhateverTheSplit() {
    val bytes = phoneStream()
    val whole = decodeAll(bytes, fromPhone = true, step = bytes.size)
    val byteByByte = decodeAll(bytes, fromPhone = true, step = 1)
    val odd = decodeAll(bytes, fromPhone = true, step = 7)
    assertEquals(
      listOf(0x01, 0x02, 0x10, 0x11, 0x12, 0x20, 0x21, 0x22),
      whole.map { it.type },
    )
    for (other in listOf(byteByByte, odd)) {
      assertEquals(whole.size, other.size)
      whole.zip(other).forEach { (a, b) ->
        assertEquals(a.type, b.type)
        assertEquals(a.flags, b.flags)
        assertArrayEquals(a.body, b.body)
      }
    }
    // The blocking reader gives the same records
    val input = DataInputStream(ByteArrayInputStream(bytes))
    whole.forEach { expected ->
      val read = RelayWire.read(input, fromPhone = true)
      assertEquals(expected.type, read.type)
      assertArrayEquals(expected.body, read.body)
    }

    val (version, server) = RelayWire.parseChallenge(whole[0].body)
    assertEquals(1, version)
    assertArrayEquals(nonce(1), server)
    val description = RelayWire.parseParameters(whole[2].body)!!
    assertTrue(description.sameSetsAs(ProfileRegistry.seed20261023))
    assertEquals(DescriptionSource.SESSION, RelayWire.sourceOfParametersFlag(whole[2].flags))
    val header = RelayWire.parseUnitHeader(whole[3].body)
    assertEquals(RelayUnitHeader(5, 1_000, 2_000, 3_000, 7), header)
    val unit = RelayWire.accessUnitOf(whole[3].body, 42)
    assertEquals(listOf(HevcNal.ACCESS_UNIT_DELIMITER, 1, HevcNal.SUFFIX_SEI), unit.nalTypes.toList())
    assertEquals(7, unit.pictureCounter)
    assertEquals(42, unit.lastArrivalNs)
    assertEquals(RelayPong(1, 2, 3), RelayWire.parsePong(whole[6].body))
  }

  @Test
  fun theRecordsOfTheHeadsetRoundTrip() {
    val out = ByteArrayOutputStream()
    RelayWire.write(out, RelayWire.HELLO, 0, RelayWire.helloBody(nonce(2), ByteArray(32) { 3 }, """{"name":"Quest 3"}"""))
    RelayWire.write(out, RelayWire.PING, 0, RelayWire.pingBody(-5, 14_000, 300))
    RelayWire.write(out, RelayWire.HEADSET_BYE, 0, ByteArray(0))
    val records = decodeAll(out.toByteArray(), fromPhone = false, step = 3)
    assertEquals(listOf(0x81, 0x82, 0x83), records.map { it.type })
    val hello = RelayWire.parseHello(records[0].body)
    assertEquals(1, hello.version)
    assertArrayEquals(nonce(2), hello.clientNonce)
    assertEquals("Quest 3", hello.json!!["name"]!!.jsonPrimitive.content)
    assertEquals(RelayPing(-5, 14_000, 300), RelayWire.parsePing(records[1].body))
  }

  @Test
  fun theHeadsetCannotSendWhatThePhoneSendsNorAnythingElse() {
    for (type in listOf(0x00, 0x01, 0x02, 0x10, 0x11, 0x20, 0x84, 0xFF)) {
      expectProtocolError { RelayRecordDecoder(fromPhone = false).offer(RelayWire.header(type, 0, 0)) }
    }
    // Nor the phone what the headset sends
    for (type in listOf(0x81, 0x82, 0x83, 0x13, 0x30)) {
      expectProtocolError { RelayRecordDecoder(fromPhone = true).offer(RelayWire.header(type, 0, 0)) }
    }
  }

  @Test
  fun lengthsOutsideTheirLimitsAreRefusedBeforeTheBodyArrives() {
    // A ping is 16 or 64 bytes, a hello at most 1 KiB, a unit at most 4 MiB plus its longer header, JSON at most 64 KiB
    expectProtocolError { RelayRecordDecoder(false).offer(RelayWire.header(RelayWire.PING, 0, 15)) }
    expectProtocolError { RelayRecordDecoder(false).offer(RelayWire.header(RelayWire.PING, 0, 17)) }
    expectProtocolError { RelayRecordDecoder(false).offer(RelayWire.header(RelayWire.PING, 0, 63)) }
    expectProtocolError { RelayRecordDecoder(false).offer(RelayWire.header(RelayWire.PING, 0, 65)) }
    expectProtocolError { RelayRecordDecoder(false).offer(RelayWire.header(RelayWire.HELLO, 0, 1025)) }
    expectProtocolError { RelayRecordDecoder(false).offer(RelayWire.header(RelayWire.HEADSET_BYE, 0, 1)) }
    expectProtocolError {
      RelayRecordDecoder(true).offer(RelayWire.header(RelayWire.UNIT, 0, 40 + 4 * 1024 * 1024 + 1))
    }
    expectProtocolError { RelayRecordDecoder(true).offer(RelayWire.header(RelayWire.UNIT, 0, 31)) }
    expectProtocolError { RelayRecordDecoder(true).offer(RelayWire.header(RelayWire.TELEMETRY, 0, 64 * 1024 + 1)) }
    expectProtocolError { RelayRecordDecoder(true).offer(RelayWire.header(RelayWire.CHALLENGE, 0, 20)) }
    // A length of four billion is refused from the header alone: nothing is allocated for it
    val huge = RelayWire.header(RelayWire.UNIT, 0, 0)
    RelayWire.putU32(huge, 4, 0xFFFF_FFF0L)
    expectProtocolError { RelayWire.read(DataInputStream(ByteArrayInputStream(huge)), fromPhone = true) }
    // At its limit, a unit is taken, and both lengths of a ping
    RelayWire.check(RelayWire.UNIT, 40L + 4 * 1024 * 1024, fromPhone = true)
    RelayWire.check(RelayWire.PING, 16, fromPhone = false)
    RelayWire.check(RelayWire.PING, 64, fromPhone = false)
  }

  @Test
  fun aTruncatedHeaderWaitsAndATruncatedStreamEndsTheBlockingRead() {
    val decoder = RelayRecordDecoder(fromPhone = true)
    assertTrue(decoder.offer(byteArrayOf(0x20, 0, 0)).isEmpty())
    assertEquals(3, decoder.pending)
    val cut = RelayWire.record(RelayWire.TELEMETRY, 0, "{}".toByteArray()).copyOf(9)
    try {
      RelayWire.read(DataInputStream(ByteArrayInputStream(cut)), fromPhone = true)
      fail("a record cut short must not read")
    } catch (_: java.io.EOFException) {
    }
  }

  @Test
  fun theProofsMatchTheVectorsOfThePythonGenerator() {
    val text = javaClass.classLoader!!.getResource("djilink/relay-vectors.json")!!.readText()
    val root = Json.parseToJsonElement(text).jsonObject
    assertEquals(RelayWire.LABEL, root["label"]!!.jsonPrimitive.content)
    val vectors = root["vectors"]!!.jsonArray
    assertEquals(5, vectors.size)
    for (vector in vectors) {
      val entry = vector.jsonObject
      val code = entry["code"]!!.jsonPrimitive.content
      val server = StreamDescription.hexBytes(entry["serverNonce"]!!.jsonPrimitive.content)!!
      val client = StreamDescription.hexBytes(entry["clientNonce"]!!.jsonPrimitive.content)!!
      assertEquals(code, RelayWire.normalizeCode(code))
      assertEquals(
        entry["headsetProof"]!!.jsonPrimitive.content,
        StreamDescription.hex(RelayWire.proof(code, RelayWire.ROLE_HEADSET, server, client)),
      )
      assertEquals(
        entry["phoneProof"]!!.jsonPrimitive.content,
        StreamDescription.hex(RelayWire.proof(code, RelayWire.ROLE_PHONE, server, client)),
      )
    }
  }

  @Test
  fun theTwoProofsDifferAndAWrongCodeNeverMatches() {
    val server = nonce(3)
    val client = nonce(4)
    val headset = RelayWire.proof("K7M2Q9XRTH", RelayWire.ROLE_HEADSET, server, client)
    val phone = RelayWire.proof("K7M2Q9XRTH", RelayWire.ROLE_PHONE, server, client)
    assertFalse(headset.contentEquals(phone))
    assertTrue(RelayWire.proofMatches(headset, RelayWire.proof("K7M2Q9XRTH", 1, server, client)))
    assertFalse(RelayWire.proofMatches(headset, RelayWire.proof("K7M2Q9XRTJ", 1, server, client)))
    assertFalse(RelayWire.proofMatches(headset, RelayWire.proof("K7M2Q9XRTH", 1, client, server)))
  }

  @Test
  fun codesAreNormalisedAsOnThePairingPage() {
    assertEquals("K7M2Q9XRTH", RelayWire.normalizeCode("k7m2q 9xrth"))
    assertEquals("K7M2Q9XRTH", RelayWire.normalizeCode("K7M2Q-9XRTH"))
    // O, 0, I, 1 and L are refused rather than guessed
    for (typed in listOf("K7M2Q9XRT0", "K7M2Q9XRTO", "K7M2Q9XRTI", "K7M2Q9XRT1", "K7M2Q9XRTL", "K7M2Q9XRT", "")) {
      assertNull(typed, RelayWire.normalizeCode(typed))
    }
  }

  @Test
  fun onlyTheLocalNetworkIsAccepted() {
    for (host in listOf("127.0.0.1", "10.0.2.2", "172.16.0.1", "172.31.255.255", "192.168.1.23", "169.254.3.4")) {
      assertTrue(host, RelayWire.isLocalNetworkAddress(InetAddress.getByName(host)))
      assertTrue(host, RelayWire.isLocalIPv4Literal(host))
    }
    for (host in listOf("8.8.8.8", "172.32.0.1", "100.64.0.1", "192.169.0.1", "1.1.1.1")) {
      assertFalse(host, RelayWire.isLocalNetworkAddress(InetAddress.getByName(host)))
      assertFalse(host, RelayWire.isLocalIPv4Literal(host))
    }
    for (host in listOf("192.168.1.023", "192.168.1", "phone.local", "::1", "192.168.1.256")) {
      assertFalse(host, RelayWire.isLocalIPv4Literal(host))
    }
    assertFalse(RelayWire.isLocalNetworkAddress(InetAddress.getByName("::1")))
    for (name in listOf("rmnet_data0", "ccmni1", "tun0", "wg0", "v4-rmnet", "clat4", "ppp0")) {
      assertTrue(name, RelayWire.isSkippedInterface(name))
    }
    for (name in listOf("wlan0", "swlan0", "ap0", "eth0", "lo")) {
      assertFalse(name, RelayWire.isSkippedInterface(name))
    }
  }

  @Test
  fun theParametersOfAMissingSetOrAnSpsThatDoesNotParseAreRefused() {
    assertNull(RelayWire.parseParameters(HevcSamples.annexB(HevcSamples.VPS, HevcSamples.SPS)))
    assertNull(RelayWire.parseParameters(ByteArray(0)))
    assertNotNull(RelayWire.parseParameters(HevcSamples.annexB(HevcSamples.VPS, HevcSamples.SPS, HevcSamples.PPS)))
  }

  private fun expectProtocolError(block: () -> Unit) {
    try {
      block()
      fail("a protocol error was expected")
    } catch (_: RelayProtocolException) {
    }
  }
}
