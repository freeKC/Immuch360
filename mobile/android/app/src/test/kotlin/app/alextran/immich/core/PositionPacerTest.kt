package app.alextran.immich.core

import me.albemala.native_video_player.PositionPacer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** When the flat player sends its position to Flutter, which is the redraw rate of the window while a video plays */
class PositionPacerTest {
  /** How many positions go to Flutter over [seconds] of steady playback read at each tick of the player */
  private fun sentOverSteadyPlayback(pacer: PositionPacer, seconds: Int): Int {
    var sent = 0
    var now = 1_000L
    var position = 0L
    val end = now + seconds * 1000L
    while (now < end) {
      if (pacer.shouldSend(position, playing = true, now = now)) sent++
      now += PositionPacer.TICK_MS
      position += PositionPacer.TICK_MS
    }
    return sent
  }

  @Test
  fun aQuestGetsTheIntervalOfEachTickAndAPhoneTenASecond() {
    assertEquals(PositionPacer.TICK_MS, FlatPlayerPosition.intervalFor(horizonOs = true))
    assertEquals(8L, FlatPlayerPosition.intervalFor(horizonOs = true))
    assertEquals(100L, FlatPlayerPosition.intervalFor(horizonOs = false))
    assertEquals(PositionPacer.DEFAULT_INTERVAL_MS, FlatPlayerPosition.intervalFor(horizonOs = false))
  }

  @Test
  fun onAQuestEveryTickOfSteadyPlaybackGoesToFlutter() {
    // 125 ticks a second, each one sent: more than the 72 or 90 Hz of the display, so a frame at every refresh
    assertEquals(125 * 2, sentOverSteadyPlayback(PositionPacer(FlatPlayerPosition.intervalFor(true)), 2))
  }

  @Test
  fun onAPhoneSteadyPlaybackSendsTenPositionsASecond() {
    val sent = sentOverSteadyPlayback(PositionPacer(FlatPlayerPosition.intervalFor(false)), 4)
    assertTrue("sent $sent", sent in 39..41)
  }

  @Test
  fun theFirstPositionGoesAtOnceAndTheSameOneNeverAgain() {
    val pacer = PositionPacer(100L)
    assertTrue(pacer.shouldSend(5_000L, playing = true, now = 10L))
    assertFalse(pacer.shouldSend(5_000L, playing = true, now = 500L))
    assertFalse(pacer.shouldSend(5_000L, playing = false, now = 900L))
  }

  @Test
  fun aSeekWhilePlayingGoesAtOnce() {
    val pacer = PositionPacer(100L)
    assertTrue(pacer.shouldSend(5_000L, playing = true, now = 0L))
    assertFalse(pacer.shouldSend(5_008L, playing = true, now = 8L))
    // Forward by more than a second, then back: both inside the interval, both sent
    assertTrue(pacer.shouldSend(60_000L, playing = true, now = 16L))
    assertTrue(pacer.shouldSend(2_000L, playing = true, now = 24L))
    // A step of exactly a second is not a seek
    assertFalse(pacer.shouldSend(3_000L, playing = true, now = 32L))
  }

  @Test
  fun anyChangeWhileNotPlayingGoesAtOnce() {
    val pacer = PositionPacer(100L)
    assertTrue(pacer.shouldSend(1_000L, playing = true, now = 0L))
    // Paused, then a drag of the time bar a few ms at a time
    assertTrue(pacer.shouldSend(1_004L, playing = false, now = 8L))
    assertTrue(pacer.shouldSend(1_020L, playing = false, now = 16L))
    assertTrue(pacer.shouldSend(1_030L, playing = false, now = 24L))
  }

  @Test
  fun theEndOfTheFilmGoesAtOnceWhenThePlayerStops() {
    val pacer = PositionPacer(100L)
    assertTrue(pacer.shouldSend(119_900L, playing = true, now = 0L))
    assertFalse(pacer.shouldSend(119_950L, playing = true, now = 50L))
    // The player stops at the end: no longer playing, the last position goes at once
    assertTrue(pacer.shouldSend(120_000L, playing = false, now = 58L))
  }

  @Test
  fun aNegativeIntervalActsAsEveryTick() {
    val pacer = PositionPacer(-5L)
    assertEquals(0L, pacer.intervalMs)
    assertTrue(pacer.shouldSend(0L, playing = true, now = 0L))
    assertTrue(pacer.shouldSend(8L, playing = true, now = 8L))
  }
}
