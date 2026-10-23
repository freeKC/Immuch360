package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** A profile is a label. It never grants a capability, and a capability never claims support without an observation. */
class ProfileRegistryTest {
  @Test
  fun everyStartingProfileButTheObservedOneIsUnknownEverywhere() {
    val registry = ProfileRegistry()
    assertTrue(registry.all().isNotEmpty())
    for (profile in registry.all().filter { it.id != ProfileRegistry.RC_N3_NEO2 }) {
      for (capability in Capability.entries) {
        assertEquals(Support.UNKNOWN, profile.support(capability))
      }
    }
  }

  @Test
  fun aKnownModelStringSelectsItsProfileAndGrantsNothing() {
    val registry = ProfileRegistry()
    val matched = registry.match(
      AccessoryIdentity(
        manufacturer = "DJI",
        model = "com.dji.logiclink",
        description = " RC something",
        version = "1.0",
        serial = null,
        uri = null,
      )
    )
    assertEquals("model-logiclink", matched.id)
    assertEquals(Support.UNKNOWN, matched.support(Capability.VIDEO_RECEIVE))
    assertEquals(Support.UNKNOWN, matched.support(Capability.CONTINUOUS_FLIGHT_CONTROL))
  }

  @Test
  fun anUnknownTripleBecomesAProfileRatherThanAFailure() {
    val registry = ProfileRegistry()
    val before = registry.all().size
    val identity = AccessoryIdentity(
      manufacturer = "DJI",
      model = "com.dji.somethingnew",
      description = " glasses",
      version = "2.0",
      serial = null,
      uri = null,
    )
    val made = registry.match(identity)
    assertEquals(before + 1, registry.all().size)
    assertEquals("com.dji.somethingnew", made.accessoryModel)
    assertNotNull(registry.byId(made.id))
    // The same triple again is the same profile, not a second one
    assertEquals(made.id, registry.match(identity).id)
    assertEquals(before + 1, registry.all().size)
  }

  @Test
  fun supportedCannotBeExpressedWithoutAnObservation() {
    assertThrows(IllegalArgumentException::class.java) { CapabilityState(Support.SUPPORTED) }
    val state = CapabilityState(
      Support.SUPPORTED,
      Provenance(
        observationId = "HC-03",
        date = "2026-10-22",
        deviceModel = "Quest 3",
        deviceOs = "Horizon OS",
        controller = "RC-N3",
        aircraft = "Neo 2",
        captureSha256 = null,
        observed = "the accessory opened and the probe kept returning for two minutes",
      ),
    )
    assertEquals(Support.SUPPORTED, state.support)
  }
}
