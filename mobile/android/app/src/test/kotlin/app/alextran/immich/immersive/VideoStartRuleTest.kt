package app.alextran.immich.immersive

import app.alextran.immich.immersive.VideoStartRule.OverLimit
import app.alextran.immich.immersive.VideoStartRule.Start
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoStartRuleTest {
  private fun start(
    refused: Boolean = false,
    plain: Boolean = true,
    original: Boolean = true,
    streamed: Boolean = true,
    fileMedia: Boolean = false,
    hasFallback: Boolean = false,
    streamable: Boolean = true,
  ) = VideoStartRule.start(refused, plain, original, streamed, fileMedia, hasFallback, streamable)

  @Test
  fun `an original the server cannot stream is downloaded when its copy is no fallback`() {
    // The immersive viewer of 30 October: no Range on /original, the MP4 index at the end, and the server's copy
    // H.264 5760 x 2880, which Flutter sent no more as the fallback since the headset cannot decode it
    assertEquals(Start.DOWNLOAD, start(hasFallback = false, streamable = false))
  }

  @Test
  fun `an original the server cannot stream goes to the copy when the copy decodes`() {
    assertEquals(Start.FALLBACK, start(hasFallback = true, streamable = false))
  }

  @Test
  fun `an original that streams plays as it is, with or without a fallback`() {
    assertEquals(Start.URL, start(hasFallback = true, streamable = true))
    assertEquals(Start.URL, start(hasFallback = false, streamable = true))
  }

  @Test
  fun `a refusal of the app is said at once, before anything loads`() {
    for (streamable in listOf(true, false)) {
      assertEquals(Start.REFUSE, start(refused = true, streamable = streamable))
    }
  }

  @Test
  fun `files of the headset, files of a share, lens plans and copies play as they are`() {
    assertEquals(Start.URL, start(streamed = false, streamable = false))
    assertEquals(Start.URL, start(fileMedia = true, streamable = false))
    assertEquals(Start.URL, start(plain = false, streamable = false))
    assertEquals(Start.URL, start(original = false, streamable = false))
  }

  @Test
  fun `only a server original is probed for streaming`() {
    assertTrue(VideoStartRule.probes(refused = false, plain = true, original = true, streamed = true, fileMedia = false))
    assertFalse(VideoStartRule.probes(refused = true, plain = true, original = true, streamed = true, fileMedia = false))
    assertFalse(VideoStartRule.probes(refused = false, plain = false, original = true, streamed = true, fileMedia = false))
    assertFalse(VideoStartRule.probes(refused = false, plain = true, original = false, streamed = true, fileMedia = false))
    assertFalse(VideoStartRule.probes(refused = false, plain = true, original = true, streamed = false, fileMedia = false))
    assertFalse(VideoStartRule.probes(refused = false, plain = true, original = true, streamed = true, fileMedia = true))
  }

  @Test
  fun `a video beyond the decoder switches to the copy, else a server video stops at once, else a file warns`() {
    assertEquals(OverLimit.SWITCH, VideoStartRule.overLimit(fallbackLeft = true, fromServer = true))
    assertEquals(OverLimit.REFUSE, VideoStartRule.overLimit(fallbackLeft = false, fromServer = true))
    assertEquals(OverLimit.WARN, VideoStartRule.overLimit(fallbackLeft = false, fromServer = false))
    assertEquals(OverLimit.SWITCH, VideoStartRule.overLimit(fallbackLeft = true, fromServer = false))
  }

  @Test
  fun `the download line says how far it is`() {
    assertEquals(0, VideoStartRule.percent(0L, 1000L))
    assertEquals(45, VideoStartRule.percent(450L, 1000L))
    assertEquals(100, VideoStartRule.percent(1000L, 1000L))
    assertEquals(null, VideoStartRule.percent(10L, -1L))
    assertEquals(99, VideoStartRule.percent(999L, 1000L))
  }

  @Test
  fun `the download needs room for the whole file and a margin`() {
    assertTrue(VideoStartRule.fits(sizeBytes = 2_000_000_000L, freeBytes = 3_000_000_000L))
    assertFalse(VideoStartRule.fits(sizeBytes = 2_000_000_000L, freeBytes = 2_100_000_000L))
    assertFalse(VideoStartRule.fits(sizeBytes = -1L, freeBytes = 3_000_000_000L))
  }
}
