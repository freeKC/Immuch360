package app.alextran.immich.djilink

/**
 * The channels of the accessory stream and what each one carries, from the format notes of the P2 protocol study
 * (p2/protocol.md, section 3.1).
 *
 * No channel is tied to a camera here. The controller application picks the route from its own runtime state, and one
 * telemetry message publishes the camera to channel mapping; [ChannelRoles.cameraOfChannel] holds that mapping once a
 * message has given it, and holds nothing before.
 */
enum class ChannelRole {
  /** Control frames, parsed as DUML frames */
  CONTROL,

  /** Video payloads, no checksum and no sequence number */
  VIDEO,

  /** Payload (accessory on the aircraft) data */
  PAYLOAD,

  /** Accepted by the controller application's filter with no handling that was documented */
  RESERVED,

  /** Never seen in the notes: counted and shown, never dropped */
  UNKNOWN,
}

object Channels {
  const val CONTROL_PRIMARY = 22345
  const val CONTROL_ALTERNATE = 30000

  private val roles: Map<Int, ChannelRole> = buildMap {
    put(CONTROL_PRIMARY, ChannelRole.CONTROL)
    put(CONTROL_ALTERNATE, ChannelRole.CONTROL)
    put(22346, ChannelRole.VIDEO)
    put(22347, ChannelRole.VIDEO)
    put(22350, ChannelRole.VIDEO)
    put(22352, ChannelRole.VIDEO)
    put(22360, ChannelRole.VIDEO)
    put(22361, ChannelRole.PAYLOAD)
    put(22348, ChannelRole.RESERVED)
    put(22349, ChannelRole.RESERVED)
    put(22351, ChannelRole.RESERVED)
  }

  fun role(channel: Int): ChannelRole = roles[channel] ?: ChannelRole.UNKNOWN

  /** Whether the channel number is one the notes describe; an unknown channel is still parsed and counted */
  fun isKnown(channel: Int): Boolean = roles.containsKey(channel)

  val known: Set<Int> get() = roles.keys
}

/**
 * Which camera a video channel carries, filled only from a camera video stream information message. Empty until such
 * a message arrives: a guess here would name a picture nobody has seen.
 */
class ChannelRoles {
  private val cameras = mutableMapOf<Int, Int>()

  fun publishCamera(channel: Int, cameraType: Int) {
    cameras[channel] = cameraType
  }

  fun cameraOfChannel(channel: Int): Int? = cameras[channel]

  fun mapping(): Map<Int, Int> = cameras.toMap()
}
