package app.alextran.immich.immersive

import com.meta.spatial.core.Vector3
import com.meta.spatial.runtime.ButtonBits
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * The grip of one hand, and its bit in the buttons a controller holds: the left controller holds ButtonSqueezeL, the
 * right one ButtonSqueezeR.
 */
internal enum class GripSide(val bit: Int) {
  LEFT(ButtonBits.ButtonSqueezeL),
  RIGHT(ButtonBits.ButtonSqueezeR),
}

/**
 * The grips on a flat screen of the viewer (a photo on the stereo quad or its compositor layer, a video on the flat
 * video screen), read from the buttons held at every frame. The idea of moving and resizing the flat screens with the
 * grips is Gaurav Mukherjee's (gmfun/Immuch360, branch quest/flat-3d); the mapping is ours, decided by FreeKC on 29
 * October so that the grip keeps showing the info panel:
 * - a short press of either grip, released before [HOLD_MS], shows or hides the info panel, on its release;
 * - a grip held [HOLD_MS] or more while its ray points at the screen grabs it ([Event.GrabStart]): the viewer moves the
 *   screen with that ray until the grip is released ([Event.GrabEnd]); held away from the screen it does nothing until
 *   the ray reaches the screen, and its release does nothing either;
 * - both grips held stretch the screen ([Event.StretchStart]), its width following the spread of the hands (see
 *   [ScreenStretch]), until either is released ([Event.StretchEnd]); a grab in progress becomes the stretch;
 * - a grip that took part in a grab or a stretch does nothing more until it is released.
 * Pure: the viewer gives the time, the buttons held and which ray points at the screen. Unit tested.
 */
internal class ScreenGrip(private val holdMs: Long = HOLD_MS) {
  sealed interface Event {
    data object TogglePanel : Event

    data class GrabStart(val side: GripSide) : Event

    data class GrabEnd(val side: GripSide) : Event

    data object StretchStart : Event

    data object StretchEnd : Event
  }

  private class Grip {
    /** When the grip went down (uptime ms), null while it is up. */
    var downAt: Long? = null

    /** The press went into a grab or a stretch, or was cut by [cancel]: its release does nothing. */
    var spent = false
  }

  private val grips = GripSide.entries.associateWith { Grip() }

  /** The grip that holds the screen now, null when none does. */
  var grabbing: GripSide? = null
    private set

  /** Both grips stretch the screen now. */
  var stretching = false
    private set

  /**
   * What the grips held at [nowMs] (uptime ms) start or end, given the buttons [heldBits] held by all the controllers
   * and whether the ray of each side points at the screen now ([pointsAtScreen], asked only when a grab may start).
   */
  fun update(nowMs: Long, heldBits: Int, pointsAtScreen: (GripSide) -> Boolean): List<Event> {
    val events = mutableListOf<Event>()
    for ((side, grip) in grips) {
      val held = (heldBits and side.bit) != 0
      val downAt = grip.downAt
      if (held && downAt == null) {
        grip.downAt = nowMs
        grip.spent = false
      } else if (!held && downAt != null) {
        events += release(side, grip, nowMs - downAt)
      }
    }
    val bothDown = grips.values.all { it.downAt != null }
    if (bothDown && !stretching) {
      grabbing?.let { events += Event.GrabEnd(it) }
      grabbing = null
      stretching = true
      grips.values.forEach { it.spent = true }
      events += Event.StretchStart
    }
    if (!stretching && grabbing == null) {
      for ((side, grip) in grips) {
        val downAt = grip.downAt ?: continue
        if (grip.spent || nowMs - downAt < holdMs || !pointsAtScreen(side)) continue
        grip.spent = true
        grabbing = side
        events += Event.GrabStart(side)
        break
      }
    }
    return events
  }

  /** What the release of [side], down [heldMs], ends: a stretch, its grab, or a short press. */
  private fun release(side: GripSide, grip: Grip, heldMs: Long): List<Event> {
    val spent = grip.spent
    grip.downAt = null
    grip.spent = false
    return when {
      stretching -> {
        stretching = false
        listOf(Event.StretchEnd)
      }
      grabbing == side -> {
        grabbing = null
        listOf(Event.GrabEnd(side))
      }
      !spent && heldMs < holdMs -> listOf(Event.TogglePanel)
      else -> emptyList()
    }
  }

  /**
   * The flat screen went away (another media, the viewer closing): a grab or a stretch ends, and the grips still held
   * do nothing until they are released.
   */
  fun cancel(): List<Event> {
    val events = mutableListOf<Event>()
    grabbing?.let { events += Event.GrabEnd(it) }
    if (stretching) events += Event.StretchEnd
    grabbing = null
    stretching = false
    grips.values.forEach { if (it.downAt != null) it.spent = true }
    return events
  }

  /**
   * Starts again from the grips held now, [heldBits], when the viewer starts or stops following a flat screen: a grab
   * or a stretch ends, a grip held stays spent until its release (its press went elsewhere: on a sphere the grip shows
   * or hides the panel as it goes down), and a grip up is forgotten.
   */
  fun reset(heldBits: Int): List<Event> {
    val events = cancel()
    for ((side, grip) in grips) {
      if ((heldBits and side.bit) != 0) {
        if (grip.downAt == null) grip.downAt = 0L
        grip.spent = true
      } else {
        grip.downAt = null
        grip.spent = false
      }
    }
    return events
  }

  companion object {
    /** A grip held this long or more is no short press: it grabs the screen it points at. */
    const val HOLD_MS = 300L
  }
}

/**
 * Where a flat screen stands: [distance] meters from the [eyes] it was placed from, horizontally, in the direction
 * [yawDeg] (0 along +z, 90 along +x, the Spatial SDK being left handed with +x right, +y up, +z forward), its center at
 * the height [height]. It stands upright and faces the eyes, the way the stereo quad and the flat video screen always
 * did; a grab moves it around the eyes it was placed from (see [ScreenDrag]), so that it stays where the user put it
 * in the room.
 */
internal data class ScreenPlace(val eyes: Vector3, val yawDeg: Float, val height: Float, val distance: Float) {
  /** The horizontal direction from the eyes to the screen, normalized. */
  val direction: Vector3
    get() {
      val yaw = Math.toRadians(yawDeg.toDouble())
      return Vector3(sin(yaw).toFloat(), 0f, cos(yaw).toFloat())
    }

  /** The center of the screen. */
  val center: Vector3
    get() {
      val direction = direction
      return Vector3(eyes.x + direction.x * distance, height, eyes.z + direction.z * distance)
    }

  /**
   * The same screen [distance] meters away: in the same direction, and seen at the same angle above or below the eyes,
   * so that a screen raised by a grab stays raised as it comes nearer.
   */
  fun at(distance: Float): ScreenPlace =
    copy(distance = distance, height = eyes.y + (height - eyes.y) * distance / this.distance)

  companion object {
    /**
     * A screen [distance] meters along the horizontal part of [forward] (the gaze), at the height of [eyes]; along +z
     * for a gaze straight up or down.
     */
    fun inFront(eyes: Vector3, forward: Vector3, distance: Float): ScreenPlace {
      val flat = sqrt(forward.x * forward.x + forward.z * forward.z)
      val yaw = if (flat < 1e-3f) 0f else Math.toDegrees(atan2(forward.x, forward.z).toDouble()).toFloat()
      return ScreenPlace(Vector3(eyes.x, eyes.y, eyes.z), yaw, eyes.y, distance)
    }
  }
}

/**
 * A grab of the flat screen [start] by a ray from [origin] along [direction]: the ray meets the upright cylinder of
 * the distance of the screen around its eyes, and the screen follows that point, the offset between the point grabbed
 * and its center kept, so that the part of the screen under the ray stays under it. The height stays within
 * MAX_ELEVATION of the distance above or below the eyes. Pure, unit tested.
 */
internal class ScreenDrag(private val start: ScreenPlace, origin: Vector3, direction: Vector3) {
  private val grabbed = FlatScreenGeometry.onCylinder(start, origin, direction)
  private val yawOffset = if (grabbed != null) start.yawDeg - grabbed.first else 0f
  private val heightOffset = if (grabbed != null) start.height - grabbed.second else 0f

  /** Where the screen goes for the ray from [origin] along [direction] now; null when that ray meets no cylinder. */
  fun place(origin: Vector3, direction: Vector3): ScreenPlace? {
    val (yaw, height) = FlatScreenGeometry.onCylinder(start, origin, direction) ?: return null
    val reach = start.distance * FlatScreenGeometry.MAX_ELEVATION
    return start.copy(
      yawDeg = FlatScreenGeometry.normalizeDegrees(yaw + yawOffset),
      height = (height + heightOffset).coerceIn(start.eyes.y - reach, start.eyes.y + reach),
    )
  }
}

/**
 * The two handed stretch of a flat screen: both grips held (see [ScreenGrip]), the hands pulled apart or brought
 * together scale its width by the ratio of their spread to the spread when the stretch began. Gaurav Mukherjee's idea
 * and first version (gmfun/Immuch360, branch quest/flat-3d, commit 50a3cdd97). Pure, unit tested.
 */
internal class ScreenStretch {
  private var startSpread = 0f
  private var startWidth = 0f
  private var active = false

  /** The stretch begins with the hands [spread] meters apart and the screen [width] meters wide. */
  fun start(spread: Float, width: Float) {
    startSpread = max(spread, MIN_SPREAD_M)
    startWidth = width
    active = true
  }

  /** The width in meters for the hands [spread] meters apart now, null when no stretch is going on. */
  fun width(spread: Float): Float? = if (active) startWidth * max(spread, MIN_SPREAD_M) / startSpread else null

  fun end() {
    active = false
  }

  companion object {
    /** Hands closer than this (one over the other) count as this far apart: no division by nothing. */
    const val MIN_SPREAD_M = 0.05f
  }
}

/**
 * The geometry of the flat screens: what a ray points at, the distances and the sizes a screen takes. Its size is the
 * angle its width covers from the eyes ("Size 48°"), its distance one of [DISTANCES_M] ("Distance 2 m"); a screen
 * brought nearer keeps its width in meters, as a real one would. The steps, bounds and the keeping of the width are
 * those of Gaurav Mukherjee's Size and Distance rows (gmfun/Immuch360, branch quest/flat-3d, commit d47f56f6a). Pure,
 * unit tested.
 */
internal object FlatScreenGeometry {
  /** Where a new flat screen goes, in meters from the eyes: the distance of the stereo quad. */
  const val DEFAULT_DISTANCE_M = 2f

  /** The distances the thumbstick and the Distance buttons step through, in meters. */
  val DISTANCES_M = floatArrayOf(0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f, 2.5f, 3f, 4f, 5f, 6f, 8f)

  /** What the Size buttons change the angular width by, and its bounds. */
  const val ANGLE_STEP_DEG = 6f
  const val MIN_ANGLE_DEG = 15f
  const val MAX_ANGLE_DEG = 110f

  /** The box a new screen fits in, as angles from the eyes: a large screen still seen whole. */
  const val FIT_WIDTH_DEG = 60f
  const val FIT_HEIGHT_DEG = 40f

  /** A ray this close to the edges of a screen still points at it: easier to grab. */
  const val HIT_MARGIN_M = 0.1f

  /** A grab keeps the center of the screen this much of its distance above or below the eyes at most. */
  const val MAX_ELEVATION = 0.8f

  /**
   * Whether the ray from [origin] along [direction] meets the screen at [place], [width] x [height] meters, within
   * [margin] of its edges, in front of the origin.
   */
  fun hits(
    place: ScreenPlace,
    width: Float,
    height: Float,
    origin: Vector3,
    direction: Vector3,
    margin: Float = HIT_MARGIN_M,
  ): Boolean {
    val normal = place.direction
    val along = direction.x * normal.x + direction.y * normal.y + direction.z * normal.z
    if (abs(along) < 1e-6f) return false
    val center = place.center
    val toCenter =
      (center.x - origin.x) * normal.x + (center.y - origin.y) * normal.y + (center.z - origin.z) * normal.z
    val t = toCenter / along
    if (t <= 0f) return false
    val hitX = origin.x + direction.x * t - center.x
    val hitY = origin.y + direction.y * t - center.y
    val hitZ = origin.z + direction.z * t - center.z
    // The right of a user facing the screen: Up x normal, as Quaternion.lookRotation places the local +x
    val lateral = hitX * normal.z - hitZ * normal.x
    return abs(lateral) <= width / 2 + margin && abs(hitY) <= height / 2 + margin
  }

  /**
   * Where the ray from [origin] along [direction] leaves the upright cylinder of radius [ScreenPlace.distance] around
   * the eyes of [place]: its direction from the eyes ([ScreenPlace.yawDeg]) and its height. Null for a ray straight up
   * or down, or one that meets it behind the origin only.
   */
  fun onCylinder(place: ScreenPlace, origin: Vector3, direction: Vector3): Pair<Float, Float>? {
    val ox = origin.x - place.eyes.x
    val oz = origin.z - place.eyes.z
    val a = direction.x * direction.x + direction.z * direction.z
    if (a < 1e-8f) return null
    val b = 2 * (ox * direction.x + oz * direction.z)
    val c = ox * ox + oz * oz - place.distance * place.distance
    val discriminant = b * b - 4 * a * c
    if (discriminant < 0f) return null
    val t = (-b + sqrt(discriminant)) / (2 * a)
    if (t <= 0f) return null
    val x = ox + direction.x * t
    val z = oz + direction.z * t
    val yaw = Math.toDegrees(atan2(x, z).toDouble()).toFloat()
    return yaw to origin.y + direction.y * t
  }

  /** [degrees] within -180 to 180. */
  fun normalizeDegrees(degrees: Float): Float {
    val wrapped = ((degrees % 360f) + 360f) % 360f
    return if (wrapped > 180f) wrapped - 360f else wrapped
  }

  /** The distance after a push farther ([step] 1) or nearer (-1), from the nearest one of [DISTANCES_M]. */
  fun nextDistance(distance: Float, step: Int): Float {
    val index = DISTANCES_M.indices.minBy { abs(DISTANCES_M[it] - distance) }
    return DISTANCES_M[(index + step).coerceIn(0, DISTANCES_M.lastIndex)]
  }

  /** The angular width after a push larger ([step] 1) or smaller (-1), within [MIN_ANGLE_DEG] and [maxAngleDeg]. */
  fun nextAngle(angleDeg: Float, step: Int, maxAngleDeg: Float = MAX_ANGLE_DEG): Float =
    (angleDeg + step * ANGLE_STEP_DEG).coerceIn(MIN_ANGLE_DEG, maxAngleDeg)

  /** Width in meters of a screen [angleDeg] wide at [distance]. */
  fun width(angleDeg: Float, distance: Float): Float = 2f * distance * tan(Math.toRadians(angleDeg / 2.0)).toFloat()

  /** The angle a screen [width] meters wide covers at [distance]. */
  fun angleForWidth(width: Float, distance: Float): Float =
    Math.toDegrees(2 * atan(width / (2.0 * distance))).toFloat()

  /**
   * The angular width at [to] meters of a screen [angleDeg] wide at [from]: the same width in meters, so that it looks
   * larger nearer and smaller farther, within [MIN_ANGLE_DEG] and [maxAngleDeg].
   */
  fun angleAtDistance(angleDeg: Float, from: Float, to: Float, maxAngleDeg: Float = MAX_ANGLE_DEG): Float =
    angleForWidth(width(angleDeg, from), to).coerceIn(MIN_ANGLE_DEG, maxAngleDeg)

  /**
   * The angular width a new screen of [aspect] (width over height; 16:9 when unknown) opens at: as wide as fits in
   * [FIT_WIDTH_DEG] x [FIT_HEIGHT_DEG], so that a portrait photo or video is not taller than the view.
   */
  fun fittingAngle(aspect: Float): Float {
    val shape = if (aspect > 0f) aspect else 16f / 9f
    val halfHeight = tan(Math.toRadians(FIT_HEIGHT_DEG / 2.0))
    val heightBound = Math.toDegrees(2 * atan(halfHeight * shape)).toFloat()
    return min(FIT_WIDTH_DEG, heightBound)
  }

  /** A distance as the Distance label shows it, in the numbers of [locale]: "2", "1.5", "0.75" ("1,5" in French). */
  fun meters(distance: Float, locale: Locale = Locale.ROOT): String {
    val format = NumberFormat.getNumberInstance(locale)
    format.maximumFractionDigits = 2
    format.minimumFractionDigits = 0
    format.isGroupingUsed = false
    return format.format(distance.toDouble())
  }
}
