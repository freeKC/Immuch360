package app.alextran.immich.spatial

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The crash guard of the GPU timers: each new [GpuTimerCrashGuard] over the same store stands for a new process */
class GpuTimerCrashGuardTest {
  /** The disk: what each write left, and the list of the writes */
  private class MemoryStore : GpuTimerGuardStore {
    var armed: String? = null
    var bad: List<String> = emptyList()
    val writes = mutableListOf<String>()

    /** How Android says the process that armed the key ended; it says nothing by default, as before Android 11 */
    var end = ArmedProcessEnd.UNKNOWN

    override fun armedKey(): String? = armed

    override fun setArmedKey(key: String?, synchronous: Boolean) {
      armed = key
      writes.add("armed $key ${if (synchronous) "now" else "later"}")
    }

    override fun badKeys(): List<String> = bad

    override fun setBadKeys(keys: List<String>) {
      bad = keys.toList()
      writes.add("bad ${keys.size}")
    }

    override fun armedProcessEnd(): ArmedProcessEnd = end
  }

  private val store = MemoryStore()

  private fun process() = GpuTimerCrashGuard(store)

  @Test
  fun `a fresh store blocks nothing`() {
    val guard = process()
    assertFalse(guard.blocked(KEY))
    assertNull(guard.takeTripped())
    assertTrue(store.writes.isEmpty())
  }

  @Test
  fun `a process that dies armed blocks that key in the next one and no other`() {
    process().arm(KEY)
    // The process dies here: no disarm
    val next = process()
    assertTrue(next.blocked(KEY))
    assertFalse(next.blocked(OTHER_KEY))
    assertEquals(KEY, next.takeTripped())
    assertNull("the notice is given once", next.takeTripped())
    assertNull("the leftover is cleared once moved", store.armed)
  }

  @Test
  fun `a process that crashed armed blocks that key in the next one`() {
    process().arm(KEY)
    store.end = ArmedProcessEnd.CRASH
    val next = process()
    assertTrue(next.blocked(KEY))
    assertEquals(KEY, next.takeTripped())
    assertEquals(listOf(KEY), store.bad)
  }

  @Test
  fun `a process ended by the user or the system clears the key, blocks nothing and says nothing`() {
    // A swipe from the recent apps or a force stop while the player is visible: no onStop, so no disarm
    process().arm(KEY)
    store.end = ArmedProcessEnd.OTHER
    val next = process()
    assertFalse(next.blocked(KEY))
    assertNull("no notice on the Logs page", next.takeTripped())
    assertNull("the leftover is cleared", store.armed)
    assertTrue(store.bad.isEmpty())
    store.end = ArmedProcessEnd.UNKNOWN
    assertFalse("cleared for the later processes too", process().blocked(KEY))
  }

  @Test
  fun `arm then disarm blocks nothing`() {
    val first = process()
    first.arm(KEY)
    first.disarm()
    val next = process()
    assertFalse(next.blocked(KEY))
    assertNull(next.takeTripped())
  }

  @Test
  fun `a blocked key stays blocked in the later processes`() {
    process().arm(KEY)
    assertTrue(process().blocked(KEY))
    assertTrue(process().blocked(KEY))
    assertTrue(process().blocked(KEY))
    assertEquals(listOf(KEY), store.bad)
  }

  @Test
  fun `a new driver key gets a new chance`() {
    process().arm(KEY)
    val next = process()
    assertTrue(next.blocked(KEY))
    assertFalse(next.blocked(UPDATED_KEY))
  }

  @Test
  fun `arm writes the key synchronously, once per armed period`() {
    val guard = process()
    guard.arm(KEY)
    assertEquals(KEY, store.armed)
    assertEquals(listOf("armed $KEY now"), store.writes)
    guard.arm(KEY)
    assertEquals("no second write while armed", 1, store.writes.size)
    guard.disarm()
    assertEquals("armed null later", store.writes.last())
    guard.arm(KEY)
    assertEquals("armed $KEY now", store.writes.last())
  }

  @Test
  fun `disarm before the check keeps the leftover of the previous process`() {
    process().arm(KEY)
    val next = process()
    // The activity stopped before any GL context of this process: nothing of this process to clear
    next.disarm()
    assertTrue(next.blocked(KEY))
  }

  @Test
  fun `at most 8 keys are kept, the oldest dropped`() {
    val keys = (0 until 10).map { "Renderer $it | OpenGL ES 3.2" }
    for (key in keys) process().arm(key)
    val last = process()
    assertEquals(GpuTimerCrashGuard.MAX_BAD_KEYS, store.bad.size)
    assertFalse(last.blocked(keys[0]))
    assertFalse(last.blocked(keys[1]))
    for (key in keys.drop(2)) assertTrue(key, last.blocked(key))
  }

  @Test
  fun `a key that trips again is kept once`() {
    process().arm(KEY)
    process().arm(KEY)
    process().arm(KEY)
    process().blocked(KEY)
    assertEquals(listOf(KEY), store.bad)
  }

  private companion object {
    const val KEY = "Adreno (TM) 619 | OpenGL ES 3.2 V@0502.0"
    const val UPDATED_KEY = "Adreno (TM) 619 | OpenGL ES 3.2 V@0615.0"
    const val OTHER_KEY = "Adreno (TM) 740 | OpenGL ES 3.2 V@0502.0"
  }
}
