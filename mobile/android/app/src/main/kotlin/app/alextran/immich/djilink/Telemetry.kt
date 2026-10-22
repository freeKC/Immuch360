package app.alextran.immich.djilink

/**
 * What arrives from the aircraft, as identifiers.
 *
 * The command set and command id of the usual pushes are known statically (p2/protocol.md, section 7). Their field
 * layouts and units are not established for any aircraft this app has met, and the message model classes were not
 * part of what was read, so there is no field decoder here at all. Each message is shown as its identifier, its
 * observed length, how often it arrives and a bounded preview of its first bytes.
 *
 * A field decoder is added one message at a time, and only when a capture plus a side by side reading of the numbers
 * the DJI application shows at the same moment has established the offset and the unit. Nothing invents a unit.
 */
object TelemetryNames {
  /** Pushes of the flight controller set that the notes name; the name is the controller application's own */
  val flightController: Map<Int, String> = mapOf(
    9 to "fly forbid status push",
    50 to "deform status push",
    62 to "limit update request push",
    66 to "unlimited areas push",
    67 to "common OSD push, the main flight state message",
    68 to "home point push",
    69 to "GPS signal to noise ratio push",
    81 to "smart battery push",
    83 to "avoidance parameters push",
    85 to "limit state push",
    86 to "LED status push",
    97 to "activation request push",
    99 to "onboard receive push",
    103 to "power parameters",
    106 to "avoidance push",
    108 to "RTK location push",
    173 to "installation error push",
    182 to "fault injection push",
    185 to "redundancy status push",
    206 to "forbid data information push",
    215 to "flight record push",
    218 to "detection push",
    238 to "return to home countdown push",
    251 to "parameters by hash push",
  )

  val commandSets: Map<Int, String> = mapOf(
    CommandSets.COMMON to "common",
    CommandSets.SPECIAL to "special",
    CommandSets.CAMERA to "camera",
    CommandSets.FLIGHT_CONTROLLER to "flight controller",
    CommandSets.GIMBAL to "gimbal",
    5 to "centre board",
    CommandSets.REMOTE_CONTROLLER to "remote controller",
    7 to "wifi",
    8 to "video encoder board",
    CommandSets.OSD to "OSD",
    10 to "vision",
    11 to "simulator",
    CommandSets.BATTERY to "battery",
    CommandSets.SMART_BATTERY to "smart battery",
    15 to "RTK",
    17 to "ADS-B",
    21 to "glasses",
    24 to "4G module",
    25 to "onboard SDK",
    31 to "flight",
    32 to "narrow band",
    34 to "second flight controller",
    35 to "smart function",
    36 to "perception",
    60 to "payload SDK",
  )

  fun commandSetName(set: Int): String? = commandSets[set]

  fun messageName(set: Int, id: Int): String? =
    if (set == CommandSets.FLIGHT_CONTROLLER) flightController[id] else null
}

/** One identifier as it was seen on this link, with no field read from the body */
data class TelemetryMessage(
  val commandSet: Int,
  val commandId: Int,
  val name: String?,
  val count: Long,
  val lastLength: Int,
  val firstSeenMs: Long,
  val lastSeenMs: Long,
  /** Arrivals per second over the whole session, zero while only one has arrived */
  val ratePerSecond: Double,
  /** First bytes of the last body, hexadecimal, bounded */
  val preview: String,
)

class TelemetryTable(private val previewBytes: Int = 16) {
  private class Row(
    val set: Int,
    val id: Int,
    var count: Long = 0,
    var lastLength: Int = 0,
    var firstSeenMs: Long = 0,
    var lastSeenMs: Long = 0,
    var preview: String = "",
  )

  private val rows = linkedMapOf<Int, Row>()

  fun record(frame: P3Frame, nowMs: Long) {
    val key = (frame.commandSet shl 8) or frame.commandId
    val row = rows.getOrPut(key) { Row(frame.commandSet, frame.commandId, firstSeenMs = nowMs) }
    row.count += 1
    row.lastLength = frame.body.size
    row.lastSeenMs = nowMs
    // A frame whose encryption field is not zero has a body nobody can read: it is counted, never previewed
    row.preview = if (frame.encryptionUnsupported) "" else hex(frame.body, previewBytes)
  }

  fun messages(): List<TelemetryMessage> = rows.values
    .sortedWith(compareBy({ it.set }, { it.id }))
    .map { row ->
      val seconds = (row.lastSeenMs - row.firstSeenMs).coerceAtLeast(0L) / 1000.0
      TelemetryMessage(
        commandSet = row.set,
        commandId = row.id,
        name = TelemetryNames.messageName(row.set, row.id),
        count = row.count,
        lastLength = row.lastLength,
        firstSeenMs = row.firstSeenMs,
        lastSeenMs = row.lastSeenMs,
        ratePerSecond = if (seconds > 0) row.count / seconds else 0.0,
        preview = row.preview,
      )
    }

  fun reset() = rows.clear()

  companion object {
    fun hex(bytes: ByteArray, limit: Int): String {
      val count = minOf(limit, bytes.size)
      val out = StringBuilder(count * 3)
      for (index in 0 until count) {
        if (index > 0) {
          out.append(' ')
        }
        out.append("%02X".format(bytes[index]))
      }
      if (bytes.size > count) {
        out.append(" ...")
      }
      return out.toString()
    }
  }
}
