package app.alextran.immich.djilink

import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The streaming envelope decoder: fragmentation, several frames in one read, noise, and what it counts */
class EnvelopeTest {
  private var now = 0L
  private val decoder = EnvelopeDecoder(clockMs = { now })

  private fun frame(channel: Int, payload: ByteArray) = EnvelopeDecoder.encode(channel, payload)

  @Test
  fun oneFrameInOneRead() {
    val frames = decoder.offer(frame(Channels.CONTROL_PRIMARY, byteArrayOf(1, 2, 3)))
    assertEquals(1, frames.size)
    assertEquals(Channels.CONTROL_PRIMARY, frames[0].channel)
    assertTrue(byteArrayOf(1, 2, 3).contentEquals(frames[0].payload))
    assertEquals(1L, decoder.counters.frames)
    assertEquals(0L, decoder.counters.discardedBytes)
  }

  @Test
  fun aFrameSplitOneByteAtATime() {
    val bytes = frame(22346, ByteArray(40) { it.toByte() })
    val seen = mutableListOf<EnvelopeFrame>()
    for (byte in bytes) {
      seen.addAll(decoder.offer(byteArrayOf(byte)))
    }
    assertEquals(1, seen.size)
    assertEquals(40, seen[0].payload.size)
  }

  @Test
  fun severalFramesInOneRead() {
    val together = frame(Channels.CONTROL_PRIMARY, byteArrayOf(9)) +
      frame(22346, byteArrayOf(1, 2)) +
      frame(Channels.CONTROL_ALTERNATE, ByteArray(0))
    val frames = decoder.offer(together)
    assertEquals(3, frames.size)
    assertEquals(0, frames[2].payload.size)
  }

  @Test
  fun theSyncPatternInsideAPayloadIsNotASync() {
    val payload = byteArrayOf(0x55, 0xCC.toByte(), 0x49, 0x57, 0x02, 0x00, 0x00, 0x00, 0x11, 0x22)
    val frames = decoder.offer(frame(Channels.CONTROL_PRIMARY, payload))
    assertEquals(1, frames.size)
    assertEquals(payload.size, frames[0].payload.size)
    assertEquals(0L, decoder.counters.resynchronisations)
  }

  @Test
  fun noiseBeforeAFrameIsCountedAsOneResynchronisation() {
    val frames = decoder.offer(byteArrayOf(1, 2, 3, 4) + frame(Channels.CONTROL_PRIMARY, byteArrayOf(7)))
    assertEquals(1, frames.size)
    assertEquals(4L, decoder.counters.discardedBytes)
    assertEquals(1L, decoder.counters.resynchronisations)
  }

  @Test
  fun aLengthAboveTheCeilingIsRejectedAndTheStreamRecovers() {
    val bogus = byteArrayOf(0x55, 0xCC.toByte(), 0x49, 0x57, 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0x7F)
    val frames = decoder.offer(bogus + frame(Channels.CONTROL_PRIMARY, byteArrayOf(5)))
    assertEquals(1, frames.size)
    assertEquals(1L, decoder.counters.oversizeRejections)
  }

  @Test
  fun anUnknownChannelIsCountedAndKept() {
    val frames = decoder.offer(frame(40000, byteArrayOf(1)))
    assertEquals(1, frames.size)
    assertEquals(40000, frames[0].channel)
    assertEquals(1L, decoder.counters.unknownChannelFrames)
  }

  @Test
  fun anIncompleteFrameIsHeldThenCompleted() {
    val bytes = frame(Channels.CONTROL_PRIMARY, ByteArray(100) { 7 })
    assertEquals(0, decoder.offer(bytes, 0, 50).size)
    now += 500
    val frames = decoder.offer(bytes, 50, bytes.size - 50)
    assertEquals(1, frames.size)
    assertEquals(0L, decoder.counters.incompleteTimeouts)
  }

  @Test
  fun anIncompleteFrameIsGivenUpOnAfterTheBoundedWait() {
    val bytes = frame(Channels.CONTROL_PRIMARY, ByteArray(100) { 7 })
    assertEquals(0, decoder.offer(bytes, 0, 20).size)
    now += EnvelopeDecoder.INCOMPLETE_TIMEOUT_MS + 1
    assertEquals(0, decoder.pump().size)
    assertEquals(1L, decoder.counters.incompleteTimeouts)
  }

  @Test
  fun randomChunksOfALongSessionGiveTheSameFrames() {
    val random = Random(7)
    val session = (0 until 60).fold(ByteArray(0)) { all, index ->
      all + frame(if (index % 2 == 0) Channels.CONTROL_PRIMARY else 22346, ByteArray(index) { it.toByte() })
    }
    var at = 0
    var count = 0
    while (at < session.size) {
      val length = minOf(1 + random.nextInt(97), session.size - at)
      count += decoder.offer(session, at, length).size
      at += length
    }
    assertEquals(60, count)
    assertEquals(60L, decoder.counters.frames)
    assertEquals(0L, decoder.counters.discardedBytes)
  }

  @Test
  fun aReconnectNeverKeepsTheBuffer() {
    val bytes = frame(Channels.CONTROL_PRIMARY, ByteArray(100) { 7 })
    decoder.offer(bytes, 0, 50)
    decoder.reset()
    assertEquals(0, decoder.buffered)
    assertEquals(1, decoder.offer(frame(Channels.CONTROL_PRIMARY, byteArrayOf(3))).size)
  }
}
