package app.alextran.immich.core

/**
 * How often the flat player (FlatPlayerSetup) sends its position to Flutter while a video plays, per kind of device.
 * Each position rebuilds the controls and asks for a frame (see PositionPacer).
 */
object FlatPlayerPosition {
  /** A phone or a TV: 10 positions a second, the rate of release 48 that freed the main thread for Plex films */
  const val PHONE_INTERVAL_MS = 100L

  /**
   * A Meta Quest: 10 positions a second too. Its window keeps the display's rate while a video plays through
   * DisplayRatePacer (Dart), which asks for a frame at each refresh: measured on a Quest 3 on 21 November 2026, the
   * position at each 8 ms tick alone gave 41 frames a second (the positions landed just after a refresh), and it cost
   * the main thread 22.6 % during a video against 4.1 % at 10 a second. Kept apart from the phones' value so that the
   * Quest can change on its own.
   */
  const val QUEST_INTERVAL_MS = 100L

  /** The interval of the position while a video plays on this kind of device ([horizonOs]: a Meta Quest) */
  fun intervalFor(horizonOs: Boolean): Long = if (horizonOs) QUEST_INTERVAL_MS else PHONE_INTERVAL_MS
}
