package app.alextran.immich.background

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundTeardownTest {
  /** The main looper of the tests: actions run when the clock passes their time */
  private class Clock {
    var now = 0L
      private set
    private val pending = mutableListOf<Pair<Long, () -> Unit>>()

    fun schedule(delayMs: Long, action: () -> Unit) {
      pending.add(now + delayMs to action)
    }

    fun advance(ms: Long) {
      val until = now + ms
      while (true) {
        val next = pending.filter { it.first <= until }.minByOrNull { it.first } ?: break
        pending.remove(next)
        now = next.first
        next.second()
      }
      now = until
    }
  }

  private val clock = Clock()
  private val slot = BackgroundEngineSlot()

  /** What the teardowns did, in order */
  private val events = mutableListOf<String>()

  private fun teardown(name: String = "run") =
    BackgroundTeardown<String>(
      slot = slot,
      schedule = clock::schedule,
      finishWork = { events.add("$name finished: $it") },
      destroyEngine = { events.add("$name destroyed") },
    )

  /** A run whose engine started, as when Dart is running */
  private fun running(name: String = "run") =
    teardown(name).apply {
      assertTrue(tryStart())
      engineStarted()
    }

  @Test
  fun `the answer of Dart before the timer finishes the work, then destroys the engine once`() {
    val run = running()

    assertTrue(run.cancel("failure"))
    clock.advance(1_000)
    run.dartAnswered()
    clock.advance(120_000)

    assertEquals(listOf("run finished: failure", "run destroyed"), events)
    assertFalse(slot.isHeld)
  }

  @Test
  fun `the timer finishes the work without destroying the engine, the later answer destroys it`() {
    val run = running()

    run.cancel("failure")
    clock.advance(BackgroundTeardown.FINISH_DELAY_MS)
    assertEquals(listOf("run finished: failure"), events)
    clock.advance(20_000)
    assertEquals(listOf("run finished: failure"), events)
    assertTrue(slot.isHeld)

    run.dartAnswered()

    assertEquals(listOf("run finished: failure", "run destroyed"), events)
    assertFalse(slot.isHeld)
  }

  @Test
  fun `without an answer the engine is destroyed at the cap`() {
    val run = running()

    run.cancel("failure")
    clock.advance(BackgroundTeardown.DESTROY_CAP_MS - 1)
    assertEquals(listOf("run finished: failure"), events)

    clock.advance(1)

    assertEquals(listOf("run finished: failure", "run destroyed"), events)
    assertFalse(slot.isHeld)
  }

  @Test
  fun `repeated answers, stops and timers finish and destroy once`() {
    val run = running()

    assertTrue(run.cancel("failure"))
    assertFalse(run.cancel("failure"))
    run.dartAnswered()
    run.dartAnswered()
    run.complete("success")
    clock.advance(120_000)

    assertEquals(listOf("run finished: failure", "run destroyed"), events)
  }

  @Test
  fun `a new start is refused while a teardown is pending`() {
    val first = running("first")
    first.cancel("failure")
    clock.advance(BackgroundTeardown.FINISH_DELAY_MS)
    // The work of the first run is finished, its engine is still alive
    assertTrue(first.isWorkFinished)

    assertFalse(teardown("second").tryStart())

    first.dartAnswered()
    assertTrue(teardown("third").tryStart())
  }

  @Test
  fun `a stop before the engine exists ends the run at once, with nothing to ask`() {
    val run = teardown()
    assertTrue(run.tryStart())

    assertFalse(run.cancel("failure"))

    assertTrue(run.isEnding)
    assertEquals(listOf("run finished: failure", "run destroyed"), events)
    assertFalse(slot.isHeld)
  }

  @Test
  fun `a run that ends by itself finishes the work, then destroys the engine`() {
    val run = running()

    run.complete("success")
    run.dartAnswered()
    clock.advance(120_000)

    assertEquals(listOf("run finished: success", "run destroyed"), events)
    assertFalse(slot.isHeld)
  }

  @Test
  fun `an answer without a cancel changes nothing`() {
    val run = running()

    run.dartAnswered()

    assertFalse(run.isEnding)
    assertTrue(events.isEmpty())
  }

  @Test
  fun `the slot comes back even when destroying the engine fails`() {
    val run =
      BackgroundTeardown<String>(
        slot = slot,
        schedule = clock::schedule,
        finishWork = {},
        destroyEngine = { throw IllegalStateException("engine") },
      )
    assertTrue(run.tryStart())

    runCatching { run.complete("success") }

    assertFalse(slot.isHeld)
    assertTrue(run.isEngineDestroyed)
  }
}
