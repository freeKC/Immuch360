package app.alextran.immich.djilink

/**
 * Whether a frame of the values a pilot reads goes to Flutter now: only when it says something new, and at most once
 * per [intervalMs] (ten a second), so that a number that moves with the flight is redrawn at 10 Hz and one that does
 * not move is never sent again. Pure, so that the pace is unit tested.
 */
class FrameGate<T>(private val intervalMs: Long, private val same: (T, T) -> Boolean) {
  private var last: T? = null
  private var lastAtMs = 0L

  /** The next frame goes whatever it holds: a screen came in front */
  fun reset() {
    last = null
  }

  /** True when [value] goes: it differs from the last one sent, which went at least [intervalMs] ago */
  fun offer(value: T, nowMs: Long): Boolean {
    val previous = last
    if (previous != null && (nowMs - lastAtMs < intervalMs || same(previous, value))) {
      return false
    }
    last = value
    lastAtMs = nowMs
    return true
  }
}
