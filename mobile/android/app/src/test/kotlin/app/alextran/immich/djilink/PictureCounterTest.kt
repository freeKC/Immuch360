package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Test

/** Lost pictures and encoder restarts from the picture counter of SEI 240 */
class PictureCounterTest {
  @Test
  fun stepsOfOneLoseNothing() {
    val tracker = PictureCounterTracker()
    (2246..2275).forEach { tracker.offer(it) }
    assertEquals(30L, tracker.counters)
    assertEquals(29L, tracker.steps)
    assertEquals(0L, tracker.lost)
    assertEquals(0L, tracker.restarts)
  }

  @Test
  fun aStepOfKCountsKMinusOneLostPictures() {
    val tracker = PictureCounterTracker()
    tracker.offer(10)
    tracker.offer(14)
    assertEquals(3L, tracker.lost)
    tracker.offer(15 + PictureCounterTracker.MAX_LOSS_STEP - 1)
    assertEquals(3L + PictureCounterTracker.MAX_LOSS_STEP - 1, tracker.lost)
  }

  @Test
  fun aResetCountsARestartAndNoLoss() {
    val tracker = PictureCounterTracker()
    tracker.offer(2275)
    tracker.offer(1)
    tracker.offer(2)
    assertEquals(1L, tracker.restarts)
    assertEquals(0L, tracker.lost)
    assertEquals(1L, tracker.steps)
  }

  @Test
  fun theSixteenBitCounterWrapsAsAStepOfOne() {
    val tracker = PictureCounterTracker()
    tracker.offer(65535)
    tracker.offer(0)
    assertEquals(1L, tracker.steps)
    assertEquals(0L, tracker.restarts)
  }

  @Test
  fun aNewStreamDoesNotCountTheJumpToItsFirstPicture() {
    val tracker = PictureCounterTracker()
    tracker.offer(100)
    tracker.newStream()
    tracker.offer(5)
    assertEquals(0L, tracker.restarts)
    assertEquals(0L, tracker.lost)
    assertEquals(2L, tracker.counters)
  }
}
