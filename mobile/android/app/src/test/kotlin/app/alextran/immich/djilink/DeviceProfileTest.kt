package app.alextran.immich.djilink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The RC-N3 and Neo 2 profile after the capture of 23 October 2026, and the pilot's binding */
class DeviceProfileTest {
  private val observed = listOf(
    Capability.ACCESSORY_OPEN,
    Capability.LINK_PROBE,
    Capability.LINK_NEGOTIATION,
    Capability.VIDEO_RECEIVE,
    Capability.TELEMETRY_RECEIVE,
  )

  private val s24PlusPhone = RunningDevice(manufacturer = "samsung", model = "SM-S926B", flavour = "phone")

  private val identity = AccessoryIdentity(
    manufacturer = "DJI",
    model = "some model string",
    description = "a remote",
    version = "1.0",
    serial = "not part of the binding",
    uri = null,
  )

  @Test
  fun theFiveObservedCapabilitiesAreSupportedOnThePhoneOfTheCaptureWithTheirProvenance() {
    val profile = ProfileRegistry().byId(ProfileRegistry.RC_N3_NEO2)!!
    for (capability in observed) {
      val state = profile.capabilities.getValue(capability)
      assertEquals("$capability", Support.SUPPORTED, state.support)
      assertEquals("$capability", Support.SUPPORTED, profile.supportOn(capability, s24PlusPhone))
      val provenance = state.provenance!!
      assertEquals("dji-link-20261023-102731", provenance.observationId)
      assertEquals("2026-10-23", provenance.date)
      assertEquals("8541e5d3395f12ac16e42d5fb86465f57ce7efb37ee8166a00c2260a742141bc", provenance.captureSha256)
      assertTrue(provenance.deviceModel.startsWith("Samsung SM-S926B"))
      assertEquals("Samsung SM-S926B, phone", provenance.device!!.verifiedOn)
      assertTrue(provenance.observed.isNotBlank())
    }
    for (capability in Capability.entries - observed.toSet()) {
      assertEquals("$capability", Support.UNKNOWN, profile.supportOn(capability, s24PlusPhone))
    }
  }

  @Test
  fun videoDecodingIsUnknownEverywhereUntilADeviceDecodes() {
    // Build 27 decoded nothing on the phone: the 308 pictures were decoded offline, on no device
    val profile = ProfileRegistry().byId(ProfileRegistry.RC_N3_NEO2)!!
    val state = profile.capabilities.getValue(Capability.VIDEO_DECODE)
    assertEquals(Support.UNKNOWN, state.support)
    assertEquals(Support.UNKNOWN, profile.supportOn(Capability.VIDEO_DECODE, s24PlusPhone))
    assertNull("an offline decode names no device", state.provenance!!.device)
    assertTrue(state.provenance!!.observed.contains("offline"))
  }

  @Test
  fun anAnswerHoldsOnTheDeviceAndFlavourOfItsObservationOnly() {
    val profile = ProfileRegistry().byId(ProfileRegistry.RC_N3_NEO2)!!
    val elsewhere = listOf(
      // The headset build, on the headset and even on the phone of the capture
      RunningDevice("Oculus", "Quest 3", "quest"),
      s24PlusPhone.copy(flavour = "quest"),
      // Another phone, and another Galaxy S24 model
      RunningDevice("Google", "Pixel 9", "phone"),
      s24PlusPhone.copy(model = "SM-S921B"),
    )
    for (device in elsewhere) {
      for (capability in Capability.entries) {
        assertEquals("$capability on $device", Support.UNKNOWN, profile.supportOn(capability, device))
      }
    }
    // The manufacturer string is compared without its case; the model and the flavour exactly
    assertEquals(
      Support.SUPPORTED,
      profile.supportOn(Capability.ACCESSORY_OPEN, s24PlusPhone.copy(manufacturer = "Samsung")),
    )
  }

  @Test
  fun thePageGetsThisDevicesAnswerAndTheDeviceItWasVerifiedOn() {
    val profile = ProfileRegistry().byId(ProfileRegistry.RC_N3_NEO2)!!
    val onPhone = profile.toPigeon(s24PlusPhone).capabilities.associateBy { it.name }
    val onQuest = profile.toPigeon(RunningDevice("Oculus", "Quest 3", "quest")).capabilities.associateBy { it.name }
    val open = Capability.ACCESSORY_OPEN.name
    assertEquals(DjiLinkSupport.SUPPORTED, onPhone.getValue(open).support)
    assertEquals(DjiLinkSupport.UNKNOWN, onQuest.getValue(open).support)
    assertEquals("Samsung SM-S926B, phone", onPhone.getValue(open).observedOn)
    assertEquals("Samsung SM-S926B, phone", onQuest.getValue(open).observedOn)
    assertEquals("2026-10-23", onQuest.getValue(open).observedDate)
    val decode = Capability.VIDEO_DECODE.name
    assertEquals(DjiLinkSupport.UNKNOWN, onPhone.getValue(decode).support)
    assertNull(onPhone.getValue(decode).observedOn)
    assertEquals("dji-link-20261023-102731 (2026-10-23)", onPhone.getValue(decode).provenance)
  }

  @Test
  fun theProfileCarriesTheStreamDescriptionOfTheCapture() {
    val seed = ProfileRegistry().byId(ProfileRegistry.RC_N3_NEO2)!!.streamSeed
    assertNotNull(seed)
    assertEquals(1920, seed!!.info.width)
    assertEquals(1080, seed.info.height)
    assertEquals(35, seed.vps.size)
    assertEquals(47, seed.sps.size)
    assertEquals(8, seed.pps.size)
  }

  @Test
  fun aBindingReturnsTheBoundProfileFirst() {
    val registry = ProfileRegistry()
    val bindings = ProfileBindings(MemoryKeyValueStore())
    val strings = AccessoryStrings.of(identity)!!
    assertNull(bindings.boundTo(strings))
    assertTrue(registry.match(identity).id.startsWith("observed-"))
    bindings.bind(strings, ProfileRegistry.RC_N3_NEO2)
    assertEquals(ProfileRegistry.RC_N3_NEO2, registry.match(identity, bindings.boundTo(strings)).id)
    // The serial is not part of the strings a binding is kept against
    assertEquals(strings, AccessoryStrings.of(identity.copy(serial = "another")))
    bindings.bind(strings, null)
    assertNull(bindings.boundTo(strings))
  }

  @Test
  fun aBindingGrantsNothingElse() {
    val registry = ProfileRegistry()
    // Bound to a profile nobody observed: its capabilities stay unknown, whatever is on the port
    val bound = registry.match(identity, "rc-2")
    assertEquals("rc-2", bound.id)
    for (capability in Capability.entries) {
      assertEquals(Support.UNKNOWN, bound.support(capability))
    }
    assertNull(bound.streamSeed)
    // A binding to a profile that does not exist falls back on the usual rules
    assertTrue(registry.match(identity, "no-such-profile").id.startsWith("observed-"))
  }

  @Test
  fun onlyTheStartingProfilesCanBeBound() {
    val registry = ProfileRegistry()
    registry.match(identity)
    val bindable = registry.bindable().map { it.id }
    assertTrue(ProfileRegistry.RC_N3_NEO2 in bindable)
    assertTrue(bindable.none { it.startsWith("observed-") })
  }
}
