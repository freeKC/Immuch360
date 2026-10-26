package app.alextran.immich.djilink

import app.alextran.immich.djilink.PermissionPolicy.Decision
import app.alextran.immich.djilink.PermissionPolicy.Trigger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * When the USB permission may be asked for. A pilot who refuses must not get the dialog back at once, a plug that
 * fires several broadcasts must not stack dialogs, and the system chooser of a fresh plug gets its chance first.
 */
class PermissionPolicyTest {
  private val remote = "DJI|com.dji.logiclink|1.0|serial"
  private val policy = PermissionPolicy()

  /** Carries out a decision the way the manager does, and says whether a dialog was opened */
  private fun attempt(trigger: Trigger, nowMs: Long, held: Boolean = false, key: String = remote): Decision {
    val decision = policy.decide(key, held, trigger, nowMs)
    if (decision == Decision.Ask) {
      policy.onAsked(nowMs)
    }
    return decision
  }

  @Test
  fun aRemotePluggedBeforeThePageOpenedIsAskedForOnce() {
    assertEquals(Decision.Ask, attempt(Trigger.START, 2_000))
    assertTrue(policy.pending)
    // Whatever arrives while the dialog is up asks nothing
    for (trigger in listOf(Trigger.USB_STATE, Trigger.PERIODIC, Trigger.START, Trigger.PILOT)) {
      assertEquals(Decision.Pending, attempt(trigger, 3_000))
    }
  }

  @Test
  fun aPlugWithSeveralBroadcastsOpensOneDialogAfterTheChoosersTurn() {
    var dialogs = 0
    var now = 10_000L
    // The plug: a burst of USB state broadcasts, each one an attempt
    repeat(6) {
      val decision = attempt(Trigger.USB_STATE, now)
      assertTrue("the chooser is left alone first", decision is Decision.Grace)
      now += 150
    }
    val waited = (policy.decide(remote, false, Trigger.USB_STATE, now) as Decision.Grace).waitMs
    now += waited
    if (attempt(Trigger.PERIODIC, now) == Decision.Ask) dialogs += 1
    repeat(10) {
      now += 300
      if (attempt(Trigger.USB_STATE, now) == Decision.Ask) dialogs += 1
    }
    assertEquals(1, dialogs)
  }

  @Test
  fun aRefusalIsShownAndNotAskedAgainByTheLink() {
    assertEquals(Decision.Ask, attempt(Trigger.START, 0))
    policy.onResult(granted = false)
    assertFalse(policy.pending)
    // The answer itself, every broadcast and every periodic attempt: the refusal stands
    for (trigger in listOf(Trigger.PERMISSION_RESULT, Trigger.USB_STATE, Trigger.PERIODIC, Trigger.START)) {
      assertEquals(Decision.Refused, attempt(trigger, 60_000))
    }
  }

  @Test
  fun theRetryButtonAsksAgainAfterARefusal() {
    attempt(Trigger.START, 0)
    policy.onResult(granted = false)
    assertEquals(Decision.Ask, attempt(Trigger.PILOT, 5_000))
    assertTrue(policy.pending)
  }

  @Test
  fun choosingThisApplicationInTheChooserOpensAtOnce() {
    attempt(Trigger.START, 0)
    policy.onResult(granted = false)
    // The chooser hands the permission over: held, whatever was refused before
    assertEquals(Decision.Open, attempt(Trigger.ATTACH_ENTRY, 1_000, held = true))
    assertFalse(policy.pending)
  }

  @Test
  fun aNewPlugStartsAfresh() {
    attempt(Trigger.START, 0)
    policy.onResult(granted = false)
    // Unplugged, then plugged in again while the page is open
    policy.onGone()
    assertTrue(attempt(Trigger.USB_STATE, 20_000) is Decision.Grace)
    assertEquals(Decision.Ask, attempt(Trigger.PERIODIC, 20_000 + PermissionPolicy.GRACE_MS))
  }

  @Test
  fun anotherAccessoryIsNotRefusedBecauseTheFirstWas() {
    attempt(Trigger.START, 0)
    policy.onResult(granted = false)
    assertEquals(Decision.Ask, attempt(Trigger.START, 1_000, key = "DJI|com.dji.somethingnew|2.0|other"))
  }

  @Test
  fun aHeldPermissionAlwaysOpens() {
    assertEquals(Decision.Open, attempt(Trigger.USB_STATE, 0, held = true))
    assertEquals(Decision.Open, attempt(Trigger.PERIODIC, 100, held = true))
  }

  @Test
  fun aGrantOpens() {
    attempt(Trigger.START, 0)
    policy.onResult(granted = true)
    assertEquals(Decision.Open, attempt(Trigger.PERMISSION_RESULT, 500, held = true))
  }

  @Test
  fun aDialogLeftUnansweredMayBeAskedAgainByThePilotOnly() {
    attempt(Trigger.START, 0)
    val stale = PermissionPolicy.STALE_MS
    assertEquals(Decision.Pending, attempt(Trigger.PILOT, stale - 1))
    assertEquals(Decision.Pending, attempt(Trigger.USB_STATE, stale + 1))
    assertEquals(Decision.Pending, attempt(Trigger.PERIODIC, stale + 1))
    assertEquals(Decision.Ask, attempt(Trigger.PILOT, stale + 1))
  }

  @Test
  fun aRequestThatCouldNotBeMadeIsNotPending() {
    assertEquals(Decision.Ask, policy.decide(remote, false, Trigger.START, 0))
    policy.onAskFailed()
    assertFalse(policy.pending)
    assertEquals(Decision.Ask, policy.decide(remote, false, Trigger.PERIODIC, PermissionPolicy.GRACE_MS))
  }
}
