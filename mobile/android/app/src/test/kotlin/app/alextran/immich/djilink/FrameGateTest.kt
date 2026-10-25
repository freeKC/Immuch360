package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The values go to Flutter only when they change, ten times a second at most */
class FrameGateTest {
  @Test
  fun thirtyGroupsInOneSecondGiveAtMostTenFrames() {
    val gate = FrameGate<Long>(100) { a, b -> a == b }
    var sent = 0
    // The controller looks every 50 ms; the values change thirty times a second, as thirty decoded groups would
    for (at in 0L until 1_000L step 50L) {
      if (gate.offer(at / 33, at)) {
        sent += 1
      }
    }
    assertEquals(10, sent)
  }

  @Test
  fun aValueThatDoesNotChangeIsNotSentAgain() {
    val gate = FrameGate<Int>(100) { a, b -> a == b }
    assertTrue(gate.offer(1, 0))
    assertFalse(gate.offer(1, 500))
    assertTrue(gate.offer(2, 600))
    gate.reset()
    assertTrue(gate.offer(2, 610))
  }
}
