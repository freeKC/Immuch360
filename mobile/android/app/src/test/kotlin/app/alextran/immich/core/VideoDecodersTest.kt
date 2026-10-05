package app.alextran.immich.core

import androidx.media3.common.C
import androidx.media3.common.Format
import app.alextran.immich.core.VideoDecoders.MIME_AV1
import app.alextran.immich.core.VideoDecoders.MIME_AVC
import app.alextran.immich.core.VideoDecoders.MIME_HEVC
import app.alextran.immich.core.VideoDecoders.MIME_VP9
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoDecodersTest {
  @Test
  fun `four character codes give their MIME type`() {
    assertEquals("video/avc", VideoDecoders.mimeFor("avc1"))
    assertEquals("video/avc", VideoDecoders.mimeFor("avc3"))
    assertEquals("video/hevc", VideoDecoders.mimeFor("hvc1"))
    assertEquals("video/hevc", VideoDecoders.mimeFor("hev1"))
    assertEquals("video/av01", VideoDecoders.mimeFor("av01"))
    assertEquals("video/x-vnd.on2.vp9", VideoDecoders.mimeFor("vp09"))
    assertEquals("video/mp4v-es", VideoDecoders.mimeFor("mp4v"))
  }

  @Test
  fun `an RFC 6381 string gives the MIME type of its four character code`() {
    assertEquals("video/hevc", VideoDecoders.mimeFor("hvc1.2.4.L153.B0"))
    assertEquals("video/avc", VideoDecoders.mimeFor("avc1.640033"))
    assertEquals("video/av01", VideoDecoders.mimeFor("av01.0.08M.10"))
    assertEquals("video/x-vnd.on2.vp9", VideoDecoders.mimeFor("vp09.00.41.08"))
  }

  @Test
  fun `the codec names of the server give their MIME type`() {
    assertEquals("video/avc", VideoDecoders.mimeFor("h264"))
    assertEquals("video/hevc", VideoDecoders.mimeFor("hevc"))
    assertEquals("video/av01", VideoDecoders.mimeFor("av1"))
    assertEquals("video/x-vnd.on2.vp9", VideoDecoders.mimeFor("vp9"))
  }

  @Test
  fun `a MIME type stays as it is, in lower case`() {
    assertEquals("video/hevc", VideoDecoders.mimeFor("video/hevc"))
    assertEquals("video/avc", VideoDecoders.mimeFor("VIDEO/AVC"))
    assertEquals("video/dolby-vision", VideoDecoders.mimeFor("video/dolby-vision"))
  }

  @Test
  fun `four character codes are read without case or spaces`() {
    assertEquals("video/hevc", VideoDecoders.mimeFor(" HVC1 "))
    assertEquals("video/avc", VideoDecoders.mimeFor("AVC1.640033"))
  }

  @Test
  fun `Dolby Vision codes give the Dolby Vision type`() {
    assertEquals("video/dolby-vision", VideoDecoders.mimeFor("dvh1.08.07"))
    assertEquals("video/dolby-vision", VideoDecoders.mimeFor("dvhe"))
  }

  @Test
  fun `blank and unknown codecs give nothing`() {
    assertNull(VideoDecoders.mimeFor(""))
    assertNull(VideoDecoders.mimeFor("   "))
    assertNull(VideoDecoders.mimeFor("xyz1"))
    assertNull(VideoDecoders.mimeFor("mp4a.40.2"))
  }

  @Test
  fun `codec names for the user`() {
    assertEquals("H.264", VideoDecoders.codecName("video/avc"))
    assertEquals("HEVC", VideoDecoders.codecName("video/hevc"))
    assertEquals("AV1", VideoDecoders.codecName("video/av01"))
    assertEquals("VP9", VideoDecoders.codecName("video/x-vnd.on2.vp9"))
    assertEquals("HEVC", VideoDecoders.codecName("VIDEO/HEVC"))
  }

  @Test
  fun `an unknown MIME type is its own name`() {
    assertEquals("video/mp4v-es", VideoDecoders.codecName("video/mp4v-es"))
    assertEquals("video/x-unknown", VideoDecoders.codecName("video/x-unknown"))
    assertEquals("?", VideoDecoders.codecName(null))
  }

  @Test
  fun `on Horizon OS, H264 above 4096x2304 is refused whatever the list says`() {
    assertTrue(VideoDecoders.exceedsMeasuredLimit("video/avc", 5760, 2880, horizonOs = true))
    assertTrue(VideoDecoders.exceedsMeasuredLimit("video/avc", 7680, 3840, horizonOs = true))
    assertTrue(VideoDecoders.exceedsMeasuredLimit("video/avc", 4096, 2305, horizonOs = true))
    assertTrue(VideoDecoders.exceedsMeasuredLimit("video/avc", 2880, 5760, horizonOs = true))
  }

  @Test
  fun `on Horizon OS, H264 up to 4096x2304 follows the list`() {
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 4096, 2304, horizonOs = true))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 3840, 1920, horizonOs = true))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 2160, 3840, horizonOs = true))
  }

  @Test
  fun `the measured limit only concerns H264 on Horizon OS`() {
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 5760, 2880, horizonOs = false))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/hevc", 5760, 2880, horizonOs = true))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/av01", 7680, 3840, horizonOs = true))
    assertFalse(VideoDecoders.exceedsMeasuredLimit(null, 5760, 2880, horizonOs = true))
  }

  @Test
  fun `unknown sizes never exceed the measured limit`() {
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", -1, -1, horizonOs = true))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 0, 0, horizonOs = true))
  }

  @Test
  fun `on Horizon OS, the H264 decoders report the measured size at most`() {
    assertEquals(4096 to 2304, VideoDecoders.reportedMaxSize("video/avc", 8192, 4320, horizonOs = true))
    assertEquals(3840 to 2160, VideoDecoders.reportedMaxSize("video/avc", 3840, 2160, horizonOs = true))
    assertEquals(4080 to 2304, VideoDecoders.reportedMaxSize("video/avc", 4080, 4080, horizonOs = true))
  }

  @Test
  fun `other decoders report what their list says`() {
    assertEquals(8192 to 4320, VideoDecoders.reportedMaxSize("video/avc", 8192, 4320, horizonOs = false))
    assertEquals(8192 to 4320, VideoDecoders.reportedMaxSize("video/hevc", 8192, 4320, horizonOs = true))
  }

  @Test
  fun `the decoders of Android itself and FFmpeg run in software`() {
    assertTrue(VideoDecoders.isSoftwareName("OMX.google.h264.decoder"))
    assertTrue(VideoDecoders.isSoftwareName("c2.android.hevc.decoder"))
    assertTrue(VideoDecoders.isSoftwareName("c2.google.av1.decoder"))
    assertTrue(VideoDecoders.isSoftwareName("OMX.ffmpeg.h264.decoder"))
    assertTrue(VideoDecoders.isSoftwareName("OMX.SEC.avc.sw.dec"))
    assertTrue(VideoDecoders.isSoftwareName("OMX.qcom.video.decoder.hevcswvdec"))
    assertTrue(VideoDecoders.isSoftwareName("libvpx"))
  }

  @Test
  fun `vendor decoders run in hardware`() {
    assertFalse(VideoDecoders.isSoftwareName("c2.qti.avc.decoder"))
    assertFalse(VideoDecoders.isSoftwareName("OMX.qcom.video.decoder.avc"))
    assertFalse(VideoDecoders.isSoftwareName("c2.exynos.hevc.decoder"))
    assertFalse(VideoDecoders.isSoftwareName("OMX.Exynos.avc.dec"))
    assertFalse(VideoDecoders.isSoftwareName("arc.h264.decoder"))
  }

  @Test
  fun `a size off the alignment of the decoder is rounded up to it`() {
    assertEquals(1088, VideoDecoders.alignedSize(1080, 16))
    assertEquals(1080, VideoDecoders.alignedSize(1079, 2))
    assertEquals(2882, VideoDecoders.alignedSize(2881, 2))
    assertEquals(5760, VideoDecoders.alignedSize(5745, 64))
  }

  @Test
  fun `a size on the alignment, or without one, stays as it is`() {
    assertEquals(1920, VideoDecoders.alignedSize(1920, 16))
    assertEquals(2880, VideoDecoders.alignedSize(2880, 2))
    assertEquals(1079, VideoDecoders.alignedSize(1079, 1))
    assertEquals(1079, VideoDecoders.alignedSize(1079, 0))
  }

  @Test
  fun `the rate is asked rounded down`() {
    assertEquals(30.0, VideoDecoders.checkedFrameRate(30.02))
    assertEquals(29.0, VideoDecoders.checkedFrameRate(29.97))
    assertEquals(60.0, VideoDecoders.checkedFrameRate(60.0))
    assertEquals(1.0, VideoDecoders.checkedFrameRate(1.0))
  }

  @Test
  fun `below 1 fps or unknown, only the size is asked`() {
    assertNull(VideoDecoders.checkedFrameRate(0.99))
    assertNull(VideoDecoders.checkedFrameRate(0.0))
    assertNull(VideoDecoders.checkedFrameRate(-1.0))
    assertNull(VideoDecoders.checkedFrameRate(Double.NaN))
  }

  @Test
  fun `the switch label gets the codec and the size`() {
    val labels =
      mapOf(VideoDecoders.LABEL_SWITCHED to "Transcoded stream: the original ({codec} {width} x {height}) is too big")
    assertEquals(
      "Transcoded stream: the original (H.264 5760 x 2880) is too big",
      VideoDecoders.decoderLabel(labels, VideoDecoders.LABEL_SWITCHED, "H.264", 5760, 2880),
    )
  }

  @Test
  fun `a label without placeholders shows as it is`() {
    val labels = mapOf(VideoDecoders.LABEL_SWITCHED to "Playing the transcoded stream")
    assertEquals(
      "Playing the transcoded stream",
      VideoDecoders.decoderLabel(labels, VideoDecoders.LABEL_SWITCHED, "HEVC", 7680, 3840),
    )
  }

  @Test
  fun `a missing or blank label gives nothing`() {
    assertNull(VideoDecoders.decoderLabel(emptyMap(), VideoDecoders.LABEL_SWITCHED, "H.264", 5760, 2880))
    val blank = mapOf(VideoDecoders.LABEL_SWITCHED to " ")
    assertNull(VideoDecoders.decoderLabel(blank, VideoDecoders.LABEL_SWITCHED, "H.264", 5760, 2880))
  }

  @Test
  fun `on Horizon OS, two H264 streams are refused above the measured pixel rate`() {
    // Two Insta360 X3 lenses: 497 M pixels per second against the 283 M measured
    assertTrue(VideoDecoders.exceedsMeasuredLimit("video/avc", 2880, 2880, horizonOs = true, instances = 2))
    assertTrue(
      VideoDecoders.exceedsMeasuredLimit("video/avc", 2880, 2880, horizonOs = true, instances = 2, frameRate = 30.0),
    )
    // Two transcoded 1080x1080 streams
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 1080, 1080, horizonOs = true, instances = 2))
    // A rate below 30 counts as 30, the measured one; a higher one counts as it is
    assertFalse(
      VideoDecoders.exceedsMeasuredLimit("video/avc", 2560, 1440, horizonOs = true, instances = 2, frameRate = 24.0),
    )
    assertTrue(
      VideoDecoders.exceedsMeasuredLimit("video/avc", 2560, 1440, horizonOs = true, instances = 2, frameRate = 60.0),
    )
  }

  @Test
  fun `the pixel rate rule of two streams only concerns H264 on Horizon OS`() {
    // One 2304x2304 stream is within the measured size, two at once are above the measured rate
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 2304, 2304, horizonOs = true))
    assertTrue(VideoDecoders.exceedsMeasuredLimit("video/avc", 2304, 2304, horizonOs = true, instances = 2))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 2880, 2880, horizonOs = false, instances = 2))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/hevc", 3840, 3840, horizonOs = true, instances = 2))
    assertFalse(VideoDecoders.exceedsMeasuredLimit("video/avc", 0, 0, horizonOs = true, instances = 2))
  }

  @Test
  fun `the profile required for HEVC follows the codecs string, the bit depth and the transfer`() {
    assertEquals(2, VideoDecoders.requiredProfile(MIME_HEVC, 2, 10, C.COLOR_TRANSFER_HLG))
    assertEquals(4096, VideoDecoders.requiredProfile(MIME_HEVC, 2, 10, C.COLOR_TRANSFER_ST2084))
    assertEquals(4096, VideoDecoders.requiredProfile(MIME_HEVC, 4096, 10, C.COLOR_TRANSFER_ST2084))
    assertEquals(2, VideoDecoders.requiredProfile(MIME_HEVC, null, 10, Format.NO_VALUE))
    assertEquals(4096, VideoDecoders.requiredProfile(MIME_HEVC, null, 10, C.COLOR_TRANSFER_ST2084))
    assertNull(VideoDecoders.requiredProfile(MIME_HEVC, null, 8, Format.NO_VALUE))
    assertEquals(1, VideoDecoders.requiredProfile(MIME_HEVC, 1, 8, Format.NO_VALUE))
  }

  @Test
  fun `H264 is only checked for its 10 bit profiles`() {
    assertNull(VideoDecoders.requiredProfile(MIME_AVC, 8, 8, Format.NO_VALUE))
    assertEquals(16, VideoDecoders.requiredProfile(MIME_AVC, 16, 10, Format.NO_VALUE))
    assertEquals(16, VideoDecoders.requiredProfile(MIME_AVC, null, 10, Format.NO_VALUE))
    assertNull(VideoDecoders.requiredProfile(MIME_AVC, null, 0, Format.NO_VALUE))
  }

  @Test
  fun `AV1 and VP9 profiles, and none for other codecs`() {
    assertEquals(4096, VideoDecoders.requiredProfile(MIME_AV1, null, 10, C.COLOR_TRANSFER_ST2084))
    assertEquals(2, VideoDecoders.requiredProfile(MIME_AV1, null, 10, C.COLOR_TRANSFER_HLG))
    assertEquals(4, VideoDecoders.requiredProfile(MIME_VP9, 4, 10, Format.NO_VALUE))
    assertNull(VideoDecoders.requiredProfile(MIME_VP9, null, 10, Format.NO_VALUE))
    assertNull(VideoDecoders.requiredProfile("video/mp4v-es", null, 10, Format.NO_VALUE))
  }

  @Test
  fun `an HDR profile also plays on the base 10 bit decoder`() {
    assertEquals(setOf(4096, 2), VideoDecoders.acceptableProfiles(MIME_HEVC, 4096))
    assertEquals(setOf(8192, 2), VideoDecoders.acceptableProfiles(MIME_HEVC, 8192))
    assertEquals(setOf(2), VideoDecoders.acceptableProfiles(MIME_HEVC, 2))
    assertEquals(setOf(4096, 2), VideoDecoders.acceptableProfiles(MIME_AV1, 4096))
    assertEquals(setOf(4096, 4), VideoDecoders.acceptableProfiles(MIME_VP9, 4096))
    assertEquals(setOf(16), VideoDecoders.acceptableProfiles(MIME_AVC, 16))
  }

  @Test
  fun `profiles and levels are named as the codecs strings write them`() {
    assertEquals("Main 10", VideoDecoders.profileName(MIME_HEVC, 2))
    assertEquals("Main 10 HDR10", VideoDecoders.profileName(MIME_HEVC, 4096))
    assertEquals("L6.1", VideoDecoders.levelName(MIME_HEVC, 4194304))
    assertEquals("H6.1", VideoDecoders.levelName(MIME_HEVC, 8388608))
    assertEquals("L1", VideoDecoders.levelName(MIME_HEVC, 1))
    assertEquals("H6.2", VideoDecoders.levelName(MIME_HEVC, 33554432))
    assertEquals("Constrained Baseline", VideoDecoders.profileName(MIME_AVC, 65536))
    assertEquals("High 10", VideoDecoders.profileName(MIME_AVC, 16))
    assertEquals("6.1", VideoDecoders.levelName(MIME_AVC, 262144))
    assertEquals("1b", VideoDecoders.levelName(MIME_AVC, 2))
    assertEquals("Main 8", VideoDecoders.profileName(MIME_AV1, 1))
    assertEquals("6.1", VideoDecoders.levelName(MIME_AV1, 131072))
    assertEquals("2", VideoDecoders.levelName(MIME_AV1, 1))
    assertEquals("5", VideoDecoders.levelName(MIME_AV1, 4096))
    assertEquals("7", VideoDecoders.levelName(MIME_AV1, 1048576))
    assertEquals("6.1", VideoDecoders.levelName(MIME_VP9, 4096))
    assertEquals("Profile 2 HDR", VideoDecoders.profileName(MIME_VP9, 4096))
    assertEquals("Profile 8", VideoDecoders.profileName("video/dolby-vision", 256))
    assertNull(VideoDecoders.levelName("video/dolby-vision", 256))
  }

  @Test
  fun `unknown profiles keep their value and unknown levels are left out`() {
    assertEquals("profile 12345", VideoDecoders.profileName(MIME_HEVC, 12345))
    assertEquals("profile 3", VideoDecoders.profileName("video/mp4v-es", 3))
    assertNull(VideoDecoders.levelName(MIME_HEVC, 3))
    assertNull(VideoDecoders.levelName(MIME_AV1, 3))
    assertNull(VideoDecoders.levelName(MIME_AV1, 0))
  }

  @Test
  fun `a decoder's profiles are summed up with their highest level, in the order of the constants`() {
    assertEquals(
      listOf("Main L6.1", "Main 10 L6.1", "Main 10 HDR10 L5.1"),
      VideoDecoders.profilesSummary(MIME_HEVC, listOf(1 to 4194304, 2 to 1048576, 2 to 4194304, 4096 to 65536)),
    )
    assertEquals(listOf("profile 12345"), VideoDecoders.profilesSummary(MIME_HEVC, listOf(12345 to 3)))
    assertEquals(emptyList<String>(), VideoDecoders.profilesSummary(MIME_HEVC, emptyList()))
  }

  @Test
  fun `transfers are named for the logs`() {
    assertEquals("SDR", VideoDecoders.transferName(C.COLOR_TRANSFER_SDR))
    assertEquals("PQ", VideoDecoders.transferName(C.COLOR_TRANSFER_ST2084))
    assertEquals("HLG", VideoDecoders.transferName(C.COLOR_TRANSFER_HLG))
    assertEquals("unknown", VideoDecoders.transferName(Format.NO_VALUE))
  }

  @Test
  fun `several streams at once are refused to a software decoder above 2048x2048`() {
    assertTrue(VideoDecoders.softwareTooHeavy(hardware = false, width = 3840, height = 3840, instances = 2))
    assertTrue(VideoDecoders.softwareTooHeavy(hardware = false, width = 2880, height = 2880, instances = 2))
    assertFalse(VideoDecoders.softwareTooHeavy(hardware = false, width = 2048, height = 2048, instances = 2))
    assertFalse(VideoDecoders.softwareTooHeavy(hardware = false, width = 512, height = 512, instances = 2))
  }

  @Test
  fun `one stream, a hardware decoder or an unknown size are never too heavy`() {
    assertFalse(VideoDecoders.softwareTooHeavy(hardware = false, width = 3840, height = 3840, instances = 1))
    assertFalse(VideoDecoders.softwareTooHeavy(hardware = true, width = 3840, height = 3840, instances = 2))
    assertFalse(VideoDecoders.softwareTooHeavy(hardware = false, width = 0, height = 0, instances = 2))
  }
}
