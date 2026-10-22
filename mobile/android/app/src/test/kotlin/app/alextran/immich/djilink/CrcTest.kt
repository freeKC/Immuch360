package app.alextran.immich.djilink

import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The five published checksum vectors of the format notes (p2/protocol.md, section 4.3). They are the reason the
 * parameters are treated as established for this product family, and they are a test from the first day so that a
 * frame that fails on hardware accuses the frame and not the arithmetic.
 */
class CrcTest {
  private val header = Crc(CrcSets.HEADER_CRC8)
  private val frame = Crc(CrcSets.FRAME_CRC16)

  private fun bytes(hex: String): ByteArray =
    hex.split(" ").filter { it.isNotBlank() }.map { it.toInt(16).toByte() }.toByteArray()

  @Test
  fun headerChecksumOfTheTwoPublishedHeaders() {
    assertEquals(0x66, header.compute(bytes("55 0E 04")))
    assertEquals(0x92, header.compute(bytes("55 11 04")))
  }

  @Test
  fun headerChecksumVerifiesOverItsOwnStoredValue() {
    assertTrue(header.verify(bytes("55 11 04 92")))
    assertFalse(header.verify(bytes("55 11 04 93")))
  }

  @Test
  fun frameChecksumOfThePublishedFrame() {
    val published = bytes("55 11 04 92 0A 03 40 61 40 03 DF 01 00 00 00")
    assertEquals(0xBB18, frame.compute(published))
    assertTrue(frame.verify(bytes("55 11 04 92 0A 03 40 61 40 03 DF 01 00 00 00 18 BB")))
  }

  @Test
  fun buildThenVerifyHoldsForRandomFrames() {
    val random = Random(20261022)
    repeat(200) {
      val body = ByteArray(random.nextInt(64)).also { random.nextBytes(it) }
      val built = P3Decoder.build(
        senderType = DeviceTypes.APPLICATION,
        receiverType = DeviceTypes.FLIGHT_CONTROLLER,
        sequence = random.nextInt(32768),
        commandSet = CommandSets.FLIGHT_CONTROLLER,
        commandId = random.nextInt(256),
        body = body,
      )
      assertTrue(header.verify(built, 0, 4))
      assertTrue(frame.verify(built, 0, built.size))
    }
  }

  @Test
  fun anotherParameterSetDoesNotVerifyTheSameFrame() {
    // A published study of another DJI product family reports the same polynomials with other seeds: a parameter set
    // is per family, which is why it is a parameter here and not a constant in the code
    val other = Crc(CrcParams(label = "crc16-r8408-0000", width = 16, polynomial = 0x8408, initial = 0x0000))
    assertFalse(other.verify(bytes("55 11 04 92 0A 03 40 61 40 03 DF 01 00 00 00 18 BB")))
  }
}
