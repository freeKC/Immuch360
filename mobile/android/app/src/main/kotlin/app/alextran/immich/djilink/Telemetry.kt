package app.alextran.immich.djilink

/**
 * What arrives from the aircraft, as identifiers.
 *
 * A message is its command set and command id, two numbers of the frame header (p2/protocol.md, section 4). Nothing
 * here gives either number a name or a meaning: a message is named only once a capture of hardware this project owns
 * has shown what it carries, beside the numbers the DJI application shows at the same moment, and that observation is
 * recorded with the name. Until then the page shows the numbers, how often they arrive, their length and a bounded
 * preview of their first bytes, and no field of any body is read.
 */
data class CataloguedMessage(
  val commandSet: Int,
  val commandId: Int,
  /** Our own name for what the capture showed */
  val name: String,
  /** The observation that named it: a capture identifier, its date and the hardware it was taken on */
  val observation: String,
)

object MessageCatalogue {
  /** Empty until a capture names a message; see [CataloguedMessage.observation] */
  private val entries: Map<Int, CataloguedMessage> = emptyMap()

  private fun key(set: Int, id: Int): Int = (set shl 8) or id

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
