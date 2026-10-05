package app.alextran.immich.core

import androidx.media3.exoplayer.DecoderCounters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackStatsLoggerTest {
  @Test
  fun `a summary tells the frames rendered and dropped, and the rate reached against the video's`() {
    assertEquals(
      "video stats (loop): 998 rendered, 2 dropped (0.2%), at most 1 in a row, in 20.0 s, 49.9 fps of 50.0",
      PlaybackStatsLogger.statsLine("loop", 998, 2, 1, 20000, 50f),
    )
  }

  @Test
  fun `a summary without frames, time or rate divides by nothing`() {
    assertEquals(
      "video stats (stop): 0 rendered, 0 dropped (0.0%), at most 0 in a row, in 0.0 s, 0.0 fps of ?",
      PlaybackStatsLogger.statsLine("stop", 0, 0, 0, 0, -1f),
    )
  }

  @Test
  fun `a summary keeps a dot for the decimals whatever the locale`() {
    val locale = java.util.Locale.getDefault()
    try {
      java.util.Locale.setDefault(java.util.Locale.FRANCE)
      assertEquals(
        "video stats (loop): 1497 rendered, 3 dropped (0.2%), at most 2 in a row, in 30.0 s, 49.9 fps of 50.0",
        PlaybackStatsLogger.statsLine("loop", 1497, 3, 2, 30000, 50f),
      )
    } finally {
      java.util.Locale.setDefault(locale)
    }
  }

  @Test
  fun `a summary of a lens renderer starts with its stream`() {
    assertEquals(
      "stream 1: video stats (stop): 300 rendered, 0 dropped (0.0%), at most 0 in a row, in 10.0 s, 30.0 fps of 30.0",
      PlaybackStatsLogger.statsLine("stop", 300, 0, 0, 10000, 30f, stream = 1),
    )
  }

  private fun counters(rendered: Int, dropped: Int, maxConsecutive: Int = 0) =
    DecoderCounters().also { it.add(rendered, dropped, maxConsecutive) }

  private fun DecoderCounters.add(rendered: Int, dropped: Int, maxConsecutive: Int = 0) {
    renderedOutputBufferCount += rendered
    droppedBufferCount += dropped
    maxConsecutiveDroppedBufferCount = maxOf(maxConsecutiveDroppedBufferCount, maxConsecutive)
  }

  @Test
  fun `a single renderer counts from its last summary, without a stream`() {
    val stats = DecoderStats(emptyList())
    val video = counters(0, 0)
    stats.enabled(video, 1000)
    video.add(998, 2, 1)
    assertEquals(
      listOf(PlaybackStatsLogger.statsLine("loop", 998, 2, 1, 20000, 50f)),
      stats.summaries("loop", 21000, 50f),
    )
    video.add(500, 0)
    assertEquals(
      PlaybackStatsLogger.statsLine("stop", 500, 0, 1, 10000, 50f),
      stats.disabled(video, "stop", 31000, 50f),
    )
    assertEquals(emptyList<String>(), stats.summaries("loop", 32000, 50f))
  }

  @Test
  fun `two lens renderers keep their own counts, one line each with its stream`() {
    val stats = DecoderStats(listOf(1, 0))
    val first = counters(0, 0)
    val second = counters(0, 0)
    stats.enabled(first, 0)
    stats.enabled(second, 0)
    first.add(600, 0)
    second.add(590, 10, 4)
    assertEquals(
      listOf(
        PlaybackStatsLogger.statsLine("loop", 600, 0, 0, 20000, 30f, stream = 1),
        PlaybackStatsLogger.statsLine("loop", 590, 10, 4, 20000, 30f, stream = 0),
      ),
      stats.summaries("loop", 20000, 30f),
    )
    // The renderer that stops first logs its own frames since the loop, never the other's: no negative count
    first.add(300, 0)
    second.add(10, 0)
    assertEquals(
      PlaybackStatsLogger.statsLine("stop", 10, 0, 4, 10000, 30f, stream = 0),
      stats.disabled(second, "stop", 30000, 30f),
    )
    assertEquals(
      PlaybackStatsLogger.statsLine("stop", 300, 0, 0, 10000, 30f, stream = 1),
      stats.disabled(first, "stop", 30000, 30f),
    )
  }

  @Test
  fun `a lens renderer enabled again alone takes back its place and its stream`() {
    val stats = DecoderStats(listOf(0, 1))
    val first = counters(0, 0)
    stats.enabled(first, 0)
    stats.enabled(counters(0, 0), 0)
    stats.disabled(first, "stop", 5000, 30f)
    val again = counters(0, 0)
    stats.enabled(again, 6000)
    again.add(120, 0)
    assertEquals(
      PlaybackStatsLogger.statsLine("loop", 120, 0, 0, 4000, 30f, stream = 0),
      stats.summaries("loop", 10000, 30f).first(),
    )
  }

  @Test
  fun `counters enabled before the logger listened log nothing`() {
    assertNull(DecoderStats(emptyList()).disabled(counters(10, 0), "stop", 1000, 30f))
  }
}
