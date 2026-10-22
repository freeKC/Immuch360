package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The capture ring, its index, and a capture replayed through the same codecs */
class CaptureTest {
  private var monotonic = 0L
  private var wall = 1_700_000_000_000L

  private fun ring(capacity: Int = CaptureRing.MIN_CAPACITY) = CaptureRing(
    capacityBytes = capacity,
    monotonicNs = { monotonic += 1_000_000; monotonic },
    wallMs = { wall += 1; wall },
  ).also { it.start() }

  @Test
  fun recordsNothingWhileItIsNotRecording() {
    val capture = CaptureRing(capacityBytes = CaptureRing.MIN_CAPACITY)
    capture.record(CaptureDirection.IN, byteArrayOf(1, 2, 3))
    assertEquals(0L, capture.totalBytes)
  }

  @Test
  fun theBytesAndTheIndexDescribeTheSameWindow() {
    val capture = ring()
    capture.record(CaptureDirection.IN, byteArrayOf(1, 2, 3))
    capture.record(CaptureDirection.OUT, byteArrayOf(9))
    val snapshot = capture.snapshot()
    assertEquals(4, snapshot.bytes.size)
    assertEquals(2, snapshot.entries.size)
    assertEquals(0L, snapshot.entries[0].offset)
    assertEquals(3L, snapshot.entries[1].offset)
    assertEquals(CaptureDirection.OUT, snapshot.entries[1].direction)
    assertTrue(snapshot.indexCsv().startsWith("offset,length,direction,monotonic_ns,wall_ms"))
    assertEquals(64, snapshot.sha256().length)
  }

  @Test
  fun theRingWrapsAndTheOldestRecordsLeaveTheIndex() {
    val capture = ring(CaptureRing.MIN_CAPACITY)
    val block = ByteArray(CaptureRing.MIN_CAPACITY / 4) { 7 }
    repeat(6) { capture.record(CaptureDirection.IN, block) }
    val snapshot = capture.snapshot()
    assertEquals(CaptureRing.MIN_CAPACITY, snapshot.bytes.size)
    assertEquals(6L * block.size, snapshot.totalBytes)
    assertTrue(snapshot.droppedBytes > 0)
    assertEquals(0L, snapshot.entries.first().offset)
    assertEquals(CaptureRing.MIN_CAPACITY.toLong(), snapshot.entries.sumOf { it.length.toLong() })
  }

  @Test
  fun aCaptureReplaysToTheSameFramesAsTheLivePath() {
    val capture = ring()
    val session = listOf(
      EnvelopeDecoder.encode(
        Channels.CONTROL_PRIMARY,
        P3Decoder.build(
          senderType = DeviceTypes.FLIGHT_CONTROLLER,
          receiverType = DeviceTypes.APPLICATION,
          sequence = 4,
          commandSet = CommandSets.FLIGHT_CONTROLLER,
          commandId = 67,
          body = ByteArray(8) { it.toByte() },
        ),
      ),
      EnvelopeDecoder.encode(22346, byteArrayOf(0, 0, 0, 1, 0x65, 9, 9)),
    )
    // The probe byte of the transport is in the capture too, and the replay must not read it as inbound
    capture.record(CaptureDirection.IN, session[0])
    capture.record(CaptureDirection.OUT, ByteArray(1))
    capture.record(CaptureDirection.IN, session[1])
    val snapshot = capture.snapshot()

    val index = CaptureReplay.parseIndex(snapshot.indexCsv())
    assertEquals(3, index.size)
    val result = CaptureReplay.replay(snapshot.bytes, index)
    assertTrue(result.usedIndex)
    assertEquals(2, result.readsReplayed)
    assertEquals(2L, result.envelopes.frames)
    assertEquals(1L, result.control.frames)
    assertEquals(0L, result.envelopes.discardedBytes)
    assertEquals(1, result.telemetry.size)
    assertEquals(67, result.telemetry[0].commandId)
    assertEquals(ProbeVerdict.START_CODES_SEEN, result.probe.verdict)
  }

  @Test
  fun aCaptureWithNoIndexIsReadAsOneInboundStream() {
    val bytes = EnvelopeDecoder.encode(Channels.CONTROL_PRIMARY, ByteArray(4))
    val result = CaptureReplay.replay(bytes, emptyList())
    assertEquals(1L, result.envelopes.frames)
    assertEquals(false, result.usedIndex)
  }
}
