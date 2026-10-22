package app.alextran.immich.djilink

/** What a hardware profile may or may not be able to do. Each one is answered by an observation, never by a name. */
enum class Capability {
  ACCESSORY_OPEN,
  LINK_PROBE,
  LINK_NEGOTIATION,
  VIDEO_RECEIVE,
  VIDEO_DECODE,
  TELEMETRY_RECEIVE,
  CAMERA_SETTINGS,
  GIMBAL,
  FLIGHT_ACTION,
  CONTINUOUS_FLIGHT_CONTROL,
  PHYSICAL_STICK_PRIORITY_KNOWN,
}

enum class Support {
  UNKNOWN,
  UNSUPPORTED,
  SUPPORTED,
}

/**
 * Where a capability answer comes from. A hardware test, on named hardware, with a capture to show for it. Without
 * one, [Support.SUPPORTED] cannot be expressed: [CapabilityState] refuses it.
 */
data class Provenance(
  val observationId: String,
  val date: String,
  val deviceModel: String,
  val deviceOs: String,
  val controller: String,
  val aircraft: String,
  val captureSha256: String?,
  val observed: String,
)

data class CapabilityState(val support: Support, val provenance: Provenance? = null) {
  init {
    require(support != Support.SUPPORTED || provenance != null) {
      "a capability cannot be supported without an observation to show for it"
    }
  }

  companion object {
    val unknown = CapabilityState(Support.UNKNOWN)
  }
}

/**
 * One product pair (a controller and an aircraft, with its transceiver when it needs one) as this app knows it. The
 * accessory strings are what was read on the wire, not product names: nothing maps a model string to a product yet.
 *
 * Matching an accessory triple selects a label and nothing else. A profile never grants a capability.
 */
data class DeviceProfile(
  val id: String,
  val label: String,
  val accessoryManufacturer: String? = null,
  val accessoryModel: String? = null,
  val accessoryDescription: String? = null,
  val controllerModel: String? = null,
  val controllerFirmware: String? = null,
  val aircraftModel: String? = null,
  val aircraftFirmware: String? = null,
  val transceiver: String? = null,
  val transportKind: String = "usb-accessory",
  val protocolFamily: String? = null,
  val protocolVersion: String? = null,
  val note: String? = null,
  val capabilities: Map<Capability, CapabilityState> =
    Capability.entries.associateWith { CapabilityState.unknown },
) {
  fun support(capability: Capability): Support =
    capabilities[capability]?.support ?: Support.UNKNOWN
}

/**
 * The profiles this app starts with, every capability unknown, plus a profile made at runtime for an accessory triple
 * nobody has seen. Wide hardware support means exactly this: an unknown triple becomes a profile instead of a failure.
 */
class ProfileRegistry(seed: List<DeviceProfile> = starting) {
  companion object {
    /** Accessory model strings the format notes list (p2/protocol.md, section 2.2), as identity strings only */
    val KNOWN_MODELS = listOf("com.dji.logiclink", "WM160", "com.dji.link")
    const val MANUFACTURER = "DJI"

    val starting: List<DeviceProfile> = listOf(
      // The three accessory identity strings the format notes list. They are identity strings and nothing maps one of
      // them to a product, so each is its own profile with its label saying exactly that.
      DeviceProfile(
        id = "model-logiclink",
        label = "DJI accessory with the model string com.dji.logiclink",
        accessoryManufacturer = MANUFACTURER,
        accessoryModel = "com.dji.logiclink",
        note = "an identity string, not a product name; no product is claimed for it",
      ),
      DeviceProfile(
        id = "model-wm160",
        label = "DJI accessory with the model string WM160",
        accessoryManufacturer = MANUFACTURER,
        accessoryModel = "WM160",
        note = "an identity string, not a product name; no product is claimed for it",
      ),
      DeviceProfile(
        id = "model-link",
        label = "DJI accessory with the model string com.dji.link",
        accessoryManufacturer = MANUFACTURER,
        accessoryModel = "com.dji.link",
        note = "an identity string, not a product name; no product is claimed for it",
      ),
      DeviceProfile(
        id = "rc-n3-neo2",
        label = "DJI RC-N3 with a Neo 2 and the Digital Transceiver",
        accessoryManufacturer = MANUFACTURER,
        controllerModel = "RC-N3",
        aircraftModel = "Neo 2",
        transceiver = "DJI Digital Transceiver",
        note = "the hardware this work is written for; nothing about it is verified yet",
      ),
      DeviceProfile(
        id = "rc-n2-neo2",
        label = "DJI RC-N2 with a Neo 2",
        accessoryManufacturer = MANUFACTURER,
        controllerModel = "RC-N2",
        aircraftModel = "Neo 2",
        note = "a similar connector is not the same negotiation; compared session by session",
      ),
      DeviceProfile(
        id = "rc-n1",
        label = "DJI RC-N1 generation phone holder remote",
        accessoryManufacturer = MANUFACTURER,
        controllerModel = "RC-N1",
        note = "one profile per product and firmware pair",
      ),
      DeviceProfile(
        id = "rc-2",
        label = "DJI RC 2",
        accessoryManufacturer = MANUFACTURER,
        controllerModel = "RC 2",
        note = "a remote with its own screen and application; its USB topology is studied on its own",
      ),
      DeviceProfile(
        id = "goggles-n3",
        label = "DJI Goggles N3",
        accessoryManufacturer = MANUFACTURER,
        note = "the goggles category exists in the controller application; that proves nothing about a stream",
      ),
      DeviceProfile(
        id = "goggles-3",
        label = "DJI Goggles 3",
        accessoryManufacturer = MANUFACTURER,
        note = "as above",
      ),
      DeviceProfile(
        id = "motion-3",
        label = "DJI RC Motion 3 with goggles",
        accessoryManufacturer = MANUFACTURER,
        note = "remote plus goggles plus aircraft as one profile, not an RC-N3 lookalike",
      ),
    )
  }

  private val profiles = seed.associateBy { it.id }.toMutableMap()

  fun all(): List<DeviceProfile> = profiles.values.toList()

  fun byId(id: String): DeviceProfile? = profiles[id]

  /**
   * The profile for an accessory triple. A triple that matches nothing is added as a profile of its own, with every
   * capability unknown and its strings as they were read.
   */
  fun match(identity: AccessoryIdentity): DeviceProfile {
    val exact = profiles.values.firstOrNull {
      it.accessoryModel != null &&
        it.accessoryModel.equals(identity.model, ignoreCase = false) &&
        it.accessoryManufacturer.equals(identity.manufacturer, ignoreCase = true)
    }
    if (exact != null) {
      return exact
    }
    val id = "observed-" + listOf(identity.manufacturer, identity.model, identity.description)
      .joinToString("-") { it?.ifBlank { "blank" } ?: "none" }
      .lowercase()
      .replace(Regex("[^a-z0-9.-]"), "-")
      .take(80)
    return profiles.getOrPut(id) {
      DeviceProfile(
        id = id,
        label = "Unknown DJI accessory: " + listOfNotNull(identity.manufacturer, identity.model).joinToString(" "),
        accessoryManufacturer = identity.manufacturer,
        accessoryModel = identity.model,
        accessoryDescription = identity.description,
        note = "made from what was read on the port; nothing is claimed about it",
      )
    }
  }
}
