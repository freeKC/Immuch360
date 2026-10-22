package app.alextran.immich.djilink

/**
 * The states of the USB link to a DJI remote controller, in the order they can be reached, plus the exits.
 *
 * Each step is a different claim and no step ever follows from a write. A descriptor is not a DJI connection, a
 * controller that answers is not an aircraft that is linked, and none of them is authority over the aircraft:
 * authority is a capability of the hardware profile, never a state here (see [Capability.CONTINUOUS_FLIGHT_CONTROL]).
 */
enum class LinkState {
  /** No accessory on the port */
  ABSENT,

  /** An accessory is listed, with its manufacturer, model and description read */
  ACCESSORY_DETECTED,

  /** Permission asked, the system dialog is up */
  PERMISSION_PENDING,

  /** The pilot refused, or the system refused for us */
  PERMISSION_DENIED,

  /** The accessory is open and a descriptor is held */
  ACCESSORY_OPEN,

  /** The one byte liveness probe returns without error, so the pipe accepts bytes */
  LINK_USABLE,

  /** Control frames from the controller side arrived and parsed */
  CONTROLLER_IDENTIFIED,

  /** Frames from the aircraft side arrived and parsed */
  AIRCRAFT_LINKED,

  /** Video fragments assembled into something a decoder accepted */
  VIDEO_READY,

  /** At least one telemetry message decoded with an established layout */
  TELEMETRY_READY,

  /** The link was up and went away */
  LINK_LOST,

  /** Waiting before the next attempt */
  RECOVERING,

  /** This device cannot be a USB accessory at all, so no cable path exists here */
  UNSUPPORTED_TRANSPORT,

  /** Bytes arrive and nothing in them matches the formats this app knows */
  UNSUPPORTED_PROTOCOL,
}

/** What was read of the accessory, as reported, with nothing renamed */
data class AccessoryIdentity(
  val manufacturer: String?,
  val model: String?,
  val description: String?,
  val version: String?,
  val serial: String?,
  val uri: String?,
)

/** Everything the diagnostics page shows about the link itself */
data class LinkSnapshot(
  val state: LinkState = LinkState.ABSENT,
  val accessory: AccessoryIdentity? = null,
  val profileId: String? = null,
  val profileLabel: String? = null,
  /** Why the state is what it is, in one line, for the page and the log */
  val detail: String? = null,
  val openedAtMs: Long? = null,
  /** Time between the open and the first byte read, null while no byte has arrived */
  val firstByteMs: Long? = null,
  val probesSent: Long = 0,
  val probeFailures: Long = 0,
  val consecutiveProbeFailures: Int = 0,
  val lastProbeCallMs: Long = 0,
  val bytesRead: Long = 0,
  val bytesWritten: Long = 0,
  val reads: Long = 0,
  val writes: Long = 0,
  val attempts: Long = 0,
  val chargeCurrentMicroAmps: Int? = null,
)
