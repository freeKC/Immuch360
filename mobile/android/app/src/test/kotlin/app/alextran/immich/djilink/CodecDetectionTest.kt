package app.alextran.immich.djilink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which codec a video channel carries, from the stream itself */
class CodecDetectionTest {
  private val detector = CodecDetector()

  @Test
  fun h265ByItsParameterSets() {
    val fresh = detector.offer(
      HevcSamples.unitOf(
        HevcSamples.DELIMITER,
        HevcSamples.VPS,
        HevcSamples.SPS,
        HevcSamples.PPS,
        HevcSamples.slice(type = 20),
        HevcSamples.suffixSei(1),
      )
    )
    assertNotNull(fresh)
    assertEquals(VideoCodec.H265, detector.codec)
    assertEquals(CodecEvidence.PARAMETER_SETS, detector.evidence)
    assertArrayEquals(HevcSamples.SPS, fresh!!.sps)
    assertEquals(1920, fresh.info.width)
    // The same description again in band is not a new one
    assertNull(detector.offer(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.VPS, HevcSamples.SPS, HevcSamples.PPS)))
  }

  @Test
  fun h265ByTheDelimiterSignatureAfterThirtyUnits() {
    repeat(CodecDetector.SIGNATURE_UNITS - 1) {
      detector.offer(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(it)))
    }
    assertEquals(VideoCodec.UNKNOWN, detector.codec)
    assertFalse(detector.showsH265Signature)
    detector.offer(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice(), HevcSamples.suffixSei(99)))
    assertEquals(VideoCodec.H265, detector.codec)
    assertEquals(CodecEvidence.DELIMITER_SIGNATURE, detector.evidence)
    assertTrue(detector.showsH265Signature)
    assertNull("no description comes with the signature", detector.description)
  }

  @Test
  fun aUnitWithoutTheDelimiterStartsTheRunAgain() {
    repeat(20) { detector.offer(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice())) }
    detector.offer(HevcSamples.unitOf(HevcSamples.slice()))
    repeat(20) { detector.offer(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice())) }
    assertEquals(VideoCodec.UNKNOWN, detector.codec)
  }

  @Test
  fun h264ByItsSequenceParameterSet() {
    // Baseline profile 66, level 3.0, sequence parameter set 0; a picture parameter set; an IDR slice
    val sps = byteArrayOf(0x67, 0x42, 0xC0.toByte(), 0x1E, 0x80.toByte())
    val pps = byteArrayOf(0x68, 0xCE.toByte(), 0x3C, 0x80.toByte())
    val idr = byteArrayOf(0x65, 0x88.toByte(), 0x84.toByte(), 0x00)
    detector.offer(HevcSamples.unitOf(sps, pps, idr))
    assertEquals(VideoCodec.H264, detector.codec)
    assertEquals(CodecEvidence.H264_PARAMETER_SETS, detector.evidence)
    assertEquals(66, detector.h264!!.profileIdc)
  }

  @Test
  fun anH264SliceHeaderByteReadTheH265WayIsNotAVps() {
    // 0x41 is an H.264 non IDR slice; read the H.265 way it is a type 32, but its second byte is not 0x01
    val slice = byteArrayOf(0x41, 0x9A.toByte(), 0x22, 0x11, 0x00, 0x7F)
    repeat(40) { detector.offer(HevcSamples.unitOf(slice)) }
    assertEquals(VideoCodec.UNKNOWN, detector.codec)
    assertNull(detector.description)
  }

  @Test
  fun anythingElseStaysUnknown() {
    detector.offer(HevcSamples.unitOf(byteArrayOf(0x12, 0x34, 0x56, 0x78)))
    assertEquals(VideoCodec.UNKNOWN, detector.codec)
    assertEquals(CodecEvidence.NONE, detector.evidence)
  }

  @Test
  fun theProbeNamesTheCodecOnceDetected() {
    val probe = VideoProbe()
    probe.offer(HevcSamples.picture(1))
    assertEquals(ProbeVerdict.START_CODES_SEEN, probe.report().verdict)
    probe.detector.offer(HevcSamples.unitOf(HevcSamples.VPS, HevcSamples.SPS, HevcSamples.PPS))
    assertEquals(ProbeVerdict.H265, probe.report().verdict)
  }
}
