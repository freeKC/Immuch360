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
 * Read since the second telemetry reading of 24 October 2026 (p2/telemetry-deep-dive-2026-10-24.md, sections 2 to 4)
 * and proven by the flights of 25 October (p2/telemetry-proof-2026-10-25.md, section 4: the 09:42 capture and the
 * afternoon one, two independent pieces of evidence each, the same in both): the height above the lift off point
 * (offset 16, 0.1 m, positive up), the vertical speed (offset 22, 0.1 m/s, positive down on the wire, turned positive up
 * here), the speed over ground from the two horizontal components (offsets 18 and 20, 0.1 m/s along the axes the
 * heading counts from), offset 41 (0.1 m, a smoothed copy of the distance below), the distance below of push 10/3 (mm)
 * and the ring of 360 obstacle distances of push 36/8 (mm), with its index 0 at the nose and its index growing
 * clockwise ([ObstacleRing.MAPPING]). The height and the speeds mean something only in the air (bit 0x04): before lift
 * off the height drifted by -1.2 m and +1.0 m with the motors spinning, and the speeds hold a stale value on the
 * ground, so a pilot reads them only from [FlightReading.inAir] frames.
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
  /**
   * Above the lift off point, positive up, meaningful in the air only; reset to 0 the frame the motors stop, wherever
   * they stop. Not a height above the ground.
   */
  val heightM: Double,
  /** Offsets 18, 20 and 22 as they are on the wire, 0.1 m/s each, for Diagnostics */
  val speedsMps: List<Double>,
  val pitchDeg: Double,
  val rollDeg: Double,
  val headingDeg: Double,
  val mode: Int,
  /** Bit 0x04: set at lift off, cleared at touch down; the height and the speeds a pilot reads come only with it */
  val inAir: Boolean,
  /** Bit 0x08: the motors run, from the spin up 4 to 5 s before lift off to the frame they stop */
  val motorsOn: Boolean,
  val satellites: Int,
  /** Offset 41: a smoothed copy of the distance below, 0.1 m; it holds its old value 0.3 to 0.6 s after a change */
  val groundHeightM: Double,
  val motorTimeS: Double,
  val flags: Long,
  /** Offset 22 with its sign turned: climbing reads positive */
  val verticalSpeedMps: Double = 0.0,
  /** The speed over ground from offsets 18 and 20; it holds a stale value on the ground: read it in the air */
  val horizontalSpeedMps: Double = 0.0,
) {
  /** The height, the vertical speed and the speed as a pilot reads them: in the air only, else null */
  val airborne: FlightReading? get() = takeIf { inAir }
}

/** Push 10/3 from the remote side: the distance below the drone, only while the motors run */
data class RangeBelowReading(
  /** Null when the sensor has no reading (its flag byte is 0 and the distance 0xFFFF) */
  val distanceM: Double?,
)

/**
 * Push 36/8 from sender 18.4: 360 distances around the drone, one per degree in blocks of five, only while the motors
 * run. A sector that sees nothing reads [TelemetryFields.OBSTACLE_NO_READING], which may also be glass, a thin branch
 * or Sport mode: never a clear way.
 */
data class ObstacleReading(
  /** The smallest distance of the ring, null when no sector reads anything */
  val nearestM: Double?,
  /** The index of that distance */
  val nearestIndex: Int?,
  /** Sectors without a reading */
  val noReading: Int,
  /**
   * The 72 sectors of 5 degrees ([ObstacleRing.sectors]) in millimetres, null for a sector with no reading; null for
   * a ring whose count is not 360. Which sector is the nose: [ObstacleRing.MAPPING], proven.
   */
  val sectorsMm: List<Int?>? = null,
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
  const val SIGNAL_BARS_SET = 9
  const val SIGNAL_BARS_ID = 117
  const val SIGNAL_BARS_LENGTH = 1
  const val RANGE_BELOW_SET = 10
  const val RANGE_BELOW_ID = 3
  const val RANGE_BELOW_LENGTH = 4
  const val OBSTACLES_SET = 36
  const val OBSTACLES_ID = 8
  const val OBSTACLES_HEADER = 8

  /** The obstacle ring's value for a sector that reads nothing */
  const val OBSTACLE_NO_READING = 60000
  const val MODULE_SET = 33
  val MODULE_IDS = setOf(6, 8)

  /** The flight mode number of the automatic landing, the one value of that byte the capture explains */
  const val MODE_AUTOMATIC_LANDING = 12
  /**
   * Offset 32 (p2/telemetry-proof-2026-10-25.md, 4.9). Bit 0x08 alone is the motors running: set 0.1 s before the
   * motor time starts and cleared the frame it stops, in three motor runs over two captures; bits 0x04 and 0x08
   * together missed the 4 to 5 s of spin before lift off, when the propellers already turn. Bit 0x04 comes at lift off
   * and goes at touch down: the height and the speeds a pilot reads come only with it.
   */
  const val FLAG_IN_AIR = 0x04L
  const val FLAG_MOTORS_ON = 0x08L

  fun flight(body: ByteArray): FlightReading? {
    if (body.size != FLIGHT_LENGTH) {
      return null
    }
    val flags = u32(body, 32)
    return FlightReading(
      heightM = i16(body, 16) / 10.0,
      speedsMps = listOf(i16(body, 18) / 10.0, i16(body, 20) / 10.0, i16(body, 22) / 10.0),
      // Positive down on the wire: 2 in the five flying frames of the 23 October landing, while the height estimate
      // fell at 0.198 m/s and the range below at 0.216 m/s
      verticalSpeedMps = -i16(body, 22) / 10.0,
      horizontalSpeedMps = kotlin.math.hypot(i16(body, 18).toDouble(), i16(body, 20).toDouble()) / 10.0,
      pitchDeg = i16(body, 24) / 10.0,
      rollDeg = i16(body, 26) / 10.0,
      headingDeg = i16(body, 28) / 10.0,
      mode = u8(body, 30),
      inAir = (flags and FLAG_IN_AIR) != 0L,
      motorsOn = (flags and FLAG_MOTORS_ON) != 0L,
      satellites = u8(body, 36),
      // Tenths of a metre: round(range / 100) of push 10/3 in 2205 of 2496 frames with the motors on, against 3 read as
      // centimetres; the centimetres of 24 October were a hand landing, where offset 41 still showed the floor
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

  /** 0 to 5: 0 before the drone links, then 3, 4, 5 as the signal settles (p2/telemetry-flight-2026-10-24.md, 3.5) */
  fun signalBars(body: ByteArray): Int? =
    if (body.size == SIGNAL_BARS_LENGTH && u8(body, 0) <= 5) u8(body, 0) else null

  /** u16 millimetres, then 1 while the sensor reads and 0 while it does not, then a counter */
  fun rangeBelow(body: ByteArray): RangeBelowReading? {
    if (body.size != RANGE_BELOW_LENGTH) {
      return null
    }
    val reading = u8(body, 2) == 1 && u16(body, 0) != 0xFFFF
    return RangeBelowReading(if (reading) u16(body, 0) / 1000.0 else null)
  }

  /**
   * An eight byte header (1, a counter, two u16 distances whose meaning is not settled, the count of values), then that
   * many u16 distances in millimetres. Any other length is a layout this decoder does not know.
   */
  fun obstacles(body: ByteArray): ObstacleReading? {
    if (body.size < OBSTACLES_HEADER) {
      return null
    }
    val count = u16(body, 6)
    if (count == 0 || body.size != OBSTACLES_HEADER + 2 * count) {
      return null
    }
    var nearest = Int.MAX_VALUE
    var nearestIndex = -1
    var empty = 0
    val values = IntArray(count)
    for (index in 0 until count) {
      val value = u16(body, OBSTACLES_HEADER + 2 * index)
      values[index] = value
      if (value == OBSTACLE_NO_READING) {
        empty += 1
      } else if (value < nearest) {
        nearest = value
        nearestIndex = index
      }
    }
    return ObstacleReading(
      nearestM = if (nearestIndex < 0) null else nearest / 1000.0,
      nearestIndex = nearestIndex.takeIf { it >= 0 },
      noReading = empty,
      sectorsMm = ObstacleRing.sectors(values),
    )
  }

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
  /** 9/117 from the remote side, 0 to 5 */
  val signalBars: Timed<Int>? = null,
  val rangeBelow: Timed<RangeBelowReading>? = null,
  val obstacles: Timed<ObstacleReading>? = null,
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
    private const val SIGNAL_BARS = (TelemetryFields.SIGNAL_BARS_SET shl 8) or TelemetryFields.SIGNAL_BARS_ID
    private const val RANGE_BELOW = (TelemetryFields.RANGE_BELOW_SET shl 8) or TelemetryFields.RANGE_BELOW_ID
    private const val OBSTACLES = (TelemetryFields.OBSTACLES_SET shl 8) or TelemetryFields.OBSTACLES_ID

    /** The sender of the 50 Hz push and of the obstacle ring, 18.4 in our captures */
    private const val SENSING_SENDER = 18
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
  private val signalBars = Group<Int>()
  private val rangeBelow = Group<RangeBelowReading>()
  private val obstacles = Group<ObstacleReading>()
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
      // The remote side only: the same pairs from another sender are not what our captures named
      SIGNAL_BARS -> if (frame.senderType == SIGNAL_REMOTE_SIDE) {
        read(TelemetryCodes.SIGNAL_BARS, TelemetryFields.signalBars(body)) { signalBars.put(it, nowMs) }
      }
      RANGE_BELOW -> if (frame.senderType == SIGNAL_REMOTE_SIDE) {
        read(TelemetryCodes.RANGE_BELOW, TelemetryFields.rangeBelow(body)) { rangeBelow.put(it, nowMs) }
      }
      OBSTACLES -> if (frame.senderType == SENSING_SENDER) {
        read(TelemetryCodes.OBSTACLES, TelemetryFields.obstacles(body)) { obstacles.put(it, nowMs) }
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
      signalBars = signalBars.timed(nowMs),
      rangeBelow = rangeBelow.timed(nowMs),
      obstacles = obstacles.timed(nowMs),
    )
  }

  /** Senders whose module seconds counter was seen, for the export */
  fun moduleSenders(): Int = moduleSeconds.size

  fun reset() {
    listOf(
      flight,
      gimbal,
      battery,
      remoteBattery,
      signalAircraft,
      signalRemote,
      liveRate,
      clock,
      signalBars,
      rangeBelow,
      obstacles,
    ).forEach { it.clear() }
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
  const val SIGNAL_BARS = "signalBars"
  const val RANGE_BELOW = "rangeBelow"
  const val OBSTACLES = "obstacles"
}
