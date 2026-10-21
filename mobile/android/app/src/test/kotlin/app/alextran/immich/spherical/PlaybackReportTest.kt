package app.alextran.immich.spherical

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackReportTest {
  @Test
  fun `describes a video that does not play with what the player saw`() {
    val text =
      PlaybackReport.describe(
        title = "VID_5K.mp4",
        source = "the server original",
        error = "ERROR_CODE_DECODER_INIT_FAILED",
        video = "H.264 5760 x 2880 at 30.0 fps, 80.0 Mbit/s",
        stats = null,
        bufferedMs = 2500,
        heapBytes = 192L shl 20,
        bufferTargetBytes = 96 shl 20,
        device = "Acme TV, Android 12 (API 31), TV: true, low memory: true",
      )

    assertTrue(text.startsWith("The 360° player cannot play VID_5K.mp4 from the server original"))
    assertTrue(text.contains("Decoder: none started"))
    assertTrue(text.contains("network rate: not measured, buffered ahead: 2500 ms"))
    assertTrue(text.contains("Java heap: 192 MiB, buffer target: 96 MiB"))
  }

  @Test
  fun `a file on the device has no streaming buffer`() {
    val text =
      PlaybackReport.describe(
        title = null,
        source = "a file on the device",
        error = "ERROR_CODE_DECODING_FAILED",
        video = null,
        stats = PlaybackStats(),
        bufferedMs = 0,
        heapBytes = 512L shl 20,
        bufferTargetBytes = null,
        device = "Phone",
      )

    assertTrue(text.contains("cannot play a video from a file on the device"))
    assertTrue(text.contains("Video: no video track"))
    assertTrue(text.contains("buffer target: the default of a file"))
  }

  @Test
  fun `takes the URLs out of an error message`() {
    assertEquals(
      "Unable to connect to (a URL) after 8 s",
      PlaybackReport.withoutUrls("Unable to connect to http://127.0.0.1:41234/secret/1/a.mp4 after 8 s"),
    )
  }

  @Test
  fun `megabits with one decimal`() {
    assertEquals("80.0", PlaybackReport.megabits(80_000_000))
    assertEquals("12.3", PlaybackReport.megabits(12_345_678))
  }
}
