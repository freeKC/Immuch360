package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The control frames of a whole session, beside the capture (p2/telemetry-deep-dive-2026-10-24.md, section 8): the 24
 * October flight was pushed out of a 16 MiB tail by the video, while its control frames alone fit many times over.
 */
class ControlCaptureTest {
  @Test
  fun aWholeBatteryOfControlFramesFits() {
    // 19.5 kB/s in flight, 11.5 kB/s on the ground: 25 minutes of flight is under the ring
    assertTrue(19_500L * 25 * 60 < DjiLinkController.CONTROL_CAPTURE_BYTES)
    assertTrue(DjiLinkController.CONTROL_CAPTURE_BYTES <= CaptureRing.MAX_CAPACITY)
  }

  @Test
  fun everyControlEnvelopeOfASessionLongerThanTheVideoTailIsKept() {
    var nowNs = 0L
    val video = CaptureRing(capacityBytes = 64 * 1024, headBytes = 8 * 1024, monotonicNs = { nowNs })
    val control = CaptureRing(capacityBytes = 512 * 1024, headBytes = 0, monotonicNs = { nowNs })
    video.start(accessoryOpen = true)
    control.start(accessoryOpen = true)
    control.mark(CaptureDirection.OPEN)
    for (index in 0 until 300) {
      nowNs += 100_000_000
      // A picture's worth of video, and one control envelope unpadded, as the reader thread records them
      video.record(CaptureDirection.IN, ByteArray(5_000))
      val envelope = EnvelopeDecoder.encode(Channels.CONTROL_PRIMARY, ByteArray(120) { index.toByte() })
      control.record(CaptureDirection.IN, envelope)
    }
    // The video tail kept the last seconds only, with a gap after its head
    assertTrue(video.snapshot().entries.any { it.direction == CaptureDirection.GAP })
    val kept = control.snapshot()
    assertFalse(kept.entries.any { it.direction == CaptureDirection.GAP })
    assertEquals(300, kept.entries.count { it.direction == CaptureDirection.IN })
    // Back through the envelope decoder, unpadded envelopes one after the other: every one of them, in order
    val frames = EnvelopeDecoder().offer(kept.bytes)
    assertEquals(300, frames.size)
    assertEquals(299.toByte(), frames.last().payload[0])
    assertTrue(frames.all { it.channel == Channels.CONTROL_PRIMARY })
  }
}
