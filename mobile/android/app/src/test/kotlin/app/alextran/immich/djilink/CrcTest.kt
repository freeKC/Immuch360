package app.alextran.immich.djilink

import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The five published checksum vectors of the format notes (p2/protocol.md, section 4.3). They are the reason the
 * parameters are the first candidate for this product family, and they are a test from the first day so that a frame
 * that fails on hardware accuses the frame and not the arithmetic. Then the seed that a failing frame votes for, which
 * is how a capture shows a family whose seeds differ.
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

  @Test
  fun theSeedOfThePublishedVectorsComesBackOut() {
    assertEquals(0x77, header.seedFor(bytes("55 11 04 92")))
    assertEquals(0x77, header.seedFor(bytes("55 0E 04 66")))
    assertEquals(0x3692, frame.seedFor(bytes("55 11 04 92 0A 03 40 61 40 03 DF 01 00 00 00 18 BB")))
  }

  @Test
  fun anySeedComesBackOutOfABuiltFrame() {
    val random = Random(14)
    repeat(300) {
      val headerSeed = random.nextInt(0x100)
      val frameSeed = random.nextInt(0x10000)
      val built = P3Decoder.build(
        senderType = DeviceTypes.REMOTE_CONTROLLER,
        receiverType = DeviceTypes.APPLICATION,
        sequence = random.nextInt(32768),
        commandSet = random.nextInt(256),
        commandId = random.nextInt(256),
        body = ByteArray(random.nextInt(40)).also { random.nextBytes(it) },
        headerParams = CrcSets.header(headerSeed),
        frameParams = CrcSets.frame(frameSeed),
      )
      // Whatever parameter set runs it backwards, the seed is a property of the bytes and the polynomial
      assertEquals(headerSeed, header.seedFor(built, 0, 4))
      assertEquals(frameSeed, frame.seedFor(built, 0, built.size))
    }
  }

  @Test
  fun aTallyKeepsItsBoundAndNamesTheMostVotedSeed() {
    val tally = SeedTally(maxValues = 3)
    listOf(5, 5, 7, 9, 5, 11, 12).forEach { tally.vote(it) }
    tally.vote(null)
    assertEquals(5 to 3L, tally.top())
    assertEquals(7L, tally.total)
    assertEquals(2L, tally.others)
    val sum = SeedTally(maxValues = 3).also { it.vote(7) }
    sum.add(tally)
    assertEquals(5 to 3L, sum.top())
    assertEquals(8L, sum.total)
  }

  @Test
  fun aDecoderWithOtherSeedsReadsFramesBuiltWithThem() {
    val headerParams = CrcSets.header(0x3C)
    val frameParams = CrcSets.frame(0x1234)
    val built = P3Decoder.build(
      senderType = DeviceTypes.REMOTE_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 3,
      commandSet = 6,
      commandId = 9,
      body = byteArrayOf(1, 2, 3),
      headerParams = headerParams,
      frameParams = frameParams,
    )
    val documented = P3Decoder()
    assertEquals(0, documented.offer(built).size)
    assertEquals(1L, documented.counters.headerCrcFailures)
    assertEquals(0x3C to 1L, documented.headerSeeds.top())

    val matching = P3Decoder(headerParams, frameParams)
    val frames = matching.offer(built)
    assertEquals(1, frames.size)
    assertEquals(9, frames[0].commandId)
  }

  @Test
  fun aFrameWhoseHeaderVerifiesVotesForTheFrameSeed() {
    val built = P3Decoder.build(
      senderType = DeviceTypes.REMOTE_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 3,
      commandSet = 6,
      commandId = 9,
      body = byteArrayOf(1, 2, 3),
      frameParams = CrcSets.frame(0xBEEF),
    )
    val decoder = P3Decoder()
    assertEquals(0, decoder.offer(built).size)
    assertEquals(1L, decoder.counters.frameCrcFailures)
    assertEquals(0xBEEF to 1L, decoder.frameSeeds.top())
  }
}
