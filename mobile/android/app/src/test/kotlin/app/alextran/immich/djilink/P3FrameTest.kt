package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The control frame: the ten bit length, both checksums, the resynchronisation rules and the sequence counter */
class P3FrameTest {
  private val decoder = P3Decoder()

  @Test
  fun buildThenParseRoundTrip() {
    val built = P3Decoder.build(
      senderType = DeviceTypes.APPLICATION,
      receiverType = DeviceTypes.OFDM_RADIO,
      receiverIndex = 3,
      sequence = 1234,
      ackPolicy = 2,
      commandSet = CommandSets.SPECIAL,
      commandId = 2,
      body = ByteArray(13) { it.toByte() },
    )
    val frames = decoder.offer(built)
    assertEquals(1, frames.size)
    val frame = frames[0]
    assertEquals(P3Decoder.DEFAULT_VERSION, frame.version)
    assertEquals(DeviceTypes.APPLICATION, frame.senderType)
    assertEquals(DeviceTypes.OFDM_RADIO, frame.receiverType)
    assertEquals(3, frame.receiverIndex)
    assertEquals(1234, frame.sequence)
    assertEquals(2, frame.ackPolicy)
    assertFalse(frame.isAcknowledgement)
    assertEquals(CommandSets.SPECIAL, frame.commandSet)
    assertEquals(2, frame.commandId)
    assertEquals(13, frame.body.size)
    assertFalse(frame.encryptionUnsupported)
  }

  @Test
  fun theSmallestFrameIsThirteenBytesAndHasNoBody() {
    val built = P3Decoder.build(
      senderType = DeviceTypes.REMOTE_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 1,
      commandSet = CommandSets.COMMON,
      commandId = 1,
    )
    assertEquals(P3Decoder.MIN_SIZE, built.size)
    assertEquals(0, decoder.offer(built)[0].body.size)
  }

  @Test
  fun theLargestFrameIsTheTenBitLength() {
    val body = ByteArray(P3Decoder.MAX_SIZE - P3Decoder.MIN_SIZE)
    val built = P3Decoder.build(
      senderType = DeviceTypes.CAMERA,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 5,
      commandSet = CommandSets.CAMERA,
      commandId = 7,
      body = body,
    )
    assertEquals(P3Decoder.MAX_SIZE, built.size)
    assertEquals(1, decoder.offer(built).size)
  }

  @Test
  fun aHeaderChecksumFailureAdvancesOneByte() {
    val built = P3Decoder.build(
      senderType = DeviceTypes.FLIGHT_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 2,
      commandSet = CommandSets.FLIGHT_CONTROLLER,
      commandId = 67,
      body = byteArrayOf(1, 2, 3),
    )
    val broken = built.copyOf()
    broken[3] = (broken[3] + 1).toByte()
    assertEquals(0, decoder.offer(broken).size)
    assertEquals(1L, decoder.counters.headerCrcFailures)
    // The good frame that follows still parses, which is what advancing one byte is for
    assertEquals(1, decoder.offer(built).size)
  }

  @Test
  fun aFrameChecksumFailureAdvancesFourBytes() {
    val built = P3Decoder.build(
      senderType = DeviceTypes.FLIGHT_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 3,
      commandSet = CommandSets.FLIGHT_CONTROLLER,
      commandId = 68,
      body = byteArrayOf(4, 5, 6),
    )
    val broken = built.copyOf()
    broken[broken.size - 1] = (broken[broken.size - 1] + 1).toByte()
    assertEquals(0, decoder.offer(broken).size)
    assertEquals(1L, decoder.counters.frameCrcFailures)
    // Four bytes at least: past the magic and the header the decoder had already read. What follows those four is
    // the rest of a frame that is not one, so the usual one byte search goes on through it
    assertTrue(decoder.counters.discardedBytes >= 4)
    assertEquals(1L, decoder.counters.resynchronisations)
    // And the good frame that comes next parses, which is what resynchronising is for
    assertEquals(1, decoder.offer(built).size)
  }

  @Test
  fun aLengthBelowTheMinimumIsRejected() {
    // A header whose length field says four bytes cannot be a frame; its checksum is built so that only the length
    // is wrong, which is the case the notes ask for
    val header = byteArrayOf(0x55, 0x04, 0x04, 0)
    header[3] = Crc(CrcSets.HEADER_CRC8).compute(header, 0, 3).toByte()
    val filler = ByteArray(12)
    assertEquals(0, decoder.offer(header + filler).size)
    assertEquals(1L, decoder.counters.lengthRejections)
  }

  @Test
  fun anEncryptedFrameIsCountedAsUnsupportedAndNeverGuessedAt() {
    val built = P3Decoder.build(
      senderType = DeviceTypes.FLIGHT_CONTROLLER,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 9,
      encryption = 3,
      commandSet = CommandSets.FLIGHT_CONTROLLER,
      commandId = 67,
      body = byteArrayOf(1, 2, 3, 4),
    )
    val frames = decoder.offer(built)
    assertEquals(1, frames.size)
    assertTrue(frames[0].encryptionUnsupported)
    assertEquals(1L, decoder.counters.unsupportedEncryption)
  }

  @Test
  fun aFrameStraddlingTwoReadsParsesOnce() {
    val built = P3Decoder.build(
      senderType = DeviceTypes.BATTERY,
      receiverType = DeviceTypes.APPLICATION,
      sequence = 11,
      commandSet = CommandSets.SMART_BATTERY,
      commandId = 2,
      body = ByteArray(30) { it.toByte() },
    )
    assertEquals(0, decoder.offer(built, 0, 10).size)
    assertEquals(1, decoder.offer(built, 10, built.size - 10).size)
  }

  @Test
  fun theSequenceCounterSkipsTheMagicAndWraps() {
    val counter = SequenceCounter(83)
    assertEquals(84, counter.next())
    assertEquals(86, counter.next())
    val high = SequenceCounter(SequenceCounter.WRAP - 1)
    assertEquals(0, high.next())
  }
}
