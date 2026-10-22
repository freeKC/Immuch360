package app.alextran.immich.djilink

/**
 * When the USB permission may be asked for, kept apart from the platform so that the rules can be tested without a
 * device.
 *
 * Three rules. One request at a time: while a dialog is up, nothing asks again, whatever arrives. A refusal is an
 * answer: it is shown, and only the pilot's retry button or a new plug asks again, never a USB state broadcast or a
 * periodic attempt. And an accessory that appears while the page is open may have the system chooser on screen above
 * it, so the request waits [graceMs] for the chooser to hand the permission over before it opens a dialog of its own.
 */
class PermissionPolicy(
  private val graceMs: Long = GRACE_MS,
  private val staleMs: Long = STALE_MS,
) {
  companion object {
    /** How long a newly plugged accessory is left to the system chooser before the permission is asked */
    const val GRACE_MS = 5_000L

    /** A request with no answer after this long may be asked again, by the pilot only */
    const val STALE_MS = 30_000L
  }

  /** What started an attempt */
  enum class Trigger {
    /** The first attempt after the page started: the accessory was plugged in before, no chooser is pending */
    START,

    /** The periodic attempt while nothing is open */
    PERIODIC,

    /** A USB state broadcast */
    USB_STATE,

    /** The pilot chose this application in the system chooser, which also grants the permission */
    ATTACH_ENTRY,

    /** The retry button */
    PILOT,

    /** The answer of the permission dialog came back */
    PERMISSION_RESULT,
  }

  sealed class Decision {
    /** The permission is held: open the accessory */
    data object Open : Decision()

    /** Ask for the permission now */
    data object Ask : Decision()

    /** A dialog is already up: wait for its answer */
    data object Pending : Decision()

    /** The pilot refused: show it, and wait for the retry button or a new plug */
    data object Refused : Decision()

    /** Wait this long, then try again: the system chooser may still hand the permission over */
    data class Grace(val waitMs: Long) : Decision()
  }

  private var seenKey: String? = null
  private var seenSinceMs = 0L
  private var pendingSinceMs: Long? = null
  private var refusedKey: String? = null

  val pending: Boolean get() = pendingSinceMs != null

  /**
   * An accessory with this [key] is listed. [held] says whether the permission is already held. The decision is what
   * to do about it; [onAsked] must follow an [Decision.Ask] that was carried out.
   */
  fun decide(key: String, held: Boolean, trigger: Trigger, nowMs: Long): Decision {
    if (key != seenKey) {
      // Another accessory, or the same one plugged in again after it left the list: a fresh start
      seenKey = key
      seenSinceMs = nowMs
      refusedKey = null
      pendingSinceMs = null
    }
    if (trigger == Trigger.ATTACH_ENTRY || trigger == Trigger.PILOT) {
      // A new plug through the chooser, or the pilot asking again: a refusal is no longer the last word
      refusedKey = null
    }
    if (held) {
      pendingSinceMs = null
      return Decision.Open
    }
    val pendingSince = pendingSinceMs
    if (pendingSince != null) {
      val stale = nowMs - pendingSince >= staleMs
      if (!(stale && trigger == Trigger.PILOT)) {
        return Decision.Pending
      }
      pendingSinceMs = null
    }
    if (refusedKey == key) {
      return Decision.Refused
    }
    if (trigger == Trigger.PERIODIC || trigger == Trigger.USB_STATE) {
      val waited = nowMs - seenSinceMs
      if (waited < graceMs) {
        return Decision.Grace(graceMs - waited)
      }
    }
    return Decision.Ask
  }

  /** The request was handed to the system */
  fun onAsked(nowMs: Long) {
    pendingSinceMs = nowMs
  }

  /** The request could not even be made */
  fun onAskFailed() {
    pendingSinceMs = null
  }

  /** The dialog answered. A refusal is remembered for the accessory that was listed. */
  fun onResult(granted: Boolean) {
    pendingSinceMs = null
    if (!granted) {
      refusedKey = seenKey
    }
  }

  /** Nothing is listed any more, or the accessory was detached: the next one starts afresh */
  fun onGone() {
    seenKey = null
    pendingSinceMs = null
    refusedKey = null
  }
}
