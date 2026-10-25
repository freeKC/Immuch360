package app.alextran.immich.djilink

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * What a headset received from the phone, kept for a bug report (p2/design-final-2026-10-24.md, section 5). On a
 * headset the cable is on the phone, so the capture of the link has nothing to keep; this keeps what the headset itself
 * received instead: the relay records as they arrived (header and body, the time of each in the index), in a head of
 * the first [headBytes] and a tail of the last [tailBytes], and every telemetry record of the session in a ring of its
 * own, with the states the reception went through.
 *
 * Nothing here is sent anywhere: the records are a copy of bytes already read. The relay carries no serial number and
 * no position (RelayTelemetry), so neither does the record; it holds the drone's picture as this headset received it.
 *
 * Allocated when a reception starts, never before; kept while the watch page is open whatever the state, and forgotten
 * when a new reception starts after the page was closed.
 */
class ReceptionRecord(
  headBytes: Int = HEAD_BYTES,
  tailBytes: Int = TAIL_BYTES,
  telemetryBytes: Int = TELEMETRY_BYTES,
  private val monotonicNs: () -> Long = { System.nanoTime() },
  private val wallMs: () -> Long = { System.currentTimeMillis() },
) {
  companion object {
    const val HEAD_BYTES = 2 * 1024 * 1024
    const val TAIL_BYTES = 16 * 1024 * 1024

    /** More than ten minutes of telemetry records at ten a second */
    const val TELEMETRY_BYTES = 8 * 1024 * 1024
    private const val STATES_KEPT = 200
  }

  /** The phone watched, as the page shows it: never its code */
  data class Watched(val name: String?, val host: String?, val port: Int?)

  data class StateLine(val wallMs: Long, val monotonicNs: Long, val state: String)

  private val records = CaptureRing(tailBytes, headBytes, monotonicNs, wallMs)
  private val telemetry = CaptureRing(telemetryBytes, 0, monotonicNs, wallMs)
  private val states = ArrayDeque<StateLine>()
  private val counts = sortedMapOf<Int, Long>()

  var watched: Watched? = null
    private set
  var startedAtWallMs: Long? = null
    private set
  var startedAtNs: Long? = null
    private set
  var lastRecordAtWallMs: Long? = null
    private set

  /** Records kept since the start, whatever the rings still hold */
  val received: Long
    @Synchronized get() = counts.values.sum()

  /** A reception starts: the rings are made the first time, and the record goes on in them */
  @Synchronized
  fun start(watched: Watched) {
    this.watched = watched
    if (startedAtWallMs == null) {
      startedAtWallMs = wallMs()
      startedAtNs = monotonicNs()
    }
    records.start(accessoryOpen = true)
    telemetry.start(accessoryOpen = true)
  }

  /** Everything goes: the next reception starts a new record */
  @Synchronized
  fun clear() {
    records.stop()
    telemetry.stop()
    records.clear()
    telemetry.clear()
    states.clear()
    counts.clear()
    watched = null
    startedAtWallMs = null
    startedAtNs = null
    lastRecordAtWallMs = null
  }

  /** One record as it arrived; the telemetry records go to their own ring too, which keeps the whole session */
  @Synchronized
  fun record(record: RelayRecord) {
    if (startedAtWallMs == null) {
      return
    }
    val bytes = RelayWire.record(record.type, record.flags, record.body)
    records.record(CaptureDirection.IN, bytes)
    if (record.type == RelayWire.TELEMETRY) {
      telemetry.record(CaptureDirection.IN, bytes)
    }
    counts[record.type] = (counts[record.type] ?: 0L) + 1
    lastRecordAtWallMs = wallMs()
  }

  /** A state of the reception, kept once per change */
  @Synchronized
  fun state(state: String) {
    if (startedAtWallMs == null || states.lastOrNull()?.state == state) {
      return
    }
    states.addLast(StateLine(wallMs(), monotonicNs(), state))
    while (states.size > STATES_KEPT) {
      states.removeFirst()
    }
  }

  @Synchronized
  fun records(): CaptureSnapshot = records.snapshot()

  @Synchronized
  fun telemetryRecords(): CaptureSnapshot = telemetry.snapshot()

  /** The part of the header this record knows: the phone, the times, the states and the records per kind */
  @Synchronized
  fun header(): JsonObject {
    val watched = watched
    return buildJsonObject {
      put("kind", "reception")
      put(
        "phone",
        buildJsonObject {
          put("name", watched?.name)
          put("host", watched?.host)
          put("port", watched?.port)
        },
      )
      put("startedAtWallMs", startedAtWallMs)
      put("startedAtMonotonicNs", startedAtNs)
      put("lastRecordAtWallMs", lastRecordAtWallMs)
      put(
        "states",
        buildJsonArray {
          for (line in states) {
            add(
              buildJsonObject {
                put("wallMs", line.wallMs)
                put("monotonicNs", line.monotonicNs)
                put("state", line.state)
              },
            )
          }
        },
      )
      put("recordsByKind", buildJsonObject { counts.forEach { (type, count) -> put(kindName(type), count) } })
      put("headBytes", records.capacityOfHead)
      put("tailBytes", records.capacityOfRing)
      put("telemetryBytes", telemetry.capacityOfRing)
    }
  }

  private fun kindName(type: Int): String = when (type) {
    RelayWire.PARAMETERS -> "parameters"
    RelayWire.UNIT -> "unit"
    RelayWire.RESET -> "reset"
    RelayWire.TELEMETRY -> "telemetry"
    RelayWire.PONG -> "pong"
    RelayWire.BYE -> "bye"
    else -> "type$type"
  }
}
