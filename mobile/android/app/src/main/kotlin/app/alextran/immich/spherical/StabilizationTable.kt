package app.alextran.immich.spherical

import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.atan2
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The stabilisation of a raw 360° video with the motion track of its camera (issue 14), as Flutter builds it
 * (lib/domain/models/raw/stabilization.dart): for each frame, its presentation time on the timeline of the video and
 * the rotation of the sphere of the stitched frame that shows the world level and steady. A point of the stitched
 * frame at direction d of its view frame (x to the right, y down, z forward: the frame of the stitch, the centre of the
 * equirectangular picture straight ahead) is shown at direction K d.
 *
 * [angleAxisAt] gives that rotation in the form Media3's CameraMotionListener takes, the one of a CAMM track: an angle
 * axis in a camera frame with x to the right, y down and z forward, which is the view frame of the stitch. Media3 turns
 * it into the frame of its sphere (OpenGL, y up, z backward) by negating y and z (FrameRotationQueue
 * .getRotationMatrixFromAngleAxis of Media3 1.10.0), and its equirectangular mesh puts the view direction (x, y, z) of
 * a picture at (x, -y, -z): the same change of frame, so the angle axis of K passes as it is. Its sphere turns each
 * vertex by that rotation before the view of the phone, so the vertex of direction d lands at K d, as Flutter means.
 * StabilizationTableTest pins it with a synthetic rotation.
 *
 * [corrections] holds four values a frame (w, x, y, z), unit quaternions, neighbours on the same side (positive dot
 * product); [timesUs] rise. Pure Kotlin: the unit tests run without a device.
 */
class StabilizationTable private constructor(private val timesUs: LongArray, private val corrections: DoubleArray) {
  companion object {
    /** Corrections whose norm is farther than this from 1 are refused: a table Flutter did not build */
    private const val NORM_TOLERANCE = 1e-3

    /**
     * The table of [timesUs] and [corrections] as setStabilization gives them, or null with the reason in [onRefused]
     * for one that cannot be used: none, lengths that do not match, times that do not rise, values that are not unit
     * quaternions. The arrays are kept as they are, not copied.
     */
    fun of(timesUs: LongArray?, corrections: DoubleArray?, onRefused: (String) -> Unit = {}): StabilizationTable? {
      if (timesUs == null || corrections == null || timesUs.isEmpty()) {
        onRefused("no frame")
        return null
      }
      if (corrections.size != 4 * timesUs.size) {
        onRefused("${corrections.size} values for ${timesUs.size} frames")
        return null
      }
      for (i in 1 until timesUs.size) {
        if (timesUs[i] <= timesUs[i - 1]) {
          onRefused("frame $i at ${timesUs[i]} us does not follow ${timesUs[i - 1]} us")
          return null
        }
      }
      for (i in timesUs.indices) {
        val o = 4 * i
        val norm = sqrt(
          corrections[o] * corrections[o] + corrections[o + 1] * corrections[o + 1] +
            corrections[o + 2] * corrections[o + 2] + corrections[o + 3] * corrections[o + 3],
        )
        if (!norm.isFinite() || abs(norm - 1) > NORM_TOLERANCE) {
          onRefused("frame $i has a correction of norm $norm")
          return null
        }
      }
      return StabilizationTable(timesUs, corrections)
    }
  }

  /** Frames in the table */
  val size: Int
    get() = timesUs.size

  /** Presentation time of the first and of the last frame, in microseconds */
  val firstTimeUs: Long
    get() = timesUs.first()
  val lastTimeUs: Long
    get() = timesUs.last()

  /**
   * The correction at [timeUs] of the timeline (w, x, y, z): the one of the frame at that time, blended (slerp) between
   * the frames before and after it, the first or the last one outside them. Binary search: a lookup per frame on the
   * playback thread costs nothing next to its decoding.
   */
  fun quaternionAt(timeUs: Long): DoubleArray {
    val times = timesUs
    if (timeUs <= times.first()) return quaternion(0)
    if (timeUs >= times.last()) return quaternion(times.size - 1)
    // The last frame at or before timeUs, and the one after it
    var low = 0
    var high = times.size - 1
    while (high - low > 1) {
      val middle = (low + high) ushr 1
      if (times[middle] <= timeUs) low = middle else high = middle
    }
    val share = (timeUs - times[low]).toDouble() / (times[high] - times[low]).toDouble()
    return StabilizationMath.slerp(quaternion(low), quaternion(high), share)
  }

  /** The correction at [timeUs] as the angle axis Media3's CameraMotionListener takes (see the class) */
  fun angleAxisAt(timeUs: Long): FloatArray = StabilizationMath.angleAxis(quaternionAt(timeUs))

  /**
   * The correction at [timeUs] as the stitch shaders take it (the immersive viewer of the Meta Quest, which turns the
   * picture inside the stitch rather than the sphere): the mat3 uniform uStabilization of RawStitchShaders, column
   * major, that turns the view direction e of each output pixel into the direction of the stitched view it shows. The
   * point at direction d is shown at K d, so the pixel at e shows the point at K^T e: the uniform is K^T, see
   * [StabilizationMath.stitchMatrix]. StabilizedStitchTest pins it with the checks of StabilizationTableTest.
   */
  fun stitchMatrixAt(timeUs: Long): FloatArray = StabilizationMath.stitchMatrix(quaternionAt(timeUs))

  private fun quaternion(frame: Int): DoubleArray = corrections.copyOfRange(4 * frame, 4 * frame + 4)
}

/** Quaternions (w, x, y, z), Hamilton product, rotations acting on vectors */
internal object StabilizationMath {
  /** The rotation blended between [a] and [b] at [share] (0 at a, 1 at b), along the shorter arc, unit long */
  fun slerp(a: DoubleArray, b: DoubleArray, share: Double): DoubleArray {
    var dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    val sign = if (dot < 0) -1.0 else 1.0
    dot *= sign
    val wa: Double
    var wb: Double
    if (dot > 1 - 1e-10) {
      // Within about 1e-5 radian: a straight blend is as good
      wa = 1 - share
      wb = share
    } else {
      val angle = acos(min(1.0, dot))
      val sine = sin(angle)
      wa = sin((1 - share) * angle) / sine
      wb = sin(share * angle) / sine
    }
    wb *= sign
    val q = DoubleArray(4) { wa * a[it] + wb * b[it] }
    val norm = sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
    for (i in 0 until 4) q[i] /= norm
    return q
  }

  /**
   * The angle axis of the rotation [q] (w, x, y, z): the unit axis times the angle in radians, at most pi, in the frame
   * of [q]. A new array each time: Media3 keeps it in its queue until the frame is drawn.
   */
  fun angleAxis(q: DoubleArray): FloatArray {
    // q and -q are the same rotation: the one with w >= 0 has the angle of at most pi
    val sign = if (q[0] < 0) -1.0 else 1.0
    val w = sign * q[0]
    val x = sign * q[1]
    val y = sign * q[2]
    val z = sign * q[3]
    val length = sqrt(x * x + y * y + z * z)
    if (length < 1e-12) return FloatArray(3)
    val angle = 2 * atan2(length, w)
    val scale = angle / length
    return floatArrayOf((x * scale).toFloat(), (y * scale).toFloat(), (z * scale).toFloat())
  }

  /**
   * The transpose of the rotation matrix K of the unit quaternion [q] (w, x, y, z), as GLSL reads a mat3 uniform
   * uploaded without transpose (column major): column c of K^T is row c of K, so the nine values are the rows of K one
   * after the other. A new array each time.
   */
  fun stitchMatrix(q: DoubleArray): FloatArray {
    val (w, x, y, z) = q
    // The rows of K
    return floatArrayOf(
      (1 - 2 * (y * y + z * z)).toFloat(), (2 * (x * y - w * z)).toFloat(), (2 * (x * z + w * y)).toFloat(),
      (2 * (x * y + w * z)).toFloat(), (1 - 2 * (x * x + z * z)).toFloat(), (2 * (y * z - w * x)).toFloat(),
      (2 * (x * z - w * y)).toFloat(), (2 * (y * z + w * x)).toFloat(), (1 - 2 * (x * x + y * y)).toFloat(),
    )
  }
}
