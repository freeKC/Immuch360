package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The offset of the phone's clock on the headset's, from the pings (design 9.2) */
class ClockOffsetTest {
  private val ms = 1_000_000L

  /** A ping at headset time [t0] to a phone whose clock is [offset] ahead, [up] ms there and [down] ms back */
  private fun ClockOffset.ping(t0: Long, offset: Long, up: Long, down: Long, held: Long = 1) {
    val p1 = t0 + up * ms + offset
    val p2 = p1 + held * ms
    val t3 = p2 - offset + down * ms
    onPong(t0, p1, p2, t3)
  }

  @Test
  fun symmetricDelaysGiveTheExactOffset() {
    val clock = ClockOffset()
    val offset = 123_456_789_000L
    clock.ping(1_000 * ms, offset, 4, 4)
    clock.ping(1_500 * ms, offset, 4, 4)
    assertFalse("three pongs are needed", clock.ready)
    assertNull(clock.offsetNs)
    clock.ping(2_000 * ms, offset, 4, 4)
    assertTrue(clock.ready)
    assertEquals(offset, clock.offsetNs)
    assertEquals(4 * ms, clock.uncertaintyNs)
    assertEquals(10 * ms + offset, clock.toPhone(10 * ms))
  }

  @Test
  fun asymmetricDelaysStayWithinHalfTheRoundTrip() {
    val clock = ClockOffset()
    val offset = -5_000 * ms
    clock.ping(0, offset, 2, 10)
    clock.ping(500 * ms, offset, 9, 3)
    clock.ping(1_000 * ms, offset, 12, 12)
    val error = clock.offsetNs!! - offset
    assertTrue(kotlin.math.abs(error) <= clock.uncertaintyNs!!)
    // The least round trip wins: 2 + 10 = 12 and 9 + 3 = 12 against 24
    assertEquals(6 * ms, clock.uncertaintyNs)
  }

  @Test
  fun theLeastRoundTripWins() {
    val clock = ClockOffset()
    val offset = 77 * ms
    clock.ping(0, offset, 30, 1)
    clock.ping(500 * ms, offset, 1, 1)
    clock.ping(1_000 * ms, offset, 20, 40)
    assertEquals(offset, clock.offsetNs)
    assertEquals(1 * ms, clock.uncertaintyNs)
  }

  @Test
  fun anOldWindowIsForgotten() {
    val clock = ClockOffset(keep = 20)
    clock.ping(0, 0, 1, 1)
    // Twenty later pings of a longer round trip push the best one out
    for (index in 1..20) {
      clock.ping(index * 500 * ms, 50 * ms, 10, 10)
    }
    assertEquals(50 * ms, clock.offsetNs)
    assertEquals(10 * ms, clock.uncertaintyNs)
  }

  @Test
  fun aPongWithClocksGoingBackwardsIsIgnored() {
    val clock = ClockOffset(readyAfter = 1)
    clock.onPong(10 * ms, 5 * ms, 4 * ms, 20 * ms)
    clock.onPong(10 * ms, 5 * ms, 6 * ms, 9 * ms)
    assertFalse(clock.ready)
    clock.reset()
    assertNull(clock.offsetNs)
  }
}
