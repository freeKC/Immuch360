package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which application Android offers for a plugged DJI remote (p2/design-ux-phone-2026-10-24.md, 8.4) */
class AttachEntryPolicyTest {
  @Test
  fun aRunningLinkAlwaysKeepsTheEntry() {
    for (openOnPlug in listOf(false, true)) {
      for (settingOn in listOf(false, true)) {
        assertTrue(AttachEntryPolicy.enabled(linkRunning = true, openOnPlug = openOnPlug, settingOn = settingOn))
      }
    }
  }

  @Test
  fun withNoLinkTheEntryNeedsTheYesAndTheSetting() {
    assertTrue(AttachEntryPolicy.enabled(linkRunning = false, openOnPlug = true, settingOn = true))
    assertFalse(AttachEntryPolicy.enabled(linkRunning = false, openOnPlug = true, settingOn = false))
    assertFalse(AttachEntryPolicy.enabled(linkRunning = false, openOnPlug = false, settingOn = true))
    assertFalse(AttachEntryPolicy.enabled(linkRunning = false, openOnPlug = false, settingOn = false))
  }

  @Test
  fun aFreshInstallOffersNothingForTheCable() {
    val preferences = AttachEntryPreferences(MemoryKeyValueStore())
    assertFalse(preferences.openOnPlug)
    assertTrue(preferences.settingOn)
    assertFalse(preferences.entryEnabled(linkRunning = false))
    assertTrue(preferences.entryEnabled(linkRunning = true))
  }

  @Test
  fun theAnswersAreKeptAndTurningEitherOffDropsTheEntry() {
    val store = MemoryKeyValueStore()
    AttachEntryPreferences(store).openOnPlug = true
    // Read back by another instance, as after a process death
    val preferences = AttachEntryPreferences(store)
    assertTrue(preferences.openOnPlug)
    assertTrue(preferences.entryEnabled(linkRunning = false))
    preferences.settingOn = false
    assertFalse(AttachEntryPreferences(store).entryEnabled(linkRunning = false))
    preferences.settingOn = true
    assertTrue(AttachEntryPreferences(store).entryEnabled(linkRunning = false))
    preferences.openOnPlug = false
    assertFalse(AttachEntryPreferences(store).entryEnabled(linkRunning = false))
    // Nothing is left in the store for the defaults
    assertEquals(0, store.size)
  }

  @Test
  fun aLaunchThroughTheEntryIsToldOnce() {
    AttachLaunch.take()
    assertFalse(AttachLaunch.take())
    AttachLaunch.mark()
    assertTrue(AttachLaunch.take())
    assertFalse(AttachLaunch.take())
  }
}
