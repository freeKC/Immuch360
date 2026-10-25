package app.alextran.immich.djilink

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Which sector of the obstacle ring is the drone's nose, and whether the sectors grow clockwise seen from above. Its
 * status is the gate row obstacleSide of dji_live_fields.dart: Kotlin never reads that gate, Flutter turns it into
 * [RingSettings.directional].
 */
data class RingMapping(val noseSector: Int, val clockwise: Boolean)

/** What the pilot chose for the ring: "Glow from", "Strong glow from", and whether the side is drawn */
data class RingSettings(
  val farM: Double = DEFAULT_FAR_M,
  val nearM: Double = DEFAULT_NEAR_M,
  /** The arcs on the obstacle's side; false is one even glow all around the picture */
  val directional: Boolean = false,
) {
  companion object {
    const val DEFAULT_FAR_M = 3.0
    const val DEFAULT_NEAR_M = 1.0

    /**
     * Down to 1.0 m and 0.25 m for a room: in the 09:42 indoor hover every reading was 0.29 to 1.44 m, so at 1.5 m the
     * ring glowed the whole flight (p2/review-obstacle-ring-2026-10-25.md, major 2)
     */
    const val MIN_FAR_M = 1.0
    const val MAX_FAR_M = 6.0
    const val MIN_NEAR_M = 0.25
    const val MAX_NEAR_M = 2.5

    /** "Strong glow from" stays at least this far under "Glow from" */
    const val MIN_GAP_M = 0.5
  }

  /** Within the steppers of Advanced, "Strong glow from" at least [MIN_GAP_M] under "Glow from" */
  fun clamped(): RingSettings {
    val far = (if (farM.isNaN()) DEFAULT_FAR_M else farM).coerceIn(MIN_FAR_M, MAX_FAR_M)
    val near = (if (nearM.isNaN()) DEFAULT_NEAR_M else nearM).coerceIn(MIN_NEAR_M, min(MAX_NEAR_M, far - MIN_GAP_M))
    return copy(farM = far, nearM = near)
  }

  /** Halfway between the two distances: the tick starts there */
  val middleM: Double get() = (farM + nearM) / 2
}

/** One arc of the ring, as every screen draws it */
data class RingArc(
  /** Degrees from the nose, positive to the right, -180 to 180; null for the even glow all around the picture */
  val centreDeg: Double?,
  val distanceM: Double,
  /** 0 at "Glow from", 1 at "Strong glow from" and closer */
  val strength: Double,
  /** Never opaque: the picture stays readable under it */
  val opacity: Double,
  val argb: Int,
)

/**
 * The obstacle ring of push 36/8 turned into arcs (p2/design-obstacle-ring-2026-10-25.md, 2.2 and 2.3): the 72
 * sectors, the bearing of each, which ones are close (with a hysteresis), and the arcs drawn for them, the same on the
 * phone, the TV and the headset. Pure: it reads, decides and draws, and never reaches the remote or the drone.
 */
object ObstacleRing {
  const val VALUES = 360
  const val SECTORS = 72
  const val SECTOR_DEG = 5

  /**
   * The nose at sector 0, the sectors growing clockwise: proven by the two flights of 25 October, the 09:42 capture and
   * the afternoon one, the same in both (p2/telemetry-proof-2026-10-25.md, 4.7 and 4.8). The camera picture shows the
   * heading grows on a turn to the right; turns of 80 to 100 degrees in place move the ring by -heading change / 5
   * sectors within 3 sectors in 12 of 13 turns and 4 of 4 (a right turn of +82 degrees: -16 to -19 sectors, what was
   * ahead ends on the left); the ring predicted from the 50 Hz displacement fits best with the nose at sector 0 and
   * the sectors growing with the heading; flying forward, the nose sector shrank by the distance flown in 8 of 10 legs
   * and 5 of 6. Not tested: a wall at a known distance.
   */
  val MAPPING = RingMapping(noseSector = 0, clockwise = true)

  /** A close sector stays close until it is this much past "Glow from" */
  const val HYSTERESIS_M = 0.3

  /** Arcs at most, nearest first */
  const val MAX_ARCS = 4

  /** The close sectors this near an arc's centre belong to that arc */
  const val SET_ASIDE_DEG = 45.0

  const val FAINT_OPACITY = 0.15
  const val STRONG_OPACITY = 0.70

  /**
   * The even glow lights all four edges and says no side: half as strong at most, so that a room, whose walls are
   * always close, is a soft frame rather than a red one (p2/review-obstacle-ring-2026-10-25.md, major 2)
   */
  const val EVEN_STRONG_OPACITY = 0.35

  /** djiLiveAmber and djiLiveRed, the two colours of the live screen */
  const val AMBER = 0xFFFFB300.toInt()
  const val RED = 0xFFE53935.toInt()

  /** The last arcs once the data stopped: white, faint, fading */
  const val WHITE = 0xFFFFFFFF.toInt()
  const val STOPPED_OPACITY = 0.25

  /**
   * The tick with the side: every second halfway between the distances, every 250 ms at "Strong glow from", 150 ms at
   * half of it. With the even glow: every second at "Strong glow from", 150 ms at half of it.
   */
  const val TICK_MIDDLE_MS = 1_000
  const val TICK_NEAR_MS = 250
  const val TICK_CLOSEST_MS = 150

  /** "Show a sample": eight seconds of a made up ring */
  const val SAMPLE_MS = 8_000L

  /**
   * The 72 sectors of a ring of 360 values: sector k is the smallest reading among indexes 5k-2 to 5k+2 (the values
   * come in blocks of five, the first one over indexes 358 to 2), null when all five read nothing. Null for a ring of
   * any other count.
   */
  fun sectors(values: IntArray): List<Int?>? {
    if (values.size != VALUES) {
      return null
    }
    return List(SECTORS) { sector ->
      var best: Int? = null
      for (offset in -2..2) {
        val value = values[Math.floorMod(SECTOR_DEG * sector + offset, VALUES)]
        if (value != TelemetryFields.OBSTACLE_NO_READING && (best == null || value < best)) {
          best = value
        }
      }
      best
    }
  }

  /** -180 (excluded) to 180 */
  fun normalize(degrees: Double): Double {
    var value = degrees % 360.0
    if (value > 180.0) {
      value -= 360.0
    }
    if (value <= -180.0) {
      value += 360.0
    }
    return value
  }

  /** The angle between two bearings, 0 to 180 */
  fun separation(a: Double, b: Double): Double = abs(normalize(a - b))

  /** 0 is the front, 90 the right, 180 the back, -90 the left */
  fun bearingDeg(sector: Int, mapping: RingMapping = MAPPING): Double {
    val steps = (sector - mapping.noseSector) * SECTOR_DEG * (if (mapping.clockwise) 1 else -1)
    return normalize(steps.toDouble())
  }

  /** The sector whose bearing is nearest [bearingDeg] */
  fun sectorAt(bearingDeg: Double, mapping: RingMapping = MAPPING): Int {
    val steps = (normalize(bearingDeg) / SECTOR_DEG).roundToInt() * (if (mapping.clockwise) 1 else -1)
    return Math.floorMod(mapping.noseSector + steps, SECTORS)
  }

  fun strength(distanceM: Double, settings: RingSettings): Double =
    ((settings.farM - distanceM) / (settings.farM - settings.nearM)).coerceIn(0.0, 1.0)

  /** 0.15 faint to 0.70 strong, or to 0.35 for the even glow: never opaque */
  fun opacity(strength: Double, even: Boolean = false): Double =
    FAINT_OPACITY + ((if (even) EVEN_STRONG_OPACITY else STRONG_OPACITY) - FAINT_OPACITY) * strength.coerceIn(0.0, 1.0)

  /** Amber at 0 to red at 1, mixed per channel */
  fun argb(strength: Double): Int {
    val s = strength.coerceIn(0.0, 1.0)
    fun channel(shift: Int): Int {
      val from = (AMBER shr shift) and 0xFF
      val to = (RED shr shift) and 0xFF
      return (from + (to - from) * s).roundToInt() and 0xFF
    }
    return (0xFF shl 24) or (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
  }

  /** An arc with no bearing is the even glow, and takes its softer opacity */
  fun arc(centreDeg: Double?, distanceM: Double, settings: RingSettings): RingArc {
    val strength = strength(distanceM, settings)
    return RingArc(centreDeg, distanceM, strength, opacity(strength, even = centreDeg == null), argb(strength))
  }

  /** The sectors close enough to glow: one joins at [farM] or closer, and leaves once past [farM] + [HYSTERESIS_M] */
  fun closeSectors(distancesM: List<Double?>, previous: Set<Int>, farM: Double): Set<Int> =
    distancesM.indices.filterTo(mutableSetOf()) { sector ->
      val distance = distancesM[sector]
      distance != null && distance <= (if (sector in previous) farM + HYSTERESIS_M else farM)
    }

  /**
   * The arcs of the close sectors, nearest first. With the side, the closest gives an arc centred on its bearing, the
   * close sectors within [SET_ASIDE_DEG] of it are set aside, and again on what is left, [MAX_ARCS] at most. Without
   * the side, one arc with no bearing, from the nearest. A sector with no reading is never drawn, and never clear.
   */
  fun arcs(
    distancesM: List<Double?>,
    close: Set<Int>,
    settings: RingSettings,
    mapping: RingMapping = MAPPING,
  ): List<RingArc> {
    val candidates = close
      .mapNotNull { sector -> distancesM.getOrNull(sector)?.let { sector to it } }
      .sortedWith(compareBy({ it.second }, { it.first }))
    if (candidates.isEmpty()) {
      return emptyList()
    }
    if (!settings.directional) {
      return listOf(arc(null, candidates.first().second, settings))
    }
    val left = candidates.toMutableList()
    val arcs = mutableListOf<RingArc>()
    while (left.isNotEmpty() && arcs.size < MAX_ARCS) {
      val (sector, distance) = left.first()
      val bearing = bearingDeg(sector, mapping)
      arcs += arc(bearing, distance, settings)
      left.removeAll { separation(bearingDeg(it.first, mapping), bearing) <= SET_ASIDE_DEG }
    }
    return arcs
  }

  /**
   * How often the tick sounds, 0 for silence. With the side: nothing farther than halfway between the two distances,
   * 1000 ms there, falling in a straight line to 250 ms at "Strong glow from", then to 150 ms at half of it and closer.
   * With the even glow, which says no side and in a room lasts the whole flight: nothing farther than "Strong glow
   * from", 1000 ms there, falling in a straight line to 150 ms at half of it. A 30 ms tick every 150 ms at most: never
   * more than a fifth of the time sounding.
   */
  fun tickIntervalMs(nearestM: Double?, settings: RingSettings, even: Boolean = false): Int {
    val distance = nearestM ?: return 0
    val middle = settings.middleM
    val near = settings.nearM
    if (even) {
      return when {
        distance > near -> 0
        distance > near / 2 ->
          (TICK_CLOSEST_MS + (distance - near / 2) / (near / 2) * (TICK_MIDDLE_MS - TICK_CLOSEST_MS)).roundToInt()
        else -> TICK_CLOSEST_MS
      }
    }
    return when {
      distance > middle -> 0
      distance >= near -> (TICK_NEAR_MS + (distance - near) / (middle - near) * (TICK_MIDDLE_MS - TICK_NEAR_MS))
        .roundToInt()
      distance > near / 2 -> (TICK_CLOSEST_MS + (distance - near / 2) / (near / 2) * (TICK_NEAR_MS - TICK_CLOSEST_MS))
        .roundToInt()
      else -> TICK_CLOSEST_MS
    }
  }

  /**
   * The made up ring of "Show a sample" at [tMs] from its start, in millimetres per sector, placed with [mapping] so
   * that it is drawn where a real one would be: an obstacle ahead from 4.0 m to 0.8 m (0 to 3 s), moving to the left
   * at 0.8 m (3 to 5 s), a second one behind on the right at 2.0 m (5 to 7 s), then nothing (7 to 8 s). Null once the
   * sample is over. Never relayed, never saved.
   */
  fun sample(tMs: Long, mapping: RingMapping = MAPPING): List<Int?>? {
    if (tMs < 0 || tMs >= SAMPLE_MS) {
      return null
    }
    val obstacles = mutableListOf<Pair<Double, Double>>()
    when {
      tMs < 3_000 -> obstacles += 0.0 to 4.0 - 3.2 * tMs / 3_000.0
      tMs < 5_000 -> obstacles += -90.0 * (tMs - 3_000) / 2_000.0 to 0.8
      tMs < 7_000 -> {
        obstacles += -90.0 to 0.8
        obstacles += 135.0 to 2.0
      }
    }
    val sectors = MutableList<Int?>(SECTORS) { null }
    for ((bearing, metres) in obstacles) {
      val centre = sectorAt(bearing, mapping)
      // A small object: its centre nearest, two sectors on each side a little farther
      for (offset in -2..2) {
        val sector = Math.floorMod(centre + offset, SECTORS)
        val millimetres = (metres * (1 + 0.1 * abs(offset)) * 1_000).roundToInt()
        sectors[sector] = min(sectors[sector] ?: Int.MAX_VALUE, millimetres)
      }
    }
    return sectors
  }
}

/**
 * Where the arcs fall on a picture's border (p2/design-obstacle-ring-2026-10-25.md, 2.2 and 2.4): front on the top
 * edge, right on the right edge, back on the bottom, left on the left. The picture is taken as a square, so each edge
 * holds exactly 90 degrees whatever its shape. Shared by the Quest's halo; Flutter has the same rules in
 * dji_live_obstacle.widget.dart.
 */
object RingGeometry {
  /** An arc weighs nothing this far from its centre: about 90 degrees wide at half its weight and more */
  const val WINDOW_HALF_DEG = 60.0

  /** A faint arc is this part of the full depth, a strong one all of it */
  const val FAINT_DEPTH = 0.6

  enum class Edge { TOP, RIGHT, BOTTOM, LEFT }

  /** A piece of an edge, from [from] to [to] along it (0 to 1, clockwise from its first corner), and its glow */
  data class Segment(
    val edge: Edge,
    val from: Double,
    val to: Double,
    val alpha: Double,
    val argb: Int,
    val strength: Double,
  )

  /** The point of the border of a box [width] by [height] that [bearingDeg] points at, from its top left corner */
  fun borderPoint(bearingDeg: Double, width: Double, height: Double): Pair<Double, Double> {
    val radians = Math.toRadians(bearingDeg)
    val dx = sin(radians)
    val dy = -cos(radians)
    val scale = 1.0 / max(abs(dx), abs(dy))
    return width / 2 * (1 + dx * scale) to height / 2 * (1 + dy * scale)
  }

  /** The bearing of a point of the box, read through the square: the inverse of [borderPoint] on the border */
  fun bearingOf(x: Double, y: Double, width: Double, height: Double): Double {
    val u = (x - width / 2) / (width / 2)
    val v = (y - height / 2) / (height / 2)
    return Math.toDegrees(atan2(u, -v))
  }

  /** The weight of an arc [offsetDeg] from its centre: 1 there, 0.5 at 30 degrees, about 0.15 at 45, 0 from 60 */
  fun window(offsetDeg: Double): Double {
    val offset = abs(offsetDeg)
    return if (offset >= WINDOW_HALF_DEG) 0.0 else 0.5 * (1 + cos(PI * offset / WINDOW_HALF_DEG))
  }

  /** How deep the glow goes: thin when faint, the whole [fullDepth] when strong */
  fun depth(strength: Double, fullDepth: Double): Double =
    fullDepth * (FAINT_DEPTH + (1 - FAINT_DEPTH) * strength.coerceIn(0.0, 1.0))

  /** The two ends of [edge] in a box, clockwise */
  fun corners(edge: Edge, width: Double, height: Double): Pair<Pair<Double, Double>, Pair<Double, Double>> =
    when (edge) {
      Edge.TOP -> (0.0 to 0.0) to (width to 0.0)
      Edge.RIGHT -> (width to 0.0) to (width to height)
      Edge.BOTTOM -> (width to height) to (0.0 to height)
      Edge.LEFT -> (0.0 to height) to (0.0 to 0.0)
    }

  /**
   * The glow of [arcs] cut into [perEdge] pieces per edge: at the middle of each piece, the arc that weighs most gives
   * the alpha (its opacity times its window) and the colour; where arcs meet the larger wins, they never add up. The
   * even glow (an arc with no bearing) is the same on every piece. Pieces with nothing to draw are left out.
   */
  fun segments(arcs: List<RingArc>, width: Double, height: Double, perEdge: Int): List<Segment> {
    if (arcs.isEmpty() || perEdge <= 0) {
      return emptyList()
    }
    val segments = mutableListOf<Segment>()
    for (edge in Edge.entries) {
      val (start, end) = corners(edge, width, height)
      for (index in 0 until perEdge) {
        val from = index.toDouble() / perEdge
        val to = (index + 1).toDouble() / perEdge
        val middle = (from + to) / 2
        val x = start.first + (end.first - start.first) * middle
        val y = start.second + (end.second - start.second) * middle
        val bearing = bearingOf(x, y, width, height)
        var best: RingArc? = null
        var bestAlpha = 0.0
        for (arc in arcs) {
          val centre = arc.centreDeg
          val alpha = arc.opacity * (if (centre == null) 1.0 else window(ObstacleRing.separation(bearing, centre)))
          if (alpha > bestAlpha) {
            bestAlpha = alpha
            best = arc
          }
        }
        val chosen = best ?: continue
        segments += Segment(edge, from, to, bestAlpha, chosen.argb, chosen.strength)
      }
    }
    return segments
  }
}
