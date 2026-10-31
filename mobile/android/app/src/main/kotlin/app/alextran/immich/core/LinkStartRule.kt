package app.alextran.immich.core

import kotlin.math.roundToLong

/**
 * How much media a streamed video waits for before it plays, from what the link brings: FreeKC's request of 31 October
 * 2026, a film starts as soon as it reasonably can, and a link that cannot keep up waits for enough to play a while
 * rather than pausing every few seconds. [ratio] is what the link brings per second against what the video consumes
 * per second (see [LinkMeter.ratio]), null while it is not measured yet.
 *
 * | Link                | Before playing, at the start or after a seek | After a stall                  |
 * |---------------------|----------------------------------------------|--------------------------------|
 * | unknown, or >= 1.25 | 1 s                                          | 2 s                            |
 * | 1 to 1.25           | 2 s                                          | 4 s                            |
 * | 0.5 to 1            | 30 s x (1 - ratio), 1 to 15 s                | 60 s x (1 - ratio), 2 to 30 s  |
 * | below 0.5           | 1 s                                          | 30 s                           |
 *
 * Below 1, what is waited for gives about 30 s of play before the next pause (60 s after a stall). Never longer than
 * 4 s once [START_MS] is there ([START_LONGEST_WAIT_MS]), 30 s once [REBUFFER_MS] is there after a stall
 * ([REBUFFER_LONGEST_WAIT_MS]). At the start, a link under half the video ([START_WAIT_RATIO]) does not wait past
 * [START_MS]. A wait is never a failure: a video is dead only when nothing arrives ([isDead]).
 *
 * The same rule in Dart (video_link_rule.dart, for the players of the computers and the texts), checked against the
 * same cases (src/test/resources/video_link_rule_cases.json). Pure, so that it is tested.
 */
object LinkStartRule {
  /** A link this much faster than the video starts at once */
  const val FAST_RATIO = 1.25

  const val START_MS = 1_000L
  const val REBUFFER_MS = 2_000L
  const val NEAR_START_MS = 2_000L
  const val NEAR_REBUFFER_MS = 4_000L

  /** The play a short link buffers for before it plays, at the start and after a stall */
  const val START_HORIZON_MS = 30_000L
  const val REBUFFER_HORIZON_MS = 60_000L

  const val START_MAX_MS = 15_000L
  const val REBUFFER_MAX_MS = 30_000L

  /**
   * The longest wait once [START_MS] (or [REBUFFER_MS]) is buffered: short at the start, where the user waits for the
   * first frame (10 s put it 8 s later than before over a link at a quarter of the film, 31 October 2026), longer after
   * a stall, where a longer wait gives a longer play
   */
  const val START_LONGEST_WAIT_MS = 4_000L

  /**
   * Under this ratio the start waits for [START_MS] only, as Media3 does: a second of wait gives [ratio] / (1 - ratio)
   * seconds of play, less than a second here (over a link at a quarter of the film, 4 s of wait put the first frame
   * 2 to 4 s later than before for one second more of play, 31 October 2026). After a stall the wait stays: the link
   * makes it whatever it is cut into, fewer and longer pauses are better.
   */
  const val START_WAIT_RATIO = 0.5
  const val REBUFFER_LONGEST_WAIT_MS = 30_000L

  /** Bytes that count as progress: a trickle of a few bytes is none */
  const val PROGRESS_BYTES = 16L * 1024L

  /** A wait without progress for this long is a server or a link that stopped sending */
  const val DEAD_AFTER_MS = 30_000L

  /** A link below this ratio for [SLOW_AFTER_MS] is said to be too slow for the video */
  const val SLOW_RATIO = 0.9
  const val SLOW_AFTER_MS = 5_000L

  /** The least media there is before a video plays: [START_MS], [REBUFFER_MS] after a stall */
  fun minimumMs(rebuffering: Boolean): Long = if (rebuffering) REBUFFER_MS else START_MS

  /** The longest wait once [minimumMs] is buffered */
  fun longestWaitMs(rebuffering: Boolean): Long = if (rebuffering) REBUFFER_LONGEST_WAIT_MS else START_LONGEST_WAIT_MS

  /** The media to have ahead of the position before playing, see the table */
  fun targetMs(ratio: Double?, rebuffering: Boolean): Long {
    if (ratio == null || ratio.isNaN() || ratio >= FAST_RATIO) {
      return minimumMs(rebuffering)
    }
    if (ratio >= 1.0) {
      return if (rebuffering) NEAR_REBUFFER_MS else NEAR_START_MS
    }
    if (!rebuffering && ratio < START_WAIT_RATIO) {
      return START_MS
    }
    val short = 1.0 - ratio.coerceAtLeast(0.0)
    return if (rebuffering) {
      (REBUFFER_HORIZON_MS * short).roundToLong().coerceIn(REBUFFER_MS, REBUFFER_MAX_MS)
    } else {
      (START_HORIZON_MS * short).roundToLong().coerceIn(START_MS, START_MAX_MS)
    }
  }

  /**
   * Whether the video plays now, with [bufferedMs] of media ahead of the position and [minimumHeldMs] since
   * [minimumMs] was there (null while it is not): the target is there, or the longest wait is over.
   */
  fun shouldStart(bufferedMs: Long, ratio: Double?, rebuffering: Boolean, minimumHeldMs: Long?): Boolean {
    if (bufferedMs >= targetMs(ratio, rebuffering)) {
      return true
    }
    return bufferedMs >= minimumMs(rebuffering) && minimumHeldMs != null &&
      minimumHeldMs >= longestWaitMs(rebuffering)
  }

  /**
   * About how long the wait still lasts, in ms, with [bufferedMs] ahead at [ratio] (media seconds that arrive per
   * second); null when it cannot be told (no measure, or nothing arrives)
   */
  fun remainingWaitMs(bufferedMs: Long, ratio: Double?, rebuffering: Boolean, minimumHeldMs: Long?): Long? {
    if (ratio == null || ratio.isNaN() || ratio <= 0.0) {
      return null
    }
    val missing = (targetMs(ratio, rebuffering) - bufferedMs).coerceAtLeast(0L)
    var wait = (missing / ratio).roundToLong()
    val minimum = minimumMs(rebuffering)
    val untilMinimum = ((minimum - bufferedMs).coerceAtLeast(0L) / ratio).roundToLong()
    // The longest wait counts from the minimum: the wait never goes past it
    val cap = untilMinimum + longestWaitMs(rebuffering) - (minimumHeldMs ?: 0L)
    if (wait > cap) {
      wait = cap
    }
    return wait.coerceAtLeast(0L)
  }

  /** Whether a video that waits ([waiting]) with [sinceProgressMs] since the last progress is dead */
  fun isDead(waiting: Boolean, sinceProgressMs: Long?): Boolean =
    waiting && sinceProgressMs != null && sinceProgressMs >= DEAD_AFTER_MS

  /** Whether [ratio], measured below [SLOW_RATIO] for [slowForMs], says the link is too slow for the video */
  fun isSlow(ratio: Double?, slowForMs: Long): Boolean =
    ratio != null && !ratio.isNaN() && ratio < SLOW_RATIO && slowForMs >= SLOW_AFTER_MS
}
