package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the probe says, and what it refuses to say */
class VideoProbeTest {
  @Test
  fun noPayloadIsItsOwnAnswer() {
    assertEquals(ProbeVerdict.NO_DATA, VideoProbe().report().verdict)
  }

  @Test
  fun payloadsWithoutStartCodesAreNotCalledAnything() {
    val probe = VideoProbe()
    probe.offer(ByteArray(64) { (it + 3).toByte() })
    val report = probe.report()
    assertEquals(ProbeVerdict.NO_START_CODES, report.verdict)
    assertEquals(1L, report.payloads)
    assertEquals(0L, report.startCodesSeen)
    assertFalse(report.sawH264ParameterSets)
  }

  @Test
  fun aSyntheticAnnexBSequenceIsSeenWithItsUnitTypes() {
    val probe = VideoProbe()
    // Four units, parameter sets then two pictures, with both the four byte and the three byte start code
    val stream = byteArrayOf(
      0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1E,
      0, 0, 0, 1, 0x68, 0xCE.toByte(), 0x3C, 0x80.toByte(),
      0, 0, 0, 1, 0x65, 0x11, 0x22,
      0, 0, 1, 0x41, 0x33, 0x44,
    )
    probe.offer(stream)
    val report = probe.report()
    assertEquals(ProbeVerdict.START_CODES_SEEN, report.verdict)
    assertEquals(4L, report.startCodesSeen)
    assertEquals(1L, report.payloadsStartingWithStartCode)
    assertTrue(report.sawH264ParameterSets)
    assertEquals(1L, report.unitTypes[7])
    assertEquals(1L, report.unitTypes[8])
    assertEquals(1L, report.unitTypes[5])
    assertEquals(1L, report.unitTypes[1])
  }

  @Test
  fun fragmentsAreCountedPerChannelWithTheirGaps() {
    val fragments = VideoFragments()
    fragments.record(22346, ByteArray(100), 1000)
    fragments.record(22346, ByteArray(300), 1050)
    fragments.record(22346, ByteArray(10), 1050 + VideoFragments.GAP_MS + 10)
    fragments.record(22352, ByteArray(20), 1100)
    val channels = fragments.channels()
    assertEquals(2, channels.size)
    val first = channels.first { it.channel == 22346 }
    assertEquals(3L, first.fragments)
    assertEquals(410L, first.bytes)
    assertEquals(300, first.largestFragment)
    assertEquals(1L, first.gaps)
    assertTrue(first.longestGapMs >= VideoFragments.GAP_MS)
  }
}
