package app.alextran.immich.core

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.SinglePeriodTimeline
import androidx.media3.exoplayer.upstream.Allocator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptiveLoadControlTest {
  private var now = 1_000_000L
  private val meter = LinkMeter { now }

  /** Media3's buffers: 1 s before playing at the start, 2 s after a stall */
  private val delegate =
    object : LoadControl {
      override fun getAllocator(playerId: PlayerId): Allocator = throw UnsupportedOperationException()

      override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean =
        parameters.bufferedDurationUs >= if (parameters.rebuffering) 2_000_000L else 1_000_000L

      override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean = true
    }
  private val control = AdaptiveLoadControl(delegate, meter) { now }

  /** A film of 12 minutes, 720 MB: it needs 1 MB/s */
  private val timeline = SinglePeriodTimeline(720_000_000L, true, false, false, null, MediaItem.EMPTY)
  private val periodId = MediaSource.MediaPeriodId(timeline.getUidOfPeriod(0))

  private fun ask(positionMs: Long, bufferedMs: Long, rebuffering: Boolean): Boolean =
    control.shouldStartPlayback(
      LoadControl.Parameters(
        PlayerId.UNSET,
        timeline,
        periodId,
        positionMs * 1000L,
        bufferedMs * 1000L,
        1f,
        true,
        rebuffering,
        C.TIME_UNSET,
        C.TIME_UNSET,
      )
    )

  /** What the link brings, in tenths of the film: 1 MB/s is 10 */
  private var tenths = 0L

  /**
   * A wait the player keeps asking about every 10 ms for [ms], the buffer growing with what the link brings (a tenth
   * of the film's rate is a tenth of a second of media per second)
   */
  private fun waitFor(positionMs: Long, fromMs: Long, rebuffering: Boolean, ms: Long): Boolean {
    var buffered = fromMs
    var elapsed = 0L
    while (elapsed < ms) {
      if (ask(positionMs, buffered, rebuffering)) return true
      now += 10
      elapsed += 10
      meter.onBytes(tenths * 1_000L)
      buffered += tenths
    }
    return false
  }

  /** A link at [tenthsOfTheFilm] tenths of the film, measured for 4 s */
  private fun linkMeasured(tenthsOfTheFilm: Long) {
    tenths = tenthsOfTheFilm
    meter.onStart()
    meter.onFileSize("film", 720_000_000L)
    repeat(400) {
      now += 10
      meter.onBytes(tenths * 1_000L)
    }
  }

  private fun slowLinkMeasured() = linkMeasured(tenthsOfTheFilm = 2L)

  @Test
  fun `a stall of the link waits for the link, then plays what came meanwhile`() {
    slowLinkMeasured()
    // The buffer ran out: the first ask of the wait finds a tenth of a second
    assertFalse(waitFor(positionMs = 60_000L, fromMs = 100L, rebuffering = true, ms = 20_000L))
    assertEquals(30_000L, control.targetMs)
    // The 2 s Media3 asks came after 9.5 s; 30 s more at most
    assertTrue(waitFor(positionMs = 60_000L, fromMs = 4_100L, rebuffering = true, ms = 20_000L))
    assertEquals(0L, control.targetMs)
  }

  @Test
  fun `a stall with the media Media3 asks already there plays at once, as Media3 would`() {
    slowLinkMeasured()
    // A decoder that fell behind, a new surface: the player waits with 6.6 s ahead (measured on an emulator over a
    // link at a quarter of the film: 30 s of wait for that each time, for 3 s of play)
    assertTrue(ask(positionMs = 60_000L, bufferedMs = 6_600L, rebuffering = true))
    assertEquals(0L, control.targetMs)
  }

  @Test
  fun `a seek inside the buffer plays at once`() {
    slowLinkMeasured()
    assertTrue(ask(positionMs = 30_000L, bufferedMs = 4_000L, rebuffering = false))
  }

  @Test
  fun `the start over a link short of the film waits once a second is there, four seconds at most`() {
    linkMeasured(tenthsOfTheFilm = 8L)
    assertFalse(ask(positionMs = 0L, bufferedMs = 100L, rebuffering = false))
    assertEquals(6_000L, control.targetMs)
    // 1 s after 1.1 s, 4 s more: 4.3 s ahead at 5.1 s
    assertFalse(waitFor(positionMs = 0L, fromMs = 100L, rebuffering = false, ms = 5_000L))
    assertTrue(waitFor(positionMs = 0L, fromMs = 4_100L, rebuffering = false, ms = 300L))
  }

  @Test
  fun `the start over a link under half the film plays once its first second is there`() {
    slowLinkMeasured()
    assertFalse(ask(positionMs = 0L, bufferedMs = 100L, rebuffering = false))
    assertEquals(1_000L, control.targetMs)
    assertFalse(waitFor(positionMs = 0L, fromMs = 100L, rebuffering = false, ms = 4_000L))
    assertTrue(waitFor(positionMs = 0L, fromMs = 900L, rebuffering = false, ms = 1_000L))
  }
}
