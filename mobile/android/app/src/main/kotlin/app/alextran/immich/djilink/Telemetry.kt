package app.alextran.immich.djilink

/**
 * What arrives from the aircraft, as identifiers.
 *
 * A message is its command set and command id, two numbers of the frame header (p2/protocol.md, section 4). A message
 * is named only once a capture of hardware this project owns has shown what it carries, and that observation is
 * recorded with the name ([CataloguedMessage.observation]). The names are ours, as codes the page words in its own
 * language. Every other pair stays numbers: how often it arrives, its length and a bounded preview of its first
 * bytes. The fields of the named messages are read by [TelemetryDecoder], and only from bodies of the observed length.
 */
data class CataloguedMessage(
  val commandSet: Int,
  val commandId: Int,
  /** Our own name for what the capture showed, as a code the page words */
  val name: String,
  /** The observation that named it: a capture identifier, its date and the hardware it was taken on */
  val observation: String,
)

object MessageCatalogue {
  /** The capture that named the messages below: its identifier, its digest, the date and the hardware */
  const val OBSERVATION_20261023 =
    "dji-link-20261023-102731 (SHA-256 8541e5d3395f12ac16e42d5fb86465f57ce7efb37ee8166a00c2260a742141bc), " +
      "2026-10-23, DJI RC-N3 and Neo 2 with the Digital Transceiver, Samsung SM-S926B"

  /**
   * The pairs the 23 October 2026 capture explains (p2/capture-2026-10-23.md, sections 3.8 and 5): named where a public
   * layout of that pair and the capture agree, or where the capture alone shows what the field is.
   */
  private val entries: Map<Int, CataloguedMessage> = listOf(
    CataloguedMessage(3, 67, TelemetryCodes.FLIGHT_DATA, OBSERVATION_20261023),
    CataloguedMessage(4, 5, TelemetryCodes.GIMBAL, OBSERVATION_20261023),
    CataloguedMessage(13, 2, TelemetryCodes.BATTERY, OBSERVATION_20261023),
    CataloguedMessage(6, 30, TelemetryCodes.REMOTE_BATTERY, OBSERVATION_20261023),
    CataloguedMessage(9, 8, TelemetryCodes.SIGNAL, OBSERVATION_20261023),
    CataloguedMessage(9, 54, TelemetryCodes.LIVE_RATE, OBSERVATION_20261023),
    CataloguedMessage(35, 178, TelemetryCodes.AIRCRAFT_CLOCK, OBSERVATION_20261023),
    CataloguedMessage(33, 6, TelemetryCodes.MODULE_STATUS, OBSERVATION_20261023),
    CataloguedMessage(33, 8, TelemetryCodes.MODULE_STATUS, OBSERVATION_20261023),
  ).associateBy { key(it.commandSet, it.commandId) }

  private fun key(set: Int, id: Int): Int = (set shl 8) or id

  fun all(): List<CataloguedMessage> = entries.values.toList()

  fun named(set: Int, id: Int): CataloguedMessage? = entries[key(set, id)]

  fun isNamed(set: Int, id: Int): Boolean = entries.containsKey(key(set, id))
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
        name = MessageCatalogue.named(row.set, row.id)?.name,
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
