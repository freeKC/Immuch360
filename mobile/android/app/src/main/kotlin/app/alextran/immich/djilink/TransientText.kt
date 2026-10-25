package app.alextran.immich.djilink

/**
 * The warnings around the drone's picture come and go (FreeKC's rule of 25 October), in the Quest's flight view as in
 * Flutter (dji_live_transient.dart, the same numbers): "Watching only", the observer rule, the state of the reception,
 * the red line of a picture that stopped or comes late, "Not compared with DJI Fly yet" and the controls' hint appear,
 * stay five seconds and fade out. Any button brings them back for five seconds, and a warning that changes kind shows
 * again by itself. What stays: the flight values, the delay line, and an error that needs an action until it is
 * resolved, among them the one line that says no picture shows while the video is hidden. Pure, so that it is tested.
 */
object TransientText {
  const val FADE_IN_MS = 250L

  /** Shown this long in all, its fade in included */
  const val HOLD_MS = 5_000L
  const val FADE_OUT_MS = 800L

  /** The opacity [sinceMs] after the warning was last shown: in over 250 ms, 1 until 5 s, out over 0.8 s, then 0 */
  fun alpha(sinceMs: Long, keep: Boolean = false): Float = when {
    keep -> 1f
    sinceMs < 0 -> 0f
    sinceMs < FADE_IN_MS -> sinceMs.toFloat() / FADE_IN_MS
    sinceMs <= HOLD_MS -> 1f
    sinceMs < HOLD_MS + FADE_OUT_MS -> 1f - (sinceMs - HOLD_MS).toFloat() / FADE_OUT_MS
    else -> 0f
  }

  /** Whether it is shown (in, or held) rather than going or gone: the view animates between the two */
  fun shown(sinceMs: Long, keep: Boolean = false): Boolean = keep || (sinceMs in 0..HOLD_MS)
}

/**
 * When one warning was last shown: when it first came, when its kind changed ("live" to "lost", a picture that stops),
 * and when a button brought it back. A kind that only changes its numbers ("No new picture for 1.2 s", then 1.3 s) is
 * the same kind.
 */
class TransientClock {
  private var kind: Any? = null
  private var shownAtMs: Long? = null

  /** The warning says [kind] now (null: it is not there); a new kind shows it again */
  fun follow(kind: Any?, nowMs: Long) {
    if (kind != this.kind) {
      this.kind = kind
      if (kind != null) {
        shownAtMs = nowMs
      }
    }
  }

  /** A button: shown again for five seconds; one that still shows goes back to full from where it is */
  fun recall(nowMs: Long) {
    val alpha = alpha(nowMs)
    shownAtMs = nowMs - (TransientText.FADE_IN_MS * alpha).toLong()
  }

  fun sinceMs(nowMs: Long): Long = shownAtMs?.let { nowMs - it } ?: Long.MAX_VALUE

  fun alpha(nowMs: Long, keep: Boolean = false): Float = TransientText.alpha(sinceMs(nowMs), keep)

  fun shown(nowMs: Long, keep: Boolean = false): Boolean = kind != null && TransientText.shown(sinceMs(nowMs), keep)
}
