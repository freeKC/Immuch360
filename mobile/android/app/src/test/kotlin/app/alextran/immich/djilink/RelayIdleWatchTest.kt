package app.alextran.immich.djilink

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A relay with nothing to send and no headset stops after 10 minutes (stage2b-review.md, finding 8) */
class RelayIdleWatchTest {
  private val minute = 60_000L

  @Test
  fun tenIdleMinutesInARowStopTheRelayOnce() {
    val watch = RelayIdleWatch(10 * minute)
    assertFalse(watch.expired(true, 0))
    assertFalse(watch.expired(true, 10 * minute - 1))
    assertTrue(watch.expired(true, 10 * minute))
    // Once only: the count starts again
    assertFalse(watch.expired(true, 10 * minute + 500))
  }

  @Test
  fun aSourceOrAHeadsetStartsTheCountAgain() {
    val watch = RelayIdleWatch(10 * minute)
    assertFalse(watch.expired(true, 0))
    assertFalse(watch.expired(false, 9 * minute))
    assertFalse(watch.expired(true, 9 * minute + 1))
    assertFalse(watch.expired(true, 18 * minute))
    assertTrue(watch.expired(true, 19 * minute + 1))
  }

  @Test
  fun aRestartedRelayCountsFromItsStart() {
    val watch = RelayIdleWatch(10 * minute)
    assertFalse(watch.expired(true, 0))
    watch.reset()
    assertFalse(watch.expired(true, 10 * minute))
    assertTrue(watch.expired(true, 20 * minute))
  }
}
