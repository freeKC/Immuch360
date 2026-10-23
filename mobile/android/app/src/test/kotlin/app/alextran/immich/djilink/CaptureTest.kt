package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The capture ring, its index, and a capture replayed through the same codecs */
class CaptureTest {
  private var monotonic = 0L
  private var wall = 1_700_000_000_000L

  private fun ring(capacity: Int = CaptureRing.MIN_CAPACITY) = CaptureRing(
    capacityBytes = capacity,
    headBytes = 0,
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
  fun theRingIsAllocatedByTheFirstStartAndFreedByAClearAtRest() {
    val capture = CaptureRing(capacityBytes = CaptureRing.MIN_CAPACITY)
    assertFalse(capture.allocated)
    assertEquals(0, capture.snapshot().bytes.size)
    capture.start()
    assertTrue(capture.allocated)
    capture.record(CaptureDirection.IN, byteArrayOf(1))
    capture.stop()
    assertTrue("a stopped capture keeps its bytes for the export", capture.allocated)
    assertEquals(1, capture.snapshot().bytes.size)
    capture.clear()
    assertFalse(capture.allocated)
  }

  @Test
  fun opensAndClosesAreMarkersInTheIndex() {
    val capture = ring()
    capture.mark(CaptureDirection.OPEN)
    capture.record(CaptureDirection.IN, byteArrayOf(1, 2))
    capture.mark(CaptureDirection.CLOSE)
    capture.mark(CaptureDirection.OPEN)
    capture.record(CaptureDirection.IN, byteArrayOf(3))
    val snapshot = capture.snapshot()
    assertEquals(3, snapshot.bytes.size)
    assertEquals(
      listOf("open", "in", "close", "open", "in"),
      snapshot.entries.map { it.direction.word },
    )
    assertEquals(2L, snapshot.entries[2].offset)
    assertEquals(0, snapshot.entries[2].length)
    val csv = snapshot.indexCsv()
    assertTrue(csv.contains(",open,"))
    assertTrue(csv.contains(",close,"))
    assertEquals(snapshot.entries, CaptureReplay.parseIndex(csv))
  }

  @Test
  fun aReplayRestartsTheParsersAtEachOpen() {
    val capture = ring()
    val frame = EnvelopeDecoder.encode(
      Channels.CONTROL_PRIMARY,
      P3Decoder.build(
        senderType = DeviceTypes.REMOTE_CONTROLLER,
        receiverType = DeviceTypes.APPLICATION,
        sequence = 1,
        commandSet = CommandSets.REMOTE_CONTROLLER,
        commandId = 5,
        body = ByteArray(6),
      ),
    )
    // The first session ends in the middle of a frame; the second starts with a whole one
    capture.mark(CaptureDirection.OPEN)
    capture.record(CaptureDirection.IN, frame, 0, frame.size - 5)
    capture.mark(CaptureDirection.CLOSE)
    capture.mark(CaptureDirection.OPEN)
    capture.record(CaptureDirection.IN, frame)
    val snapshot = capture.snapshot()
    val result = CaptureReplay.replay(snapshot.bytes, CaptureReplay.parseIndex(snapshot.indexCsv()))
    assertEquals(2, result.opens)
    assertEquals(1L, result.envelopes.frames)
    assertEquals(1L, result.control.frames)
    assertEquals(0L, result.envelopes.unknownChannelFrames)
  }

  @Test
  fun aCaptureWithNoIndexIsReadAsOneInboundStream() {
    val bytes = EnvelopeDecoder.encode(Channels.CONTROL_PRIMARY, ByteArray(4))
    val result = CaptureReplay.replay(bytes, emptyList())
    assertEquals(1L, result.envelopes.frames)
    assertEquals(false, result.usedIndex)
  }

  @Test
  fun theHeadKeepsTheFirstBytesOfASessionAndAGapMarkerSaysWhatTheTailLost() {
    val capture = CaptureRing(
      capacityBytes = CaptureRing.MIN_CAPACITY,
      headBytes = 1000,
      monotonicNs = { monotonic += 1_000_000; monotonic },
      wallMs = { wall += 1; wall },
    )
    capture.start(accessoryOpen = false)
    capture.mark(CaptureDirection.OPEN)
    capture.record(CaptureDirection.IN, ByteArray(600) { 1 })
    // Does not fit what is left of the head: the head closes, this and the rest of the session go to the tail
    capture.record(CaptureDirection.IN, ByteArray(600) { 2 })
    repeat(8) { capture.record(CaptureDirection.IN, ByteArray(16 * 1024) { 3 }) }
    val snapshot = capture.snapshot()
    assertEquals(600 + CaptureRing.MIN_CAPACITY, snapshot.bytes.size)
    assertEquals(1.toByte(), snapshot.bytes[599])
    assertEquals(3.toByte(), snapshot.bytes[600])
    assertEquals(listOf("open", "in", "gap"), snapshot.entries.take(3).map { it.direction.word })
    val gap = snapshot.entries[2]
    assertEquals(600L, gap.offset)
    val tailWritten = 600L + 8 * 16 * 1024
    assertEquals(tailWritten - CaptureRing.MIN_CAPACITY, gap.skippedBytes)
    assertEquals(600L + 600 + 8 * 16 * 1024, snapshot.totalBytes)
    val csv = snapshot.indexCsv()
    assertTrue(csv.contains("600,${gap.skippedBytes},gap,"))
    val parsed = CaptureReplay.parseIndex(csv)
    assertEquals(snapshot.entries, parsed)
    // Every record of the tail is rebased after the head
    assertTrue(snapshot.entries.drop(3).all { it.offset >= 600 })
  }

  @Test
  fun anAccessoryAlreadyOpenStartsTheHeadAtOnce() {
    val capture = CaptureRing(capacityBytes = CaptureRing.MIN_CAPACITY, headBytes = 100)
    capture.start(accessoryOpen = true)
    capture.record(CaptureDirection.IN, ByteArray(80) { 5 })
    capture.record(CaptureDirection.IN, ByteArray(80) { 6 })
    val snapshot = capture.snapshot()
    // Nothing was lost, so head and tail follow each other with no gap marker
    assertEquals(160, snapshot.bytes.size)
    assertEquals(listOf(0L, 80L), snapshot.entries.map { it.offset })
    assertEquals(CaptureRing.DEFAULT_HEAD, CaptureRing().capacityOfHead)
    assertEquals(16 * 1024 * 1024, CaptureRing().capacityOfRing)
  }

  @Test
  fun aReplayRestartsItsParsersAtTheGap() {
    val capture = CaptureRing(
      capacityBytes = CaptureRing.MIN_CAPACITY,
      headBytes = 1000,
      monotonicNs = { monotonic += 1_000_000; monotonic },
      wallMs = { wall += 1; wall },
    )
    capture.start(accessoryOpen = false)
    capture.mark(CaptureDirection.OPEN)
    fun control(sequence: Int, body: Int) = EnvelopeDecoder.encode(
      Channels.CONTROL_PRIMARY,
      P3Decoder.build(
        senderType = DeviceTypes.REMOTE_CONTROLLER,
        receiverType = DeviceTypes.APPLICATION,
        sequence = sequence,
        commandSet = 0,
        commandId = 119,
        body = ByteArray(body),
      ),
    )
    capture.record(CaptureDirection.IN, control(1, 4))
    // The head ends inside a frame: without a restart its header would swallow the bytes after the gap
    capture.record(CaptureDirection.IN, control(2, 100).copyOf(20))
    repeat(31) { index ->
      capture.record(CaptureDirection.IN, EnvelopeDecoder.encode(22346, ByteArray(4080) { (index + 7).toByte() }))
    }
    val snapshot = capture.snapshot()
    val result = CaptureReplay.replay(snapshot.bytes, CaptureReplay.parseIndex(snapshot.indexCsv()))
    assertEquals(1, result.gaps)
    assertEquals(1, result.opens)
    assertEquals(1L, result.control.frames)
    assertTrue(result.envelopes.frames >= 15)
    assertEquals(0L, result.envelopes.unknownChannelFrames)
  }

  @Test
  fun theSessionLogKeepsTheLastAccessoryAndEveryOpenAfterAClose() {
    val log = SessionLog()
    val identity = AccessoryIdentity("DJI", "model", "remote", "1.0", "serial", null)
    log.onIdentity(identity, 900)
    log.onOpened(1000)
    log.onRead(100, 1050)
    log.onRead(50, 1060)
    log.onWritten(1)
    log.onClosed("DETACHED", 2000)
    log.onIdentity(null, 2001)
    log.onOpened(5000)
    assertEquals(identity, log.lastAccessory)
    assertEquals(900L, log.lastAccessoryAtWallMs)
    val opens = log.opens()
    assertEquals(2, opens.size)
    val first = opens[0]
    assertEquals(50L, first.firstByteAfterMs)
    assertEquals(150L, first.bytesRead)
    assertEquals(2L, first.reads)
    assertEquals(1L, first.bytesWritten)
    assertEquals(2000L, first.closedAtWallMs)
    assertEquals("DETACHED", first.closeReason)
    assertEquals(null, opens[1].firstByteAfterMs)
    repeat(30) { log.onOpened(6000L + it) }
    assertEquals(SessionLog.MAX_OPENS, log.opens().size)
  }
}
