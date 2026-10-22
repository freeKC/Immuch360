package app.alextran.immich.djilink

/**
 * The rules that stand between the Quest controllers and anything that could move an aircraft.
 *
 * Nothing in stage 1 sends a command, and the send path is behind [DjiLinkBuild.SEND_ENABLED], which is false. This
 * class exists at this stage anyway, and is unit tested at this stage, because the safety machinery has to be older
 * than the first byte it guards, not younger.
 *
 * Any one of the signals below returns the sticks to neutral, drops authority and says why. No single signal is
 * trusted to be enough: the viewer of this same application has already been seen to go deaf after an idle period
 * with its own activity flag still saying it was fine.
 */
enum class DeadManSignal {
  /** The controller reports inactive, its entity is gone, or it became a hand */
  CONTROLLER_INACTIVE,

  /** The controller pose is not tracked */
  POSE_NOT_TRACKED,

  /** The session is not focused */
  SESSION_NOT_FOCUSED,

  /** The headset was taken off */
  HEADSET_REMOVED,

  /** The newest reading is older than the age limit */
  SAMPLE_TOO_OLD,

  /** The link is not in the aircraft linked state */
  LINK_NOT_LINKED,

  /** A write blocked or the liveness probe failed */
  WRITE_BLOCKED,

  /** The application lost the foreground */
  FOREGROUND_LOST,

  /** The triggers that hold authority were released */
  TRIGGERS_RELEASED,
}

/** Where the sticks are allowed to be, and why */
data class SafetyDecision(
  val sample: StickSample,
  val armed: Boolean,
  val neutralised: Boolean,
  val reasons: Set<DeadManSignal>,
)

/** Build time switch of the send path. False in every release of stage 1. */
object DjiLinkBuild {
  const val SEND_ENABLED = false
}

class InputSafety(
  /** A reading older than this is no reading */
  private val maxSampleAgeMs: Long = MAX_SAMPLE_AGE_MS,
  /** At most one send per this many milliseconds, which is the cadence the controller application itself uses */
  private val minSendIntervalMs: Long = MIN_SEND_INTERVAL_MS,
  /** Both triggers held this long arms, with a countdown on screen */
  private val armHoldMs: Long = ARM_HOLD_MS,
) {
  companion object {
    const val MAX_SAMPLE_AGE_MS = 100L
    const val MIN_SEND_INTERVAL_MS = 20L
    const val ARM_HOLD_MS = 2_000L
  }

  private var takeControlRequested = false
  private var triggersHeldSinceMs: Long? = null
  private var lastSendMs: Long? = null

  var armed = false
    private set

  /** The pilot pressed "take control" on the panel. The triggers still have to be held afterwards. */
  fun requestControl() {
    takeControlRequested = true
  }

  /** Instant, and needs no confirmation */
  fun disarm() {
    armed = false
    takeControlRequested = false
    triggersHeldSinceMs = null
  }

  /** Milliseconds still to hold, zero once armed, null while no hold is under way */
  fun armingCountdownMs(nowMs: Long): Long? {
    val since = triggersHeldSinceMs ?: return null
    if (armed) {
      return 0
    }
    return (armHoldMs - (nowMs - since)).coerceAtLeast(0)
  }

  /**
   * What the sticks are, after the rules. [signals] are the ones the caller already knows about; this adds the age
   * limit and the trigger rule.
   */
  fun evaluate(sample: StickSample?, signals: Set<DeadManSignal>, nowMs: Long): SafetyDecision {
    val reasons = signals.toMutableSet()
    if (sample == null || nowMs - sample.atMs > maxSampleAgeMs) {
      reasons.add(DeadManSignal.SAMPLE_TOO_OLD)
    }
    val triggers = sample?.triggersHeld == true
    if (!triggers) {
      reasons.add(DeadManSignal.TRIGGERS_RELEASED)
      triggersHeldSinceMs = null
      armed = false
    } else if (reasons.isEmpty()) {
      val since = triggersHeldSinceMs ?: nowMs.also { triggersHeldSinceMs = it }
      if (takeControlRequested && nowMs - since >= armHoldMs) {
        armed = true
      }
    } else {
      triggersHeldSinceMs = null
      armed = false
    }
    if (reasons.isNotEmpty()) {
      armed = false
    }
    val neutral = reasons.isNotEmpty() || !armed
    return SafetyDecision(
      sample = if (neutral) StickSample.neutral(atMs = nowMs, sequence = sample?.sequence ?: 0) else sample!!,
      armed = armed,
      neutralised = neutral,
      reasons = reasons,
    )
  }

  /** Whether a send would be allowed now: armed, nothing in doubt, and not faster than the rate limit */
  fun maySend(decision: SafetyDecision, nowMs: Long): Boolean {
    if (!DjiLinkBuild.SEND_ENABLED || !decision.armed || decision.neutralised) {
      return false
    }
    val last = lastSendMs
    if (last != null && nowMs - last < minSendIntervalMs) {
      return false
    }
    lastSendMs = nowMs
    return true
  }
}
