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
    safety.requestControl(now)
    now += 100
    // The first reading after the button starts the hold; it does not arm
    assertFalse(safety.evaluate(held(now), emptySet(), now).armed)
    assertEquals(InputSafety.ARM_HOLD_MS, safety.armingCountdownMs(now))
    val justBefore = now + InputSafety.ARM_HOLD_MS - 1
    assertFalse(safety.evaluate(held(justBefore), emptySet(), justBefore).armed)
    val afterHold = now + InputSafety.ARM_HOLD_MS
    val decision = safety.evaluate(held(afterHold), emptySet(), afterHold)
    assertTrue(decision.armed)
    assertFalse(decision.neutralised)
    assertEquals(0.4, decision.sample.throttle, 1e-9)
  }

  @Test
  fun triggersHeldBeforeTheButtonCountForNothing() {
    var now = 0L
    // The triggers held for longer than the hold, with no button
    while (now <= InputSafety.ARM_HOLD_MS + 500) {
      assertFalse(safety.evaluate(held(now), emptySet(), now).armed)
      assertEquals(null, safety.armingCountdownMs(now))
      now += 10
    }
    safety.requestControl(now)
    now += 10
    assertFalse("the reading right after the button must not arm", safety.evaluate(held(now), emptySet(), now).armed)
    val buttonPlusHold = now + InputSafety.ARM_HOLD_MS
    while (now < buttonPlusHold) {
      now += 10
      val armed = safety.evaluate(held(now), emptySet(), now).armed
      assertEquals(now >= buttonPlusHold, armed)
    }
  }

  @Test
  fun aDeadManTripNeedsTheButtonAgain() {
    var now = 0L
    safety.requestControl(now)
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS
    assertTrue(safety.evaluate(held(now), emptySet(), now).armed)
    now += 20
    assertFalse(safety.evaluate(held(now), setOf(DeadManSignal.HEADSET_REMOVED), now).armed)
    assertFalse(safety.controlRequested)
    // The headset is back on and the triggers never left: holding them as long as anyone likes arms nothing
    val until = now + 3 * InputSafety.ARM_HOLD_MS
    while (now < until) {
      now += 20
      assertFalse(safety.evaluate(held(now), emptySet(), now).armed)
    }
    // The button again, then the full hold
    safety.requestControl(now)
    now += 20
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS
    assertTrue(safety.evaluate(held(now), emptySet(), now).armed)
  }

  @Test
  fun aReleaseDuringTheHoldNeedsTheButtonAgain() {
    var now = 0L
    safety.requestControl(now)
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS / 2
    safety.evaluate(StickSample(triggersHeld = false, atMs = now), emptySet(), now)
    assertFalse(safety.controlRequested)
    now += 20
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS
    assertFalse(safety.evaluate(held(now), emptySet(), now).armed)
  }

  @Test
  fun theButtonMayComeBeforeTheTriggersAreSqueezed() {
    var now = 0L
    safety.requestControl(now)
    // Released at first: the press stands while the pilot reaches for the triggers
    now += 300
    safety.evaluate(StickSample(triggersHeld = false, atMs = now), emptySet(), now)
    assertTrue(safety.controlRequested)
    now += 300
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS
    assertTrue(safety.evaluate(held(now), emptySet(), now).armed)
  }

  @Test
  fun aButtonPressWithNoHoldLapses() {
    var now = 0L
    safety.requestControl(now)
    now += InputSafety.REQUEST_WINDOW_MS + 1
    safety.evaluate(held(now), emptySet(), now)
    assertFalse(safety.controlRequested)
    now += InputSafety.ARM_HOLD_MS
    assertFalse(safety.evaluate(held(now), emptySet(), now).armed)
  }

  @Test
  fun releasingATriggerDisarmsAtOnceAndReturnsToNeutral() {
    var now = 0L
    safety.requestControl(now)
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
      var now = 0L
      fresh.requestControl(now)
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
    safety.requestControl(now)
    safety.evaluate(held(now), emptySet(), now)
    now += InputSafety.ARM_HOLD_MS
    val decision = safety.evaluate(held(now), emptySet(), now)
    assertTrue(decision.armed)
    assertFalse(safety.maySend(decision, now))
  }

  @Test
  fun theArmingCountdownRunsDown() {
    var now = 1000L
    safety.requestControl(now)
    safety.evaluate(held(now), emptySet(), now)
    assertEquals(InputSafety.ARM_HOLD_MS, safety.armingCountdownMs(now))
    now += 500
    assertEquals(InputSafety.ARM_HOLD_MS - 500, safety.armingCountdownMs(now))
  }
}
