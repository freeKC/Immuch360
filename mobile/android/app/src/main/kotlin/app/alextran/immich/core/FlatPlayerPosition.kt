package app.alextran.immich.core

import me.albemala.native_video_player.PositionPacer

/**
 * How often the flat player (FlatPlayerSetup) sends its position to Flutter while a video plays, per kind of device.
 * The window redraws once per position, so this is its frame rate during playback (see PositionPacer).
 */
object FlatPlayerPosition {
  /** A phone or a TV: 10 positions a second, the rate of release 48 that freed the main thread for Plex films */
  const val PHONE_INTERVAL_MS = 100L

  /**
   * A Meta Quest: the position at each tick of the player, as up to release 47. At 10 a second the window presented
   * 10 frames a second while a video played (Meta's review of build 48 failed VRC.Quest.Performance.1); at each tick it
   * presents a frame at nearly every refresh of the display, 62 to 66 a second measured on build 47
   */
  const val QUEST_INTERVAL_MS = PositionPacer.TICK_MS

  /** The interval of the position while a video plays on this kind of device ([horizonOs]: a Meta Quest) */
  fun intervalFor(horizonOs: Boolean): Long = if (horizonOs) QUEST_INTERVAL_MS else PHONE_INTERVAL_MS
}
