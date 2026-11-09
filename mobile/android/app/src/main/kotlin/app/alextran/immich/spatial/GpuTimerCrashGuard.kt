package app.alextran.immich.spatial

/** Where [GpuTimerCrashGuard] keeps its two values across processes */
interface GpuTimerGuardStore {
  /** The driver key armed by a process, or null */
  fun armedKey(): String?

  /** Writes the armed key; [synchronous] writes it to disk before returning */
  fun setArmedKey(key: String?, synchronous: Boolean)

  /** The driver keys on which the GPU timers ran when a process died, oldest first */
  fun badKeys(): List<String>

  /** Writes the bad keys to disk before returning */
  fun setBadKeys(keys: List<String>)
}

/**
 * Remembers the drivers on which a process died while the GPU timer queries ran. A native crash in the driver cannot
 * be caught, so the guard writes the driver key before the first query of an armed period ([arm], synchronously) and
 * clears it when the timers stop ([disarm]: the renderer released, or the activity stopped once its GL thread is
 * parked). A key still armed when the next process first asks ([blocked]) is the key of a process that died with the
 * timers running: it joins the bad keys (at most [MAX_BAD_KEYS], the oldest dropped), and the timers stay off on that
 * driver. A crash in the driver therefore happens at most once per device and driver; a driver update makes a new key
 * and gets one new chance. A death in the foreground for another reason (memory, another crash) costs that driver its
 * GPU timers only, which the CPU timing replaces.
 *
 * One guard per process (see PreferencesGpuTimerGuardStore.guard): the check of the previous process runs once, at
 * the first call. Thread safe.
 */
class GpuTimerCrashGuard(private val store: GpuTimerGuardStore) {
  companion object {
    const val MAX_BAD_KEYS = 8
  }

  private var checked = false
  private var armed: String? = null
  private var tripped: String? = null

  /** True when the GPU timers ran on [driverKey] in a process that died, this one or an earlier one */
  @Synchronized
  fun blocked(driverKey: String): Boolean {
    checkPreviousProcess()
    return driverKey in store.badKeys()
  }

  /**
   * The driver key the previous process died with while its timers ran, once: the next call gives null. Read it after
   * [blocked].
   */
  @Synchronized
  fun takeTripped(): String? {
    val key = tripped
    tripped = null
    return key
  }

  /** Marks the timers as running on [driverKey], on disk before returning; nothing to write when already armed */
  @Synchronized
  fun arm(driverKey: String) {
    checkPreviousProcess()
    if (armed == driverKey) return
    store.setArmedKey(driverKey, synchronous = true)
    armed = driverKey
  }

  /** The timers stopped: nothing to remember. A key left by an earlier process is not this process's to clear. */
  @Synchronized
  fun disarm() {
    if (armed == null) return
    armed = null
    store.setArmedKey(null, synchronous = false)
  }

  private fun checkPreviousProcess() {
    if (checked) return
    checked = true
    val leftover = store.armedKey() ?: return
    store.setBadKeys((store.badKeys().filter { it != leftover } + leftover).takeLast(MAX_BAD_KEYS))
    store.setArmedKey(null, synchronous = true)
    tripped = leftover
  }
}
