package app.alextran.immich.djilink

import kotlin.math.max

/**
 * The fields of the catalogued telemetry messages, read only from bodies of the length observed on 23 October 2026.
 *
 * Every offset, type and unit below comes from the capture of FreeKC's RC-N3 and Neo 2 (p2/capture-2026-10-23.md,
 * section 5), where three public layouts fit the bodies with live values that agree with each other, cross checked
 * with the public layouts of those pairs. The names are ours. A body of any other length is counted as a layout
 * mismatch and left as numbers, so that another firmware cannot be misread silently. Offsets are body offsets (after
 * the set and id bytes), little endian.
 *
 * Not read on purpose: offsets 0 and 8 of the flight data (the position: no fix indoors, so neither the unit nor the
 * order is verified, and a position on screen would end up in screenshots), offset 40 (a counter, not the battery a
 * public layout puts there), offset 37 and everything past offset 44.
 *
 * Nothing here is a flight instrument: no value has been compared with DJI Fly yet (checkpoint HC-09).
 */
enum class TelemetryEvidence {
  /** A public layout and the 23 October capture agree */
  PUBLIC_AND_CAPTURE,

  /** The capture alone shows what the field is */
  CAPTURE,

  /** A reading that fits and was never checked against a reference */
  CANDIDATE,
}

data class FlightReading(
  val heightM: Double,
  val speedsMps: List<Double>,
  val pitchDeg: Double,
  val rollDeg: Double,
  val headingDeg: Double,
  val mode: Int,
  val inAir: Boolean,
  val motorsOn: Boolean,
  val satellites: Int,
  val groundHeightM: Double,
  val motorTimeS: Double,
  val flags: Long,
)

data class GimbalReading(
  val headingDeg: Double,
  val clockMs: Long,
  val headingFineDeg: Double,
  val angle1Deg: Double,
  val angle2Deg: Double,
  /** w, x, y, z */
  val quaternion: List<Double>,
)

data class BatteryReading(
  val voltageV: Double,
  val currentA: Double,
  val fullMah: Long,
  val remainingMah: Long,
  val temperatureC: Double,
  val cells: Int,
  val percent: Int,
  val status: Long,
)

object TelemetryFields {
  const val FLIGHT_SET = 3
  const val FLIGHT_ID = 67
  const val FLIGHT_LENGTH = 85
  const val GIMBAL_SET = 4
  const val GIMBAL_ID = 5
  const val GIMBAL_LENGTH = 50
  const val BATTERY_SET = 13
  const val BATTERY_ID = 2
  const val BATTERY_LENGTH = 44
  const val REMOTE_BATTERY_SET = 6
  const val REMOTE_BATTERY_ID = 30
  const val REMOTE_BATTERY_LENGTH = 6
  const val SIGNAL_SET = 9
  const val SIGNAL_ID = 8
  const val SIGNAL_LENGTH = 1
  const val LIVE_RATE_SET = 9
  const val LIVE_RATE_ID = 54
  const val LIVE_RATE_LENGTH = 4
  const val CLOCK_SET = 35
  const val CLOCK_ID = 178
  const val CLOCK_LENGTH = 43
  const val MODULE_SET = 33
  val MODULE_IDS = setOf(6, 8)

  /** The flight mode number of the automatic landing, the one value of that byte the capture explains */
  const val MODE_AUTOMATIC_LANDING = 12
  /**
   * Bits 0x04 and 0x08 of offset 32 are set exactly while the motor time grows and never differ in our captures: the
   * pair proves the motors running (p2/telemetry-flight-2026-10-24.md, 2.1 and 3.4). Which one alone means in the air
   * is a guess, so [FlightReading.inAir] keeps bit 0x04 for the record and no screen shows it.
   */
  const val FLAG_IN_AIR = 0x04L
  const val FLAG_MOTORS_ON = 0x08L
  const val FLAGS_MOTORS_RUNNING = 0x0CL

  fun flight(body: ByteArray): FlightReading? {
    if (body.size != FLIGHT_LENGTH) {
      return null
    }
    val flags = u32(body, 32)
    return FlightReading(
      heightM = i16(body, 16) / 10.0,
      speedsMps = listOf(i16(body, 18) / 10.0, i16(body, 20) / 10.0, i16(body, 22) / 10.0),
      pitchDeg = i16(body, 24) / 10.0,
      rollDeg = i16(body, 26) / 10.0,
      headingDeg = i16(body, 28) / 10.0,
      mode = u8(body, 30),
      inAir = (flags and FLAG_IN_AIR) != 0L,
      motorsOn = (flags and FLAGS_MOTORS_RUNNING) == FLAGS_MOTORS_RUNNING,
      satellites = u8(body, 36),
      groundHeightM = u8(body, 41) / 10.0,
      motorTimeS = u16(body, 42) / 10.0,
      flags = flags,
    )
  }

  fun gimbal(body: ByteArray): GimbalReading? {
    if (body.size != GIMBAL_LENGTH) {
      return null
    }
    return GimbalReading(
      headingDeg = i16(body, 4) / 10.0,
      clockMs = u32(body, 12),
      // A 16 bit value: bytes 18 and 19 are zero in every frame of three captures, so a 32 bit read turned every
      // negative heading into one above 400 degrees (p2/telemetry-flight-2026-10-24.md, 2.2)
      headingFineDeg = i16(body, 16) / 100.0,
      angle1Deg = i16(body, 20) / 100.0,
      angle2Deg = i16(body, 22) / 100.0,
      quaternion = listOf(f32(body, 24), f32(body, 28), f32(body, 32), f32(body, 36)).map { it.toDouble() },
    )
  }

  fun battery(body: ByteArray): BatteryReading? {
    if (body.size != BATTERY_LENGTH) {
      return null
    }
    return BatteryReading(
      voltageV = u32(body, 1) / 1000.0,
      currentA = i32(body, 5) / 1000.0,
      fullMah = u32(body, 9),
      remainingMah = u32(body, 13),
      temperatureC = u16(body, 17) / 10.0,
      cells = u8(body, 19),
      percent = u8(body, 20),
      status = u64(body, 21),
    )
  }

  fun remoteBattery(body: ByteArray): Int? = if (body.size == REMOTE_BATTERY_LENGTH) u8(body, 4) else null

  /** The low seven bits of the one byte body */
  fun signal(body: ByteArray): Int? = if (body.size == SIGNAL_LENGTH) u8(body, 0) and 0x7F else null

  fun liveRate(body: ByteArray): Double? = if (body.size == LIVE_RATE_LENGTH) f32(body, 0).toDouble() else null

  fun aircraftClock(body: ByteArray): Long? = if (body.size == CLOCK_LENGTH) u32(body, 0) else null

  /** The per module seconds counter, byte 1, wrapping; a presence signal only */
  fun moduleSeconds(body: ByteArray): Int? = if (body.size >= 2) u8(body, 1) else null

  /**
   * The yaw of the gimbal's unit quaternion w, x, y, z, in degrees: the angle about z of a decomposition that turns
   * about z first, then about x, then about y. That is the order in which the quaternion's yaw equals the fine heading
   * at offset 16 within 0.01 degree at every one of the 113 samples of the capture; the z, y, x order misses by up to
   * 1.4 degrees there.
   */
  fun yawOf(quaternion: List<Double>): Double {
    val (w, x, y, z) = quaternion
    return Math.toDegrees(kotlin.math.atan2(2 * (w * z - x * y), 1 - 2 * (x * x + z * z)))
  }

  fun u8(body: ByteArray, at: Int): Int = body[at].toInt() and 0xFF

  fun u16(body: ByteArray, at: Int): Int = u8(body, at) or (u8(body, at + 1) shl 8)

  fun i16(body: ByteArray, at: Int): Int = u16(body, at).toShort().toInt()

  fun u32(body: ByteArray, at: Int): Long =
    u16(body, at).toLong() or (u16(body, at + 2).toLong() shl 16)

  fun i32(body: ByteArray, at: Int): Int = u32(body, at).toInt()

  fun u64(body: ByteArray, at: Int): Long = u32(body, at) or (u32(body, at + 4) shl 32)

  fun f32(body: ByteArray, at: Int): Float = java.lang.Float.intBitsToFloat(i32(body, at))
}

/** One group of values with its age and whether it is stale */
data class Timed<T>(val value: T, val ageMs: Long, val stale: Boolean)

data class LinkReadings(
  /** Signal quality as the aircraft side (sender type 9) reports it */
  val signalAircraftSide: Timed<Int>?,
  /** Signal quality as the remote side (sender type 14) reports it */
  val signalRemoteSide: Timed<Int>?,
  val liveRateMbps: Timed<Double>?,
  val aircraftClockMs: Timed<Long>?,
  /** 95th percentile over the last 5 s of the arrival time minus the clock, minus its minimum */
  val clockJitterP95Ms: Double?,
  /** How far the aircraft clock moved against this device's since the series started */
  val clockDriftMs: Double?,
)

data class TelemetryValues(
  val flight: Timed<FlightReading>?,
  val gimbal: Timed<GimbalReading>?,
  val battery: Timed<BatteryReading>?,
  val remoteBatteryPercent: Timed<Int>?,
  val link: LinkReadings,
  val layoutMismatches: Long,
  /** Bodies decoded per catalogue code */
  val decoded: Map<String, Long>,
)

/**
 * Keeps the last value of each catalogued message with its arrival time, the arrival intervals that make a value
 * stale, and the arrival jitter of the aircraft clock.
 *
 * A group is stale after three of its observed intervals, and never before [MIN_STALE_MS]: a stale value is shown
 * greyed with its age rather than as if it were current.
 */
class TelemetryDecoder {
  companion object {
    const val MIN_STALE_MS = 1_500L
    const val STALE_INTERVALS = 3
    const val JITTER_WINDOW_MS = 5_000L
    private const val INTERVAL_SAMPLES = 8
    private const val SIGNAL_AIRCRAFT_SIDE = 9
    private const val SIGNAL_REMOTE_SIDE = 14

    private fun key(set: Int, id: Int): Int = (set shl 8) or id

    private const val FLIGHT = (TelemetryFields.FLIGHT_SET shl 8) or TelemetryFields.FLIGHT_ID
    private const val GIMBAL = (TelemetryFields.GIMBAL_SET shl 8) or TelemetryFields.GIMBAL_ID
    private const val BATTERY = (TelemetryFields.BATTERY_SET shl 8) or TelemetryFields.BATTERY_ID
    private const val REMOTE_BATTERY = (TelemetryFields.REMOTE_BATTERY_SET shl 8) or TelemetryFields.REMOTE_BATTERY_ID
    private const val SIGNAL = (TelemetryFields.SIGNAL_SET shl 8) or TelemetryFields.SIGNAL_ID
    private const val LIVE_RATE = (TelemetryFields.LIVE_RATE_SET shl 8) or TelemetryFields.LIVE_RATE_ID
    private const val CLOCK = (TelemetryFields.CLOCK_SET shl 8) or TelemetryFields.CLOCK_ID
    private const val MODULE_6 = (TelemetryFields.MODULE_SET shl 8) or 6
    private const val MODULE_8 = (TelemetryFields.MODULE_SET shl 8) or 8
  }

  private class Group<T> {
    var value: T? = null
    var atMs = 0L
    private val intervals = ArrayDeque<Long>()

    fun put(next: T, nowMs: Long) {
      if (value != null) {
        intervals.addLast(nowMs - atMs)
        while (intervals.size > INTERVAL_SAMPLES) {
          intervals.removeFirst()
        }
      }
      value = next
      atMs = nowMs
    }

    fun timed(nowMs: Long): Timed<T>? {
      val current = value ?: return null
      val sorted = intervals.sorted()
      val interval = if (sorted.isEmpty()) 0L else sorted[sorted.size / 2]
      val age = nowMs - atMs
      return Timed(current, age, age > max(MIN_STALE_MS, STALE_INTERVALS * interval))
    }

    fun clear() {
      value = null
      atMs = 0
      intervals.clear()
    }
  }

  private val flight = Group<FlightReading>()
  private val gimbal = Group<GimbalReading>()
  private val battery = Group<BatteryReading>()
  private val remoteBattery = Group<Int>()
  private val signalAircraft = Group<Int>()
  private val signalRemote = Group<Int>()
  private val liveRate = Group<Double>()
  private val clock = Group<Long>()
  private val decoded = linkedMapOf<String, Long>()
  private val moduleSeconds = linkedMapOf<Int, Int>()

  /** (arrival ms, arrival minus clock) of the clock series */
  private val offsets = ArrayDeque<LongArray>()
  private var firstMinimum: Long? = null
  private var seriesStartMs: Long? = null
  private var lastClockMs: Long? = null

  var layoutMismatches = 0L
    private set

  /** One control frame; only the catalogued pairs are read */
  fun offer(frame: P3Frame, nowMs: Long) {
    if (frame.encryptionUnsupported || frame.isAcknowledgement) {
      return
    }
    val body = frame.body
    when (key(frame.commandSet, frame.commandId)) {
      FLIGHT -> read(TelemetryCodes.FLIGHT_DATA, TelemetryFields.flight(body)) { flight.put(it, nowMs) }
      GIMBAL -> read(TelemetryCodes.GIMBAL, TelemetryFields.gimbal(body)) { gimbal.put(it, nowMs) }
      BATTERY -> read(TelemetryCodes.BATTERY, TelemetryFields.battery(body)) { battery.put(it, nowMs) }
      REMOTE_BATTERY ->
        read(TelemetryCodes.REMOTE_BATTERY, TelemetryFields.remoteBattery(body)) { remoteBattery.put(it, nowMs) }
      SIGNAL -> read(TelemetryCodes.SIGNAL, TelemetryFields.signal(body)) {
        when (frame.senderType) {
          SIGNAL_AIRCRAFT_SIDE -> signalAircraft.put(it, nowMs)
          SIGNAL_REMOTE_SIDE -> signalRemote.put(it, nowMs)
          else -> Unit
        }
      }
      LIVE_RATE -> read(TelemetryCodes.LIVE_RATE, TelemetryFields.liveRate(body)) { liveRate.put(it, nowMs) }
      CLOCK -> read(TelemetryCodes.AIRCRAFT_CLOCK, TelemetryFields.aircraftClock(body)) {
        clock.put(it, nowMs)
        onClock(it, nowMs)
      }
      MODULE_6, MODULE_8 -> read(TelemetryCodes.MODULE_STATUS, TelemetryFields.moduleSeconds(body)) {
        moduleSeconds[(frame.senderIndex shl 5) or frame.senderType] = it
      }
      else -> Unit
    }
  }

  private fun <T> read(code: String, value: T?, store: (T) -> Unit) {
    if (value == null) {
      layoutMismatches += 1
      return
    }
    decoded[code] = (decoded[code] ?: 0) + 1
    store(value)
  }

  private fun onClock(clockMs: Long, nowMs: Long) {
    val previous = lastClockMs
    lastClockMs = clockMs
    if (previous != null && clockMs < previous) {
      // The aircraft started again: a new series
      offsets.clear()
      firstMinimum = null
      seriesStartMs = null
    }
    if (seriesStartMs == null) {
      seriesStartMs = nowMs
    }
    offsets.addLast(longArrayOf(nowMs, nowMs - clockMs))
    while (offsets.isNotEmpty() && nowMs - offsets.first()[0] > JITTER_WINDOW_MS) {
      offsets.removeFirst()
    }
    val minimum = offsets.minOf { it[1] }
    if (nowMs - (seriesStartMs ?: nowMs) <= JITTER_WINDOW_MS) {
      firstMinimum = minOf(firstMinimum ?: minimum, minimum)
    }
  }

  fun values(nowMs: Long): TelemetryValues {
    var jitter: Double? = null
    var drift: Double? = null
    if (offsets.isNotEmpty()) {
      val minimum = offsets.minOf { it[1] }
      val spread = offsets.map { it[1] - minimum }.sorted()
      jitter = spread[((spread.size - 1) * 0.95).toInt()].toDouble()
      drift = firstMinimum?.let { (minimum - it).toDouble() }
    }
    return TelemetryValues(
      flight = flight.timed(nowMs),
      gimbal = gimbal.timed(nowMs),
      battery = battery.timed(nowMs),
      remoteBatteryPercent = remoteBattery.timed(nowMs),
      link = LinkReadings(
        signalAircraftSide = signalAircraft.timed(nowMs),
        signalRemoteSide = signalRemote.timed(nowMs),
        liveRateMbps = liveRate.timed(nowMs),
        aircraftClockMs = clock.timed(nowMs),
        clockJitterP95Ms = jitter,
        clockDriftMs = drift,
      ),
      layoutMismatches = layoutMismatches,
      decoded = decoded.toMap(),
    )
  }

  /** Senders whose module seconds counter was seen, for the export */
  fun moduleSenders(): Int = moduleSeconds.size

  fun reset() {
    listOf(flight, gimbal, battery, remoteBattery, signalAircraft, signalRemote, liveRate, clock).forEach { it.clear() }
    decoded.clear()
    moduleSeconds.clear()
    offsets.clear()
    firstMinimum = null
    seriesStartMs = null
    lastClockMs = null
    layoutMismatches = 0
  }

  /** A new stream: the clock series starts again, the last values stay with their ages */
  fun newStream() {
    offsets.clear()
    firstMinimum = null
    seriesStartMs = null
    lastClockMs = null
  }
}

/** The codes of the catalogue, which the page turns into words of its own language */
object TelemetryCodes {
  const val FLIGHT_DATA = "flightData"
  const val GIMBAL = "gimbal"
  const val BATTERY = "battery"
  const val REMOTE_BATTERY = "remoteBattery"
  const val SIGNAL = "signal"
  const val LIVE_RATE = "liveRate"
  const val AIRCRAFT_CLOCK = "aircraftClock"
  const val MODULE_STATUS = "moduleStatus"
}
