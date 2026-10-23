package app.alextran.immich.djilink

/** One descriptor of the page session, kept for the export header after it closed */
data class OpenRecord(
  val openedAtWallMs: Long,
  val firstByteAfterMs: Long? = null,
  val bytesRead: Long = 0,
  val bytesWritten: Long = 0,
  val reads: Long = 0,
  val closedAtWallMs: Long? = null,
  val closeReason: String? = null,
)

/**
 * What the export header keeps of a page session after the cable is pulled: the last accessory strings read on the
 * port with the time they were read, and one record per descriptor (up to [maxOpens]) with its own counters. The 23
 * October 2026 export lost both, because a second open reset the counters and the strings went with the unplug.
 */
class SessionLog(private val maxOpens: Int = MAX_OPENS) {
  companion object {
    const val MAX_OPENS = 16
  }

  var lastAccessory: AccessoryIdentity? = null
    private set
  var lastAccessoryAtWallMs: Long? = null
    private set

  private val records = ArrayDeque<OpenRecord>()

  fun opens(): List<OpenRecord> = records.toList()

  /** Strings read on the port; an unplug (null) keeps the last ones */
  fun onIdentity(identity: AccessoryIdentity?, wallMs: Long) {
    if (identity != null) {
      lastAccessory = identity
      lastAccessoryAtWallMs = wallMs
    }
  }

  fun onOpened(wallMs: Long) {
    records.addLast(OpenRecord(openedAtWallMs = wallMs))
    while (records.size > maxOpens) {
      records.removeFirst()
    }
  }

  fun onRead(length: Int, wallMs: Long) {
    val open = records.lastOrNull() ?: return
    if (open.closedAtWallMs != null) {
      return
    }
    records[records.size - 1] = open.copy(
      firstByteAfterMs = open.firstByteAfterMs ?: (wallMs - open.openedAtWallMs),
      bytesRead = open.bytesRead + length,
      reads = open.reads + 1,
    )
  }

  fun onWritten(length: Int) {
    val open = records.lastOrNull() ?: return
    if (open.closedAtWallMs != null) {
      return
    }
    records[records.size - 1] = open.copy(bytesWritten = open.bytesWritten + length)
  }

  fun onClosed(reason: String, wallMs: Long) {
    val open = records.lastOrNull() ?: return
    if (open.closedAtWallMs == null) {
      records[records.size - 1] = open.copy(closedAtWallMs = wallMs, closeReason = reason)
    }
  }

  /** A new page session: the opens start again; the last accessory stays, as the page shows it */
  fun newPageSession() {
    records.clear()
  }
}
