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

/** The device this app runs on, as Build.MANUFACTURER and Build.MODEL read it, and the flavour of the build */
data class RunningDevice(val manufacturer: String, val model: String, val flavour: String)

/** This device as its environment report reads it */
val UsbEnvironmentReport.runningDevice: RunningDevice get() = RunningDevice(deviceManufacturer, deviceModel, flavour)

/**
 * The device an observation was made on, read the same way as [RunningDevice], with the name the page and the export
 * give it. A phone result says nothing about the headset build, nor about another phone.
 */
data class ObservedDevice(
  val manufacturer: String,
  val model: String,
  val flavour: String,
  val name: String,
) {
  /** "Samsung SM-S926B, phone": the device and the flavour the answer holds for */
  val verifiedOn: String get() = "$name, $flavour"

  fun matches(device: RunningDevice): Boolean =
    manufacturer.equals(device.manufacturer, ignoreCase = true) && model == device.model && flavour == device.flavour
}

/**
 * Where a capability answer comes from. A hardware test, on named hardware, with a capture to show for it. Without
 * one, [Support.SUPPORTED] cannot be expressed: [CapabilityState] refuses it.
 */
data class Provenance(
  val observationId: String,
  val date: String,
  /** Where the observation was made, as a reader names it */
  val deviceModel: String,
  val deviceOs: String,
  val controller: String,
  val aircraft: String,
  val captureSha256: String?,
  val observed: String,
  /** The device and flavour the answer holds for; null for an observation made on no device, such as an offline decode */
  val device: ObservedDevice? = null,
)

data class CapabilityState(val support: Support, val provenance: Provenance? = null) {
  init {
    require(support != Support.SUPPORTED || provenance?.device != null) {
      "a capability cannot be supported without an observation on a device to show for it"
    }
  }

  /**
   * The answer on [device]: an observation holds for the device and the flavour it was made on, and for no other. On
   * any other device, the headset build of the same phone included, the answer is unknown until a capture there exists.
   */
  fun on(device: RunningDevice): Support =
    if (provenance?.device?.matches(device) == true) support else Support.UNKNOWN

  companion object {
    val unknown = CapabilityState(Support.UNKNOWN)
  }
}

/**
 * One product pair (a controller and an aircraft, with its transceiver when it needs one) as this app knows it. The
 * accessory strings are what was read on the wire, not product names: nothing maps a model string to a product yet.
 *
 * Matching an accessory triple, or the pilot binding the strings he sees to a profile, selects a label, the
 * capabilities observed on that hardware and the stream description seed, and nothing else. A profile never grants
 * anything to the link: the safety rules do not read it.
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
  /** The H.265 stream description observed on this hardware, used when the stream gives none ([ParameterSetStore]) */
  val streamSeed: StreamDescription? = null,
) {
  /** The answer as it was observed, on the device of its observation */
  fun support(capability: Capability): Support =
    capabilities[capability]?.support ?: Support.UNKNOWN

  /** The answer on [device], which is unknown anywhere but on the device and flavour of the observation */
  fun supportOn(capability: Capability, device: RunningDevice): Support =
    capabilities[capability]?.on(device) ?: Support.UNKNOWN
}

/**
 * The profiles this app starts with, every capability unknown, plus a profile made at runtime for an accessory triple
 * nobody has seen. Wide hardware support means exactly this: an unknown triple becomes a profile instead of a failure.
 */
class ProfileRegistry(seed: List<DeviceProfile> = starting) {
  companion object {
    /** The capture of 23 October 2026, FreeKC's RC-N3 and Neo 2 on a Galaxy S24+ (p2/capture-2026-10-23.md) */
    const val CAPTURE_20261023 = "dji-link-20261023-102731"
    const val CAPTURE_20261023_SHA256 = "8541e5d3395f12ac16e42d5fb86465f57ce7efb37ee8166a00c2260a742141bc"

    /**
     * The VPS, SPS and PPS of that capture, 102 bytes in one envelope on the wire (start codes excluded here): H.265
     * Main, High tier, level 5, 1920 x 1080, 4:2:0, 8 bit. A stream description, no picture and no serial number: the
     * only bytes of a capture this repository holds.
     */
    const val SEED_VPS_20261023 = "40010c01ffff21600000030000030000030000030096ac0c0000030004000003007940"
    const val SEED_SPS_20261023 =
      "42010121600000030000030000030000030096a003c08010e7febbb726b97535010101040000030004000003007820"
    const val SEED_PPS_20261023 = "4401c17312240890"

    val seed20261023: StreamDescription? by lazy {
      StreamDescription.fromHex(SEED_VPS_20261023, SEED_SPS_20261023, SEED_PPS_20261023)
    }

    /** The phone of the capture of 23 October 2026, as its export header reads it (build 27, phone flavour) */
    val GALAXY_S24_PLUS_PHONE = ObservedDevice(
      manufacturer = "samsung",
      model = "SM-S926B",
      flavour = "phone",
      name = "Samsung SM-S926B",
    )

    private fun observed20261023(observed: String) = CapabilityState(
      Support.SUPPORTED,
      Provenance(
        observationId = CAPTURE_20261023,
        date = "2026-10-23",
        deviceModel = "Samsung SM-S926B (Galaxy S24+), phone flavour",
        deviceOs = "Android 16, BP4A.251205.006",
        controller = "RC-N3, firmware not recorded",
        aircraft = "Neo 2 with the Digital Transceiver, firmware not recorded",
        captureSha256 = CAPTURE_20261023_SHA256,
        observed = observed,
        device = GALAXY_S24_PLUS_PHONE,
      ),
    )

    /**
     * What the capture of 23 October 2026 shows the RC-N3 and the Neo 2 doing with a phone that sends nothing. Each
     * answer holds on that phone with the phone build only ([CapabilityState.on]).
     */
    val rcN3Neo2Capabilities: Map<Capability, CapabilityState> =
      Capability.entries.associateWith { CapabilityState.unknown } + mapOf(
        Capability.ACCESSORY_OPEN to observed20261023("two opens, reads on both"),
        Capability.LINK_PROBE to observed20261023("68 probes, 0 failures"),
        Capability.LINK_NEGOTIATION to observed20261023(
          "nothing but the one byte probe was written and video and telemetry flowed: none needed",
        ),
        Capability.VIDEO_RECEIVE to observed20261023("29,026 video envelopes on channel 22346 in the session"),
        // Build 27 decoded nothing on the phone: the pictures of the capture were decoded offline, on no device. The
        // answer stays unknown everywhere until a device decodes the stream (owner test step 1).
        Capability.VIDEO_DECODE to CapabilityState(
          Support.UNKNOWN,
          Provenance(
            observationId = CAPTURE_20261023,
            date = "2026-10-23",
            deviceModel = "no device: the capture decoded offline on the build host with ffmpeg 7.1.5",
            deviceOs = "Debian 13",
            controller = "RC-N3, firmware not recorded",
            aircraft = "Neo 2 with the Digital Transceiver, firmware not recorded",
            captureSha256 = CAPTURE_20261023_SHA256,
            observed = "H.265 Main 1920 x 1080, 308 pictures decoded with no error offline; no device has decoded it yet",
            device = null,
          ),
        ),
        Capability.TELEMETRY_RECEIVE to observed20261023("21,860 control frames, every checksum verified"),
      )

    /** Accessory model strings the format notes list (p2/protocol.md, section 2.2), as identity strings only */
    val KNOWN_MODELS = listOf("com.dji.logiclink", "WM160", "com.dji.link")
    const val MANUFACTURER = "DJI"
    const val RC_N3_NEO2 = "rc-n3-neo2"

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
        id = RC_N3_NEO2,
        label = "DJI RC-N3 with a Neo 2 and the Digital Transceiver",
        accessoryManufacturer = MANUFACTURER,
        controllerModel = "RC-N3",
        aircraftModel = "Neo 2",
        transceiver = "DJI Digital Transceiver",
        protocolFamily = "envelope 55 CC, control channel 22345, H.265 video on 22346",
        note = "observed on 23 October 2026: receive only, video and telemetry with nothing sent but the probe",
        capabilities = rcN3Neo2Capabilities,
        streamSeed = seed20261023,
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

  /** The profiles the pilot can bind accessory strings to: the starting ones, never one made from a port */
  fun bindable(): List<DeviceProfile> = starting.mapNotNull { profiles[it.id] }

  /**
   * The profile for an accessory triple: the one the pilot bound these strings to first, then the rules below. A triple
   * that matches nothing is added as a profile of its own, with every capability unknown and its strings as they were
   * read.
   */
  fun match(identity: AccessoryIdentity, boundProfileId: String? = null): DeviceProfile {
    boundProfileId?.let { bound -> profiles[bound]?.let { return it } }
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
        // Whatever is on the port, DJI or not: the label claims nothing beyond the strings that were read
        label = "Accessory not described yet: " +
          listOfNotNull(identity.manufacturer, identity.model).joinToString(" ").ifBlank { "no strings" },
        accessoryManufacturer = identity.manufacturer,
        accessoryModel = identity.model,
        accessoryDescription = identity.description,
        note = "made from what was read on the port; nothing is claimed about it",
      )
    }
  }
}

/**
 * The pilot's choice of "Your hardware", kept in the app's preferences against the four accessory strings. It names
 * the hardware and selects the stream description seed; it changes nothing in what the link does.
 */
class ProfileBindings(private val preferences: KeyValueStore) {
  companion object {
    const val KEY_PREFIX = "djilink.profileBinding."
  }

  fun boundTo(strings: AccessoryStrings?): String? = strings?.let { preferences.read(KEY_PREFIX + it.key) }

  fun bind(strings: AccessoryStrings, profileId: String?) {
    preferences.write(KEY_PREFIX + strings.key, profileId)
  }
}
