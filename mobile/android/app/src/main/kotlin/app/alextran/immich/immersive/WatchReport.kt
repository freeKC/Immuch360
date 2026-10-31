package app.alextran.immich.immersive

/**
 * The film rule in the immersive viewer (FreeKC's request of 31 October 2026, WatchRule on the Dart side, which keeps
 * the watch progress for the whole app): a video longer than the threshold Flutter gives (ImmersiveApi.open's
 * watchMinDurationMs, -1 with "Remember where I stopped" off) is a film. A film plays once, and the viewer reports
 * where it is to the app every [INTERVAL_MS] while it plays, when the viewer goes behind the system, before it asks for
 * the previous or next media, at its end and as it closes (ImmersiveEvents.progress). Any other video loops as before;
 * the kiosk plays its film once and never reports. Pure, unit tested in WatchReportTest.
 */
object WatchReport {
  /** "Remember where I stopped" off: no video is a film */
  const val OFF = -1L

  /** How often a film that plays is reported: a crash or a kill of the headset loses this much at most */
  const val INTERVAL_MS = 5_000L

  /** Whether a video of [durationMs] (unknown below 1) is a film, longer than the threshold [minDurationMs] */
  fun isFilm(durationMs: Long, minDurationMs: Long): Boolean =
    minDurationMs >= 0 && durationMs > 0 && durationMs > minDurationMs

  /** Whether the player loops the video: never the kiosk (its end shows the card), never a film, any other video. */
  fun loops(kiosk: Boolean, durationMs: Long, minDurationMs: Long): Boolean =
    !kiosk && !isFilm(durationMs, minDurationMs)

  /** Whether the viewer tells the app where this media is: a film it played in this opening, never the kiosk. */
  fun reports(isVideo: Boolean, kiosk: Boolean, played: Boolean, durationMs: Long, minDurationMs: Long): Boolean =
    isVideo && !kiosk && played && isFilm(durationMs, minDurationMs)

  /** Whether a report is due, [sinceLastMs] after the one before */
  fun due(sinceLastMs: Long): Boolean = sinceLastMs >= INTERVAL_MS

  /** Where a film of [durationMs] is reported at [positionMs]: within the film, at its duration once it [ended]. */
  fun reportedPositionMs(positionMs: Long, durationMs: Long, ended: Boolean): Long =
    when {
      ended && durationMs > 0 -> durationMs
      durationMs > 0 -> positionMs.coerceIn(0L, durationMs)
      else -> positionMs.coerceAtLeast(0L)
    }
}
