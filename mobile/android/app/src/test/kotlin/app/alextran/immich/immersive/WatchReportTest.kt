package app.alextran.immich.immersive

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The film rule of the immersive viewer (FreeKC's request of 31 October 2026, WatchRule in Dart): a video of at least
 * the threshold is a film, which plays once and whose position the viewer reports to the app every 5 s; any other
 * video loops as before, and the kiosk neither reports nor loops.
 */
class WatchReportTest {
  private val tenMinutes = 10 * 60_000L
  private val film = 98 * 60_000L
  private val unset = Long.MIN_VALUE + 1 // C.TIME_UNSET of Media3, before the player knows the duration

  @Test
  fun `a video of at least the threshold is a film`() {
    assertTrue(WatchReport.isFilm(film, tenMinutes))
    assertTrue(WatchReport.isFilm(tenMinutes, tenMinutes))
    assertFalse(WatchReport.isFilm(tenMinutes - 1, tenMinutes))
    assertFalse(WatchReport.isFilm(40_000L, tenMinutes))
  }

  @Test
  fun `a threshold of 0 makes every video a film, -1 none`() {
    assertTrue(WatchReport.isFilm(3_000L, 0L))
    assertFalse(WatchReport.isFilm(film, WatchReport.OFF))
    assertFalse(WatchReport.isFilm(film, -5L))
  }

  @Test
  fun `nothing is a film before the player knows its duration`() {
    assertFalse(WatchReport.isFilm(unset, 0L))
    assertFalse(WatchReport.isFilm(0L, 0L))
  }

  @Test
  fun `a film plays once, a shorter video loops as before, the kiosk never loops`() {
    assertFalse(WatchReport.loops(kiosk = false, durationMs = film, minDurationMs = tenMinutes))
    assertTrue(WatchReport.loops(kiosk = false, durationMs = 40_000L, minDurationMs = tenMinutes))
    assertTrue(WatchReport.loops(kiosk = false, durationMs = film, minDurationMs = WatchReport.OFF))
    assertTrue(WatchReport.loops(kiosk = false, durationMs = unset, minDurationMs = tenMinutes))
    assertFalse(WatchReport.loops(kiosk = true, durationMs = 40_000L, minDurationMs = tenMinutes))
    assertFalse(WatchReport.loops(kiosk = true, durationMs = film, minDurationMs = WatchReport.OFF))
  }

  @Test
  fun `the viewer reports a film it played, never a photo, the kiosk, a shorter video or one not played`() {
    fun reports(isVideo: Boolean = true, kiosk: Boolean = false, played: Boolean = true, durationMs: Long = film) =
      WatchReport.reports(isVideo, kiosk, played, durationMs, tenMinutes)

    assertTrue(reports())
    assertFalse(reports(isVideo = false))
    assertFalse(reports(kiosk = true))
    assertFalse(reports(durationMs = 40_000L))
    assertFalse(reports(played = false))
  }

  @Test
  fun `a report is due 5 s after the one before`() {
    assertEquals(5_000L, WatchReport.INTERVAL_MS)
    assertFalse(WatchReport.due(4_999L))
    assertTrue(WatchReport.due(5_000L))
    assertTrue(WatchReport.due(60_000L))
  }

  @Test
  fun `the position reported is where the film is, its duration once it ended`() {
    assertEquals(2_520_000L, WatchReport.reportedPositionMs(2_520_000L, film, ended = false))
    assertEquals(film, WatchReport.reportedPositionMs(0L, film, ended = true))
    assertEquals(film, WatchReport.reportedPositionMs(film + 800L, film, ended = false))
    assertEquals(0L, WatchReport.reportedPositionMs(-40L, film, ended = false))
  }
}
