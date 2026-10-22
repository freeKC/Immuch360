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

/**
 * Why the link is in its state, as a code the page turns into a sentence of its own language. The log keeps the
 * English name; [LinkEvents.onState] can add one technical word to it, such as the name of an exception.
 */
enum class LinkReason {
  /** The device declares no USB accessory feature and has no accessory device node */
  NO_ACCESSORY_FEATURE,

  /** The device has no USB service at all */
  NO_USB_SERVICE,

  /** The page is looking for an accessory */
  LOOKING,

  /** The accessory list is empty */
  NOTHING_LISTED,

  /** An accessory is listed and its strings were read */
  LISTED,

  /** An accessory appeared while the system chooser may be on screen; the permission is asked after a grace period */
  WAITING_FOR_CHOOSER,

  /** The permission dialog is up */
  PERMISSION_ASKED,

  /** The permission could not even be asked for */
  PERMISSION_REQUEST_FAILED,

  /** The pilot refused the permission; it is asked again only by the retry button or a new plug */
  PERMISSION_REFUSED,

  /** The permission is held and the open returned nothing: another application may hold the accessory */
  OPEN_FAILED,

  /** A descriptor is held and nothing has been written */
  OPENED,

  /** The liveness probe returns; nothing has answered yet */
  PROBE_RETURNS,

  /** Several probes in a row failed while nothing was read */
  PROBES_FAILED,

  /** A probe write did not return: the remote is not reading this endpoint, and probing stopped */
  WRITE_BLOCKED,

  /** The accessory was unplugged */
  DETACHED,

  /** The accessory stream ended */
  STREAM_ENDED,

  /** Reads failed too many times in a row */
  READS_FAILED,

  /** Writes failed too many times in a row */
  WRITES_FAILED,

  /** The page was closed */
  PAGE_CLOSED,

  /** Control frames arrive and parse */
  FRAMES_PARSE,

  /** Frames from the aircraft side arrive */
  AIRCRAFT_FRAMES,
}
