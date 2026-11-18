package app.alextran.immich.spherical

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

/**
 * Where the 360° video player of the phones looks, in degrees, with the conventions of the 360° photo viewer of
 * Flutter (panorama_viewer.widget.dart): [longitude] grows to the right, [latitude] grows upwards and stays within the
 * poles, [fov] is the field of view across the longer side of the screen.
 */
internal data class SphereLook(
  val longitude: Float = 0f,
  val latitude: Float = 0f,
  val fov: Float = SphereLookMath.DEFAULT_FOV,
)

/**
 * The pure part of [SphereLookController], unit tested: the drags, the pinch, the double tap and the gyroscope of the
 * 360° photo viewer applied to the 360° video player (issue 20), and the view matrix it hands to Media3's spherical
 * renderer.
 *
 * The view is a longitude and a latitude, never a rotation built up from the previous one: the latitude is clamped at
 * the poles, so a drag reaches straight up and straight down and the view never flips over, and there is no roll, so
 * the horizon stays level. The gyroscope adds its turns to the same two angles, as the photo viewer does
 * (applyGyroRotation in Dart), rather than replacing the view with the attitude of the phone: off, nothing of the
 * motion of the phone reaches the view.
 */
internal object SphereLookMath {
  /** The field of view the player opens with, and goes back to with a double tap once zoomed in: the photo viewer's */
  const val DEFAULT_FOV = 90f

  /** The limits of the pinch, the photo viewer's */
  const val MIN_FOV = 15f
  const val MAX_FOV = 115f

  /** Where a double tap zooms in to, the photo viewer's */
  const val DOUBLE_TAP_FOV = 45f

  /**
   * Pixels of drag per degree at the default field of view: Media3's PX_PER_DEGREES, the speed of the drags before
   * issue 20 (see [RemoteLookMath.PX_PER_DEGREE]). Zoomed in, a drag turns slower, so that the picture still follows the
   * finger, as in the photo viewer.
   */
  const val PX_PER_DEGREE = RemoteLookMath.PX_PER_DEGREE

  /** Slower rotations of the gyroscope, in rad/s, are sensor noise: the photo viewer's threshold */
  const val GYRO_NOISE_THRESHOLD = 0.005f

  /** The duration of the double tap zoom, the photo viewer's */
  const val ZOOM_ANIMATION_MS = 250L

  /** The rotations of the display, Surface.ROTATION_0 to ROTATION_270, without Android classes for the tests */
  const val ROTATION_0 = 0
  const val ROTATION_90 = 1
  const val ROTATION_180 = 2
  const val ROTATION_270 = 3

  private const val DEGREES_PER_RADIAN = (180.0 / PI).toFloat()

  /** The field of view of a pinch, from [startFov] when the fingers went down and the [scale] they spread by since */
  fun pinchFov(startFov: Float, scale: Float): Float {
    if (!(scale > 0f) || scale.isInfinite()) return startFov.coerceIn(MIN_FOV, MAX_FOV)
    return (startFov / scale).coerceIn(MIN_FOV, MAX_FOV)
  }

  /** The field of view a double tap animates to: zoomed in, or back to the default once zoomed in */
  fun doubleTapFov(fov: Float): Float = if (fov > DOUBLE_TAP_FOV + 1f) DOUBLE_TAP_FOV else DEFAULT_FOV

  /** Degrees the view turns per pixel of drag at the field of view [fov] */
  fun degreesPerPixel(fov: Float): Float = fov / DEFAULT_FOV / PX_PER_DEGREE

  /**
   * The vertical field of view, in degrees, of a surface of [width] by [height] pixels showing [fov]. Media3 draws 90
   * degrees across the longer side (vertical in portrait, horizontal in landscape), which [zoomScale] then scales.
   */
  fun verticalFov(fov: Float, width: Int, height: Int): Float {
    if (width <= 0 || height <= 0) return fov
    val aspect = width.toFloat() / height
    val halfLong = tan(fov / 2f / DEGREES_PER_RADIAN)
    val halfVertical = if (aspect > 1f) halfLong / aspect else halfLong
    return 2f * atan(halfVertical) * DEGREES_PER_RADIAN
  }

  /**
   * How far the latitude goes. A full sphere: straight up and straight down, as in the photo viewer. A half sphere
   * (VR180): only until the edge of the screen reaches the zenith or the nadir, whose [verticalFov] is the vertical
   * field of view (see [verticalFov]); so a drag never brings more of the empty back half on screen than before issue
   * 20 (45 degrees at the default field of view in portrait, as Media3's touch allowed), and zoomed in it goes further.
   */
  fun maxLatitude(halfSphere: Boolean, verticalFov: Float): Float =
    if (!halfSphere) 90f else (90f - verticalFov / 2f).coerceIn(0f, 90f)

  /** [look] within the latitudes of [maxLatitude] and the limits of the pinch */
  fun clamp(look: SphereLook, maxLatitude: Float): SphereLook =
    look.copy(
      longitude = wrapLongitude(look.longitude),
      latitude = look.latitude.coerceIn(-maxLatitude, maxLatitude),
      fov = look.fov.coerceIn(MIN_FOV, MAX_FOV),
    )

  /**
   * A drag of [dx] and [dy] pixels (y down, as on screen): the picture follows the finger, so a drag to the left looks
   * further right and a drag down looks up, like the photo viewer and like Media3's touch before issue 20.
   */
  fun drag(look: SphereLook, dx: Float, dy: Float, maxLatitude: Float): SphereLook {
    val degrees = degreesPerPixel(look.fov)
    return clamp(look.copy(longitude = look.longitude - dx * degrees, latitude = look.latitude + dy * degrees), maxLatitude)
  }

  /**
   * Turns the view by the rotation the gyroscope measured over [dt] seconds, as the photo viewer's applyGyroRotation:
   * [rateX], [rateY] and [rateZ] in rad/s around the axes of the device in portrait (x to the right edge, y to the top,
   * z out of the screen, positive counterclockwise seen from the tip of the axis), as Android's TYPE_GYROSCOPE and iOS
   * report them. [rotation] is the rotation of the display ([ROTATION_0] to [ROTATION_270]). Turning the phone to the
   * right looks further right, tilting its top towards the user looks up; the roll around z is ignored.
   */
  fun gyro(
    look: SphereLook,
    rateX: Float,
    rateY: Float,
    @Suppress("UNUSED_PARAMETER") rateZ: Float,
    dt: Float,
    rotation: Int,
    maxLatitude: Float,
  ): SphereLook {
    // Rotation around the axes of the screen as the user sees it
    val (aroundScreenRight, aroundScreenUp) =
      when (rotation) {
        // The top of the phone on the left
        ROTATION_90 -> Pair(-rateY, rateX)
        ROTATION_180 -> Pair(-rateX, -rateY)
        // The top of the phone on the right
        ROTATION_270 -> Pair(rateY, -rateX)
        else -> Pair(rateX, rateY)
      }
    fun degrees(rate: Float): Float = if (abs(rate) < GYRO_NOISE_THRESHOLD) 0f else rate * dt * DEGREES_PER_RADIAN
    return clamp(
      look.copy(
        longitude = look.longitude - degrees(aroundScreenUp),
        latitude = look.latitude + degrees(aroundScreenRight),
      ),
      maxLatitude,
    )
  }

  /**
   * The time between two gyroscope samples, in seconds, from their timestamps in nanoseconds: the first sample, or
   * timestamps that make no sense, count as one sample at 50 Hz, as in the photo viewer.
   */
  fun gyroStep(previousNs: Long, currentNs: Long): Float {
    if (previousNs == 0L) return 1f / 50f
    val elapsed = (currentNs - previousNs) / 1e9f
    return if (elapsed > 0f && elapsed <= 0.2f) elapsed else 1f / 50f
  }

  /** How much the picture is magnified against Media3's own 90 degrees, for [fov] across the longer side */
  fun zoomScale(fov: Float): Float = 1f / tan(fov.coerceIn(MIN_FOV, MAX_FOV) / 2f / DEGREES_PER_RADIAN)

  /**
   * The view matrix of [look] for Media3's renderer, column major as android.opengl.Matrix: S · Rx(-latitude) ·
   * Ry(longitude), where S magnifies x and y by [zoomScale]. Media3 multiplies it with its projection of 90 degrees
   * across the longer side; its own touch rotations are kept at zero. The rotations are those Media3's touch built,
   * Rx(-pitch) and Ry(yaw), with its pitch the latitude and its yaw the opposite of the longitude, now with the whole
   * range of latitudes, and the camera always upright.
   */
  fun viewMatrix(look: SphereLook, out: FloatArray = FloatArray(16)): FloatArray {
    require(out.size >= 16)
    val lon = look.longitude / DEGREES_PER_RADIAN
    val lat = -look.latitude / DEGREES_PER_RADIAN
    val ca = cos(lon)
    val sa = sin(lon)
    val cb = cos(lat)
    val sb = sin(lat)
    val k = zoomScale(look.fov)
    // Rows of Rx(b) · Ry(a): [ca, 0, sa], [sb sa, cb, -sb ca], [-cb sa, sb, cb ca]; the first two times k
    out[0] = k * ca
    out[1] = k * sb * sa
    out[2] = -cb * sa
    out[3] = 0f
    out[4] = 0f
    out[5] = k * cb
    out[6] = sb
    out[7] = 0f
    out[8] = k * sa
    out[9] = -k * sb * ca
    out[10] = cb * ca
    out[11] = 0f
    out[12] = 0f
    out[13] = 0f
    out[14] = 0f
    out[15] = 1f
    return out
  }

  /** [longitude] in [-180, 180), so that hours of turning keep its precision */
  fun wrapLongitude(longitude: Float): Float {
    if (longitude >= -180f && longitude < 180f) return longitude
    val wrapped = ((longitude + 180f) % 360f + 360f) % 360f - 180f
    return wrapped
  }
}
