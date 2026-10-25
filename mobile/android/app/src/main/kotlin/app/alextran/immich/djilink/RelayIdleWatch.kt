package app.alextran.immich.djilink

/**
 * When a relay left on with nothing to send and no headset stops by itself (p2/stage2b-review.md, finding 8): the
 * flight ended, the phone went into a pocket, and the wake lock, the low latency Wi-Fi lock and the tick would
 * otherwise run until the user thinks of Stop. Pure, so that it is unit tested; the controller asks it on its tick, on
 * the main thread.
 */
class RelayIdleWatch(private val limitMs: Long) {
  private var idleSinceMs: Long? = null

  /** The relay starts again, or was just started: the time counts from its next idle tick */
  fun reset() {
    idleSinceMs = null
  }

  /**
   * True once [idle] has held on every call for [limitMs]; anything that is not idle starts the count again. True only
   * once: the count starts again after it.
   */
  fun expired(idle: Boolean, nowMs: Long): Boolean {
    if (!idle) {
      idleSinceMs = null
      return false
    }
    val since = idleSinceMs ?: nowMs.also { idleSinceMs = it }
    if (nowMs - since < limitMs) {
      return false
    }
    idleSinceMs = null
    return true
  }
}
