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
