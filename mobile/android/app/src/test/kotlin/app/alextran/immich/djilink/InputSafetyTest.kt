package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The rules that would stand between a controller and an aircraft. They are tested now, at a stage where nothing can
 * be sent at all, because they have to be older than the first byte they guard.
 */
class InputSafetyTest {
  private val safety = InputSafety()

  private fun held(nowMs: Long) = StickSample(throttle = 0.4, triggersHeld = true, atMs = nowMs)

  @Test
  fun theSendPathIsOffInThisBuild() {
    assertFalse(DjiLinkBuild.SEND_ENABLED)
  }

  @Test
  fun noSampleMeansNeutral() {
    val decision = safety.evaluate(null, emptySet(), 1000)
    assertTrue(decision.neutralised)
    assertFalse(decision.armed)
    assertTrue(decision.reasons.contains(DeadManSignal.SAMPLE_TOO_OLD))
    assertEquals(0.0, decision.sample.throttle, 0.0)
  }

  @Test
  fun anOldSampleIsNoSample() {
    val sample = held(1000)
    val decision = safety.evaluate(sample, emptySet(), 1000 + InputSafety.MAX_SAMPLE_AGE_MS + 1)
    assertTrue(decision.reasons.contains(DeadManSignal.SAMPLE_TOO_OLD))
    assertEquals(0.0, decision.sample.throttle, 0.0)
  }

  @Test
  fun armingNeedsTheButtonAndTheHold() {
    var now = 0L
    // The triggers alone arm nothing
    repeat(5) {
      now += 500
      assertFalse(safety.evaluate(held(now), emptySet(), now).armed)
    }
    safety.requestControl()
    now += 100
    safety.evaluate(held(now), emptySet(), now)
    val afterHold = now + InputSafety.ARM_HOLD_MS
    val decision = safety.evaluate(held(afterHold), emptySet(), afterHold)
    assertTrue(decision.armed)
    assertFalse(decision.neutralised)
    assertEquals(0.4, decision.sample.throttle, 1e-9)
  }

  @Test
  fun releasingATriggerDisarmsAtOnceAndReturnsToNeutral() {
    var now = 0L
    safety.requestControl()
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS
    assertTrue(safety.evaluate(held(now), emptySet(), now).armed)
    now += 20
    val released = safety.evaluate(StickSample(throttle = 0.9, triggersHeld = false, atMs = now), emptySet(), now)
    assertFalse(released.armed)
    assertTrue(released.neutralised)
    assertEquals(0.0, released.sample.throttle, 0.0)
    assertTrue(released.reasons.contains(DeadManSignal.TRIGGERS_RELEASED))
  }

  @Test
  fun everyDeadManSignalNeutralises() {
    for (signal in DeadManSignal.entries) {
      val fresh = InputSafety()
      fresh.requestControl()
      var now = 0L
      fresh.evaluate(held(now), emptySet(), now)
      now += InputSafety.ARM_HOLD_MS
      assertTrue(fresh.evaluate(held(now), emptySet(), now).armed)
      now += 20
      val decision = fresh.evaluate(held(now), setOf(signal), now)
      assertFalse("$signal must disarm", decision.armed)
      assertTrue(decision.neutralised)
      assertEquals(0.0, decision.sample.roll, 0.0)
    }
  }

  @Test
  fun nothingMaySendWhileTheBuildSwitchIsOff() {
    var now = 0L
    safety.requestControl()
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS
    val decision = safety.evaluate(held(now), emptySet(), now)
    assertTrue(decision.armed)
    assertFalse(safety.maySend(decision, now))
  }

  @Test
  fun theArmingCountdownRunsDown() {
    var now = 1000L
    safety.requestControl()
    safety.evaluate(held(now), emptySet(), now)
    assertEquals(InputSafety.ARM_HOLD_MS, safety.armingCountdownMs(now))
    now += 500
    assertEquals(InputSafety.ARM_HOLD_MS - 500, safety.armingCountdownMs(now))
  }
}
