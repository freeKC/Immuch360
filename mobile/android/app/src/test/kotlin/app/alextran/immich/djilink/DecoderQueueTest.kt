package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/** The queue in front of the decoder: its bound held by the producer, and no decoder thread after a shutdown */
class DecoderQueueTest {
  private class Worker(val number: Int)

  private val made = AtomicInteger()
  private fun make() = Worker(made.incrementAndGet())

  @Test
  fun theFirstUnitMakesTheWorkerAndTheNextOnesWakeTheSameOne() {
    val queue = DecoderQueue<String, Worker>(bound = 4)
    val first = queue.offer("a", ::make)!!
    assertSame(first, queue.offer("b", ::make))
    assertEquals(1, made.get())
    assertSame(first, queue.currentWorker)
    assertEquals("a", queue.peek())
  }

  @Test
  fun aClosedQueueTakesNothingAndMakesNoWorkerUntilItIsOpened() {
    val queue = DecoderQueue<String, Worker>(bound = 4)
    val worker = queue.offer("a", ::make)!!
    assertSame("the worker to shut down", worker, queue.close())
    assertTrue(queue.isClosed)
    assertNull(queue.currentWorker)
    assertEquals(0, queue.size)
    // A unit still on its way after the shutdown: dropped, and no thread made for it
    assertNull(queue.offer("late", ::make))
    assertEquals(1, made.get())
    assertEquals(0, queue.size)
    assertNull("a second shutdown has nothing to stop", queue.close())
    queue.open()
    assertFalse(queue.isClosed)
    assertEquals(2, queue.offer("next session", ::make)!!.number)
  }

  @Test
  fun theProducerHoldsTheBoundByDroppingTheOldestWholeUnitsAndAsksForAFlush() {
    val queue = DecoderQueue<Int, Worker>(bound = 15)
    // A decoder thread stuck in a vendor call takes nothing: the queue must not grow past its bound
    for (unit in 1..1000) {
      queue.offer(unit, ::make)
      assertTrue(queue.size <= 15)
    }
    assertEquals(15, queue.size)
    assertEquals(985L, queue.droppedUnits)
    assertEquals("the newest units stay, oldest first", 986, queue.peek())
    // The decoder thread, once free, flushes and the units still waiting go too
    assertTrue(queue.takeFlush())
    assertEquals(0, queue.size)
    assertEquals(1000L, queue.droppedUnits)
    assertFalse("one flush per overflow", queue.takeFlush())
    queue.offer(1001, ::make)
    assertEquals(1001, queue.peek())
  }

  @Test
  fun belowTheBoundNothingIsDroppedAndNoFlushIsAsked() {
    val queue = DecoderQueue<Int, Worker>(bound = 15)
    repeat(15) { queue.offer(it, ::make) }
    assertEquals(15, queue.size)
    assertEquals(0L, queue.droppedUnits)
    assertFalse(queue.takeFlush())
  }

  @Test
  fun theDecoderThreadTakesOutOnlyTheUnitItPeeked() {
    val queue = DecoderQueue<String, Worker>(bound = 2)
    queue.offer("a", ::make)
    val peeked = queue.peek()!!
    // Meanwhile the producer passes the bound and drops "a"
    queue.offer("b", ::make)
    queue.offer("c", ::make)
    assertEquals("b", queue.peek())
    queue.remove(peeked)
    assertEquals("a unit dropped meanwhile does not take another one with it", "b", queue.peek())
    queue.remove("b")
    assertEquals("c", queue.peek())
  }

  @Test
  fun aNewSourceEmptiesTheQueueAndStartsTheCountAgain() {
    val queue = DecoderQueue<Int, Worker>(bound = 2)
    repeat(5) { queue.offer(it, ::make) }
    assertEquals(3L, queue.droppedUnits)
    queue.clear()
    assertEquals(0, queue.size)
    assertEquals(0L, queue.droppedUnits)
    assertFalse(queue.takeFlush())
    assertTrue("a new source does not close the queue", queue.offer(9, ::make) != null)
  }

  /** A unit for the safety net: its arrival, its size, and whether it is a key unit */
  private data class Item(val name: String, val bornNs: Long, val size: Int = 1_000, val key: Boolean = false)

  private fun paced() = DecoderQueue<Item, Worker>(
    bound = 15,
    sizeOf = { it.size },
    bornNs = { it.bornNs },
    isKey = { it.key },
  ).apply { net = DecoderQueue.Net(maxAgeNs = 5_000_000_000L, maxBytes = 16L * 1024 * 1024, maxUnits = 600) }

  /**
   * A paced reception (p2/review-relay-2026-10-25.md M2): far past the plain bound nothing goes; past 5 s every unit
   * but the newest goes, no flush is asked, and the decoder thread learns it once
   */
  @Test
  fun theSafetyNetOfAPacedReceptionDropsWithoutAFlush() {
    val queue = paced()
    val second = 1_000_000_000L
    for (index in 0 until 290) {
      queue.offer(Item("p$index", index * second / 60), index * second / 60, ::make)
    }
    assertEquals("4.8 s queued, far over 15 units: all kept", 290, queue.size)
    assertFalse(queue.takeNet())
    queue.offer(Item("late", 5_100_000_000L), 5_100_000_000L, ::make)
    assertEquals(listOf("late"), generateSequence { queue.peek()?.also { queue.remove(it) } }.map { it.name }.toList())
    assertEquals(290L, queue.droppedUnits)
    assertTrue(queue.takeNet())
    assertFalse("once", queue.takeNet())
    assertFalse("no flush of the decoder", queue.takeFlush())
    assertEquals(0L, queue.queuedBytes)
  }

  /** When a key unit is queued, only the units before it go; when it is the oldest, it stays with the newest unit */
  @Test
  fun theSafetyNetGoesBackToAKeyUnitQueued() {
    val second = 1_000_000_000L
    val queue = paced()
    queue.offer(Item("p0", 0), 0, ::make)
    queue.offer(Item("p1", second), second, ::make)
    queue.offer(Item("key", 2 * second, key = true), 2 * second, ::make)
    queue.offer(Item("p3", 3 * second), 3 * second, ::make)
    queue.offer(Item("p4", 5_500_000_000L), 5_500_000_000L, ::make)
    assertEquals(listOf("key", "p3", "p4"), names(queue))
    assertTrue(queue.takeNet())
    val first = paced()
    first.offer(Item("key", 0, key = true), 0, ::make)
    first.offer(Item("p1", second), second, ::make)
    first.offer(Item("p2", 6 * second), 6 * second, ::make)
    assertEquals(listOf("key", "p2"), names(first))
    // By the bytes too: 16 MiB
    val heavy = paced()
    repeat(5) { heavy.offer(Item("big$it", 0, size = 4 * 1024 * 1024), 0, ::make) }
    assertEquals(listOf("big4"), names(heavy))
  }

  private fun names(queue: DecoderQueue<Item, Worker>): List<String> =
    generateSequence { queue.peek()?.also { queue.remove(it) } }.map { it.name }.toList()

  @Test
  fun noWorkerIsEverMadeAfterTheShutdownWhateverTheThreads() {
    repeat(50) {
      val queue = DecoderQueue<Int, Worker>(bound = 15)
      val makes = AtomicInteger()
      val start = CountDownLatch(1)
      val closedAt = AtomicInteger(-1)
      val madeAfterClose = AtomicInteger()
      val producers = (1..4).map { producer ->
        thread {
          start.await()
          repeat(2_000) { unit ->
            queue.offer(producer * 10_000 + unit) {
              makes.incrementAndGet()
              if (closedAt.get() >= 0) madeAfterClose.incrementAndGet()
              Worker(makes.get())
            }
          }
        }
      }
      start.countDown()
      Thread.sleep(1)
      // The closing thread marks the shutdown under nothing but its own order: what matters is the queue's lock
      val stopped = queue.close()
      closedAt.set(1)
      producers.forEach { it.join() }
      assertTrue(makes.get() <= 1)
      assertEquals("a worker made after the shutdown would never be stopped", 0, madeAfterClose.get())
      assertEquals("the worker made, if any, is the one the shutdown stopped", makes.get(), if (stopped == null) 0 else 1)
      assertNull(queue.currentWorker)
      assertEquals(0, queue.size)
    }
  }
}
