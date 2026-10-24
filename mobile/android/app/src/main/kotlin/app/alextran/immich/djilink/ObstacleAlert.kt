package app.alextran.immich.djilink

import android.media.AudioManager
import android.media.ToneGenerator
import android.util.Log

/** Where an obstacle is, in a top view with the nose up */
enum class ObstacleSide { AHEAD, BEHIND, LEFT, RIGHT, ABOVE }

/**
 * What the drone's sensing said at one moment, as this app reads it (p2/telemetry-deep-dive-2026-10-24.md, 4.2): the
 * nearest distance of the obstacle ring of push 36/8, which comes only while the motors run.
 */
data class ObstacleInput(
  /** The nearest distance around the drone, null when no sector reads anything or no ring came */
  val nearestM: Double?,
  /** How old the last ring is, null when none ever came */
  val ageMs: Long?,
  /** The motors bits of the flight data, null when that group is stale or never came */
  val motorsOn: Boolean?,
  /** Flight mode 12, the automatic landing: a landing or a palm catch brings a surface or a hand close */
  val landing: Boolean = false,
  /** Which side, once a capture proves which index of the ring is the nose; null today */
  val side: ObstacleSide? = null,
  /** A warning bit, once a capture names one; none is named today */
  val warning: Boolean = false,
)

data class ObstacleDecision(
  val on: Boolean,
  val distanceM: Double?,
  val side: ObstacleSide?,
  /** 0 when silent */
  val beepIntervalMs: Int,
  /** The data stopped while the alert was on: the banner says so for a few seconds, with no sound */
  val stopped: Boolean,
  /** Offered and fresh: the glyph shows; it never means the way is clear */
  val listening: Boolean,
) {
  companion object {
    val OFF = ObstacleDecision(
      on = false,
      distanceM = null,
      side = null,
      beepIntervalMs = 0,
      stopped = false,
      listening = false,
    )
  }
}

/**
 * The decision of the obstacle alert (p2/design-final-2026-10-24.md, 4.5), the same on the phone, in the window of the
 * headset and in its flight view, fed with what each device receives. Pure, with its own memory: on at 3.0 m or
 * closer, off at 3.5 m or farther, at least one second on, a ring older than 0.6 s stops it, and that stop is said for
 * five seconds unless the motors stopped (the ring stops with them by design).
 *
 * It decides what to draw and how fast to beep, nothing else: it never sends anything to the remote or the drone, never
 * brakes and never changes a setting. The drone's own obstacle avoidance and the remote do that.
 */
class ObstacleAlert {
  companion object {
    const val ON_AT_M = 3.0
    const val OFF_AT_M = 3.5
    const val MIN_ON_MS = 1_000L
    const val STALE_MS = 600L
    const val STOPPED_MS = 5_000L
    const val BEEP_FAR_MS = 600
    const val BEEP_NEAR_MS = 150
    const val NEAR_M = 0.5
    const val WARNING_BEEP_MS = 300

    /** 600 ms at 3.0 m, falling in a straight line to 150 ms at 0.5 m and under; never a continuous tone */
    fun beepIntervalMs(distanceM: Double): Int = when {
      distanceM >= ON_AT_M -> BEEP_FAR_MS
      distanceM <= NEAR_M -> BEEP_NEAR_MS
      else -> (BEEP_NEAR_MS + (distanceM - NEAR_M) / (ON_AT_M - NEAR_M) * (BEEP_FAR_MS - BEEP_NEAR_MS)).toInt()
    }
  }

  private var onSinceMs: Long? = null
  private var stoppedUntilMs: Long? = null

  fun reset() {
    onSinceMs = null
    stoppedUntilMs = null
  }

  fun decide(offered: Boolean, input: ObstacleInput, nowMs: Long): ObstacleDecision {
    if (!offered) {
      reset()
      return ObstacleDecision.OFF
    }
    val age = input.ageMs
    val fresh = age != null && age <= STALE_MS
    if (!fresh) {
      if (onSinceMs != null) {
        onSinceMs = null
        // The ring comes only while the motors run: once the flight data says they stopped, the alert ends quietly
        stoppedUntilMs = if (input.motorsOn == false) null else nowMs + STOPPED_MS
      }
      val until = stoppedUntilMs
      if (until != null && nowMs < until) {
        return ObstacleDecision.OFF.copy(stopped = true)
      }
      stoppedUntilMs = null
      return ObstacleDecision.OFF
    }
    stoppedUntilMs = null
    // A landing brings the ground and a hand close: no alert while the drone lands or its motors are off
    val active = input.motorsOn != false && !input.landing
    val distance = input.nearestM
    val since = onSinceMs
    val close = when {
      distance != null -> if (since == null) distance <= ON_AT_M else distance < OFF_AT_M
      else -> input.warning
    }
    val on = when {
      active && close -> true
      since != null && nowMs - since < MIN_ON_MS -> true
      else -> false
    }
    if (!on) {
      onSinceMs = null
      return ObstacleDecision.OFF.copy(listening = true)
    }
    if (since == null) {
      onSinceMs = nowMs
    }
    return ObstacleDecision(
      on = true,
      distanceM = distance,
      side = input.side,
      beepIntervalMs = if (distance != null) beepIntervalMs(distance) else WARNING_BEEP_MS,
      stopped = false,
      listening = true,
    )
  }
}

/** What the alert reads from the values of the source in use: the ring, its age, the motors and the landing */
fun obstacleInputOf(values: TelemetryValues?): ObstacleInput {
  val ring = values?.obstacles
  val flight = values?.flight?.takeIf { !it.stale }?.value
  return ObstacleInput(
    nearestM = ring?.value?.nearestM,
    ageMs = ring?.ageMs,
    motorsOn = flight?.motorsOn,
    landing = flight?.mode == TelemetryFields.MODE_AUTOMATIC_LANDING,
  )
}

/** Plays one short beep */
fun interface ObstacleBeeper {
  fun beep()
}

/**
 * The beeps of the obstacle alert (p2/design-final-2026-10-24.md, 4.7): one short beep every
 * [ObstacleDecision.beepIntervalMs], only while the alert is on, its sound on, and a screen with the picture in front
 * on this device. Pure apart from the beeper, so that the rhythm is unit tested.
 */
class ObstacleTone(private val beeper: ObstacleBeeper) {
  companion object {
    const val TEST_BEEPS = 3
    const val TEST_INTERVAL_MS = 300L
  }

  private var lastBeepMs: Long? = null

  /** Called every few tens of milliseconds; [intervalMs] 0 is silence */
  fun update(intervalMs: Int, soundOn: Boolean, screenShown: Boolean, nowMs: Long) {
    if (intervalMs <= 0 || !soundOn || !screenShown) {
      lastBeepMs = null
      return
    }
    val last = lastBeepMs
    if (last == null || nowMs - last >= intervalMs) {
      lastBeepMs = nowMs
      beeper.beep()
    }
  }
}

/**
 * The beep itself: a short tone on the media stream, the volume DJI's own beeps follow, which the volume keys set while
 * the live screen is in front. Made on the first beep, released with [release].
 */
class ToneBeeper : ObstacleBeeper {
  companion object {
    private const val TAG = "ObstacleTone"
    private const val BEEP_MS = 80
  }

  private var generator: ToneGenerator? = null

  override fun beep() {
    val tone = generator ?: runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, ToneGenerator.MAX_VOLUME) }
      .onFailure { Log.w(TAG, "no tone generator: ${it.javaClass.simpleName}") }
      .getOrNull()
      ?.also { generator = it }
      ?: return
    runCatching { tone.startTone(ToneGenerator.TONE_PROP_BEEP, BEEP_MS) }
  }

  fun release() {
    generator?.let { runCatching { it.release() } }
    generator = null
  }
}
