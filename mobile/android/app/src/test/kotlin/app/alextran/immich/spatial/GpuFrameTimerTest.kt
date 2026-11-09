package app.alextran.immich.spatial

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The GPU frame timer of the Spatial 2.5D renderer over a fake GL that records every call. The regression test of
 * Play cluster 7b656f (build 25 crashed in libGLES_mali.so under glGetQueryObjectuiv) is the first one: on a Mali
 * GPU, the timer makes no query call at all.
 */
class GpuFrameTimerTest {
  /** Records each call in [events]; [errorOn] and [throwOn] make the named call fail */
  private class FakeGl(private val events: MutableList<String>) : TimerGl {
    var nextName = 1
    var available = true
    var nanos = 5_000_000L
    var disjointOnce = false
    var errorOn: String? = null
    var throwOn: String? = null
    private val errors = ArrayDeque<Int>()

    override fun genQueries(ids: IntArray) {
      record("gen")
      for (index in ids.indices) ids[index] = nextName++
    }

    override fun deleteQueries(ids: IntArray) = record("delete ${ids.joinToString(",")}")

    override fun beginQuery(id: Int) = record("begin $id")

    override fun endQuery() = record("end")

    override fun resultAvailable(id: Int): Boolean {
      record("available $id")
      return available
    }

    override fun result(id: Int): Long {
      record("result $id")
      return nanos
    }

    override fun disjoint(): Boolean {
      record("disjoint")
      val disjoint = disjointOnce
      disjointOnce = false
      return disjoint
    }

    override fun finish() = record("finish")

    override fun error(): Int {
      record("error")
      return errors.removeFirstOrNull() ?: 0
    }

    private fun record(call: String) {
      events.add(call)
      val name = call.substringBefore(' ')
      if (name == throwOn) throw IllegalStateException("the driver refused $name")
      if (name == errorOn) {
        errorOn = null
        errors.addLast(GL_INVALID_OPERATION)
      }
    }
  }

  /** The guard's disk, writing into the same [events] as the GL */
  private class EventStore(private val events: MutableList<String>) : GpuTimerGuardStore {
    var armed: String? = null

    override fun armedKey(): String? = armed

    override fun setArmedKey(key: String?, synchronous: Boolean) {
      armed = key
      events.add(if (key == null) "disarm" else "arm $key")
    }

    override fun badKeys(): List<String> = emptyList()

    override fun setBadKeys(keys: List<String>) = Unit
  }

  private val events = mutableListOf<String>()
  private val gl = FakeGl(events)
  private val store = EventStore(events)
  private val logs = mutableListOf<String>()
  private val samples = mutableListOf<Float>()
  private val timer = GpuFrameTimer(gl, GpuTimerCrashGuard(store)) { logs.add(it) }

  /** One frame as the renderer draws it: read the finished queries, then time the passes */
  private fun frame() {
    timer.collect { samples.add(it) }
    timer.begin()
    timer.end()
  }

  private fun count(prefix: String) = events.count { it.startsWith(prefix) }

  @Test
  fun `ARM_MALI and the other refusals make no query call over 1000 frames`() {
    val refusals = GpuTimerVerdict.entries.filterNot { it.allowed }
    assertTrue(GpuTimerVerdict.ARM_MALI in refusals && GpuTimerVerdict.NO_EXTENSION in refusals)
    for (verdict in refusals) {
      timer.start(verdict, KEY)
      assertEquals("CPU (${verdict.reason})", timer.timing)
      repeat(1000) { index ->
        frame()
        // What the renderer does around the frames: resizes, tier changes, stops
        if (index % 100 == 0) timer.voidPending()
        if (index % 150 == 0) timer.settleBeforeDelete()
        if (index % 400 == 0) timer.onPaused()
      }
      assertFalse(timer.active)
      timer.release()
      assertEquals("$verdict: no GL call, not even glGetError", emptyList<String>(), events)
      assertNull("$verdict: the guard was never armed", store.armed)
      assertTrue(samples.isEmpty())
    }
  }

  @Test
  fun `an allowed driver times the frames with four queries in turn`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    assertTrue(timer.active)
    assertEquals(GpuFrameTimer.GPU, timer.timing)
    repeat(6) { frame() }
    assertEquals(listOf("begin 1", "begin 2", "begin 3", "begin 4", "begin 1", "begin 2"), events.filter {
      it.startsWith("begin")
    })
    assertEquals(5, samples.size)
    assertTrue(samples.all { it == 5f })
  }

  @Test
  fun `an error after the first begin turns the timer off and deletes the names`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    gl.errorOn = "begin"
    frame()
    assertFalse(timer.active)
    assertEquals("CPU (GPU timer failed)", timer.timing)
    assertEquals(1, count("delete 1,2,3,4"))
    assertEquals(1, logs.size)
    val before = events.size
    repeat(100) { frame() }
    assertEquals("no call once off", before, events.size)
  }

  @Test
  fun `an error of end or of a result read turns the timer off`() {
    for (failing in listOf("end", "available", "result", "disjoint")) {
      events.clear()
      timer.start(GpuTimerVerdict.ALLOWED, KEY)
      gl.errorOn = failing
      repeat(3) { frame() }
      assertFalse(failing, timer.active)
      assertEquals(failing, 1, events.count { it.startsWith("delete") })
    }
  }

  @Test
  fun `an exception of result or available never leaves collect`() {
    for (failing in listOf("result", "available", "disjoint", "begin", "end", "gen")) {
      events.clear()
      gl.throwOn = failing
      timer.start(GpuTimerVerdict.ALLOWED, KEY)
      repeat(5) { frame() }
      gl.throwOn = null
      assertFalse(failing, timer.active)
      assertEquals(failing, 1, events.count { it.startsWith("delete") })
      assertTrue(failing, samples.isEmpty())
    }
  }

  @Test
  fun `a disjoint frame drops its samples and the queries in flight`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    timer.begin()
    timer.end()
    timer.begin()
    timer.end()
    gl.available = false
    timer.collect { samples.add(it) }
    gl.available = true
    gl.disjointOnce = true
    timer.collect { samples.add(it) }
    assertTrue(samples.isEmpty())
    val reads = count("result")
    timer.collect { samples.add(it) }
    assertEquals("nothing left in flight", reads, count("result"))
    frame()
    frame()
    assertEquals(listOf(5f), samples)
  }

  @Test
  fun `with four pending slots there is no new begin`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    gl.available = false
    repeat(10) { frame() }
    assertEquals(GpuFrameTimer.SLOTS, count("begin"))
    assertTrue(timer.active)
    gl.available = true
    frame()
    assertEquals(GpuFrameTimer.SLOTS, samples.size)
    assertEquals(GpuFrameTimer.SLOTS + 1, count("begin"))
  }

  @Test
  fun `voidPending means nothing is read`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    timer.begin()
    timer.end()
    timer.voidPending()
    val before = events.size
    timer.collect { samples.add(it) }
    assertEquals(before, events.size)
    assertTrue(samples.isEmpty())
  }

  @Test
  fun `settleBeforeDelete ends the active query, finishes, then reads nothing`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    gl.available = false
    frame()
    timer.collect { samples.add(it) }
    timer.begin()
    val mark = events.size
    timer.settleBeforeDelete()
    assertEquals(listOf("end", "finish"), events.drop(mark))
    // The frame goes on: its end has nothing left to end, and nothing pending is read
    timer.end()
    gl.available = true
    timer.collect { samples.add(it) }
    assertEquals(listOf("end", "finish"), events.drop(mark))
    assertTrue(samples.isEmpty())
    assertTrue(timer.active)
  }

  @Test
  fun `settleBeforeDelete does nothing without a query in flight`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    val mark = events.size
    timer.settleBeforeDelete()
    assertEquals(mark, events.size)
  }

  @Test
  fun `forget deletes nothing and start generates again`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    repeat(3) { frame() }
    timer.forget()
    assertFalse(timer.active)
    assertEquals(0, count("delete"))
    // A new context: the names of the old one are never used again
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    assertEquals(2, count("gen"))
    val mark = events.size
    frame()
    assertEquals("begin 5", events.drop(mark).first { it.startsWith("begin") })
  }

  @Test
  fun `a context that never starts the timer makes no query call with the old names`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    repeat(3) { frame() }
    // onSurfaceCreated forgets everything first, then returns early when no eye program builds
    timer.forget()
    val mark = events.size
    repeat(100) { frame() }
    timer.voidPending()
    timer.settleBeforeDelete()
    assertEquals(mark, events.size)
  }

  @Test
  fun `the guard is armed before the first query and the first availability read`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    repeat(3) { frame() }
    val arm = events.indexOf("arm $KEY")
    assertTrue(arm >= 0)
    assertTrue(arm < events.indexOfFirst { it.startsWith("begin") })
    assertTrue(arm < events.indexOfFirst { it.startsWith("available") })
    assertEquals("armed once", 1, count("arm"))
  }

  @Test
  fun `release deletes the names and disarms the guard`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    repeat(3) { frame() }
    timer.release()
    assertEquals(1, count("delete 1,2,3,4"))
    assertEquals("disarm", events.last())
    assertNull(store.armed)
    assertFalse(timer.active)
  }

  @Test
  fun `onPaused disarms the guard and the next frame arms it again`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    repeat(3) { frame() }
    timer.onPaused()
    assertNull(store.armed)
    assertEquals(0, count("delete"))
    frame()
    assertEquals(KEY, store.armed)
    assertEquals(2, count("arm"))
  }

  @Test
  fun `glGetError is read during the first 60 timed frames only`() {
    timer.start(GpuTimerVerdict.ALLOWED, KEY)
    repeat(GpuFrameTimer.CHECKED_FRAMES) { frame() }
    assertTrue(count("error") > 0)
    repeat(5) { frame() }
    val mark = events.size
    repeat(10) { frame() }
    assertEquals(0, events.drop(mark).count { it == "error" })
    assertTrue(events.drop(mark).any { it.startsWith("result") })
  }

  private companion object {
    const val KEY = "Adreno (TM) 619 | OpenGL ES 3.2 V@0502.0"
    const val GL_INVALID_OPERATION = 0x0502
  }
}
