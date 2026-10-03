package app.alextran.immich.immersive

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ImmersiveMediaTest {
  @Test
  fun `H264 above 4K exceeds the headset decoder`() {
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 5760, 2880))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 7680, 3840))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4097, 2048))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4096, 2305))
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 3840, 3840))
  }

  @Test
  fun `H264 up to 4096x2304 fits`() {
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4096, 2304))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 4096, 2048))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 3840, 2160))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 3840, 1920))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 2880, 1440))
  }

  @Test
  fun `portrait sizes are checked on the long and the short side`() {
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("video/avc", 2880, 5760))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 2160, 3840))
  }

  @Test
  fun `other codecs never exceed`() {
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/hevc", 5760, 2880))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/av01", 7680, 3840))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder(null, 5760, 2880))
  }

  @Test
  fun `mime type is compared without case`() {
    assertTrue(ImmersiveMedia.exceedsAvcDecoder("VIDEO/AVC", 5760, 2880))
  }

  @Test
  fun `unknown sizes do not exceed`() {
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", -1, -1))
    assertFalse(ImmersiveMedia.exceedsAvcDecoder("video/avc", 0, 0))
  }

  @Test
  fun `a file URL from Flutter gives the file on the headset, its escapes decoded`() {
    assertEquals(
      File("/storage/emulated/0/DCIM/Camera/IMG 360 #1.jpg"),
      ImmersiveMedia.localFileFor("file:///storage/emulated/0/DCIM/Camera/IMG%20360%20%231.jpg"),
    )
    assertEquals(
      File("/storage/emulated/0/Oculus/VideoShots/été.mp4"),
      ImmersiveMedia.localFileFor("file:///storage/emulated/0/Oculus/VideoShots/%C3%A9t%C3%A9.mp4"),
    )
  }

  @Test
  fun `server URLs and malformed file URLs give no file`() {
    assertNull(ImmersiveMedia.localFileFor("https://immich.example/api/assets/abc/original?edited=true"))
    assertNull(ImmersiveMedia.localFileFor("content://media/external/images/media/12"))
    assertNull(ImmersiveMedia.localFileFor("file:IMG_360.jpg"))
    assertNull(ImmersiveMedia.localFileFor("file:"))
  }

  @Test
  fun `times under an hour show minutes and seconds`() {
    assertEquals("0:00", ImmersiveMedia.formatTime(0))
    assertEquals("0:00", ImmersiveMedia.formatTime(999))
    assertEquals("0:01", ImmersiveMedia.formatTime(1_000))
    assertEquals("0:59", ImmersiveMedia.formatTime(59_999))
    assertEquals("1:00", ImmersiveMedia.formatTime(60_000))
    assertEquals("12:34", ImmersiveMedia.formatTime(754_000))
    assertEquals("59:59", ImmersiveMedia.formatTime(3_599_999))
  }

  @Test
  fun `times from an hour on show hours, minutes and seconds`() {
    assertEquals("1:00:00", ImmersiveMedia.formatTime(3_600_000))
    assertEquals("1:02:03", ImmersiveMedia.formatTime(3_723_000))
    assertEquals("10:00:05", ImmersiveMedia.formatTime(36_005_000))
  }

  @Test
  fun `unknown and negative times show zero`() {
    // Media3 C.TIME_UNSET, the duration before the player is ready
    assertEquals("0:00", ImmersiveMedia.formatTime(Long.MIN_VALUE + 1))
    assertEquals("0:00", ImmersiveMedia.formatTime(-5_000))
  }

  @Test
  fun `a photo closes at position zero`() {
    assertEquals(0L, ImmersiveMedia.closingPositionMs(false, 12_000L, 8_000L, 5_000L))
    assertEquals(0L, ImmersiveMedia.closingPositionMs(false, null, null, 5_000L))
  }

  @Test
  fun `a video that plays closes at the position of its player`() {
    assertEquals(42_000L, ImmersiveMedia.closingPositionMs(true, 42_000L, 30_000L, 5_000L))
    assertEquals(0L, ImmersiveMedia.closingPositionMs(true, 0L, 30_000L, 5_000L))
  }

  @Test
  fun `a video whose player is gone closes at the last position known`() {
    assertEquals(30_000L, ImmersiveMedia.closingPositionMs(true, null, 30_000L, 5_000L))
  }

  @Test
  fun `a video closed before its player started keeps its start position`() {
    assertEquals(5_000L, ImmersiveMedia.closingPositionMs(true, null, null, 5_000L))
    assertEquals(0L, ImmersiveMedia.closingPositionMs(true, null, null, 0L))
  }

  @Test
  fun `the answer to a previous or next request replaces the request text`() {
    val looking = "Looking for the next media"
    assertEquals("No next media", ImmersiveMedia.statusAfterNavigation(looking, looking, "No next media"))
    // A timeout gives back the status held back during the request
    assertEquals("Full resolution", ImmersiveMedia.statusAfterNavigation(looking, looking, "Full resolution"))
  }

  @Test
  fun `an error shown while a request is pending stays after the answer`() {
    val looking = "Looking for the next media"
    val error = "The video cannot be played"
    assertEquals(error, ImmersiveMedia.statusAfterNavigation(error, looking, "No next media"))
    assertEquals(error, ImmersiveMedia.statusAfterNavigation(error, looking, "Full resolution"))
  }

  @Test
  fun `a closing position is never negative`() {
    // Flutter resumes its flat player at this position, which must be a real one
    assertEquals(0L, ImmersiveMedia.closingPositionMs(true, -1_000L, null, 5_000L))
    assertEquals(0L, ImmersiveMedia.closingPositionMs(true, null, null, -1L))
  }
}
