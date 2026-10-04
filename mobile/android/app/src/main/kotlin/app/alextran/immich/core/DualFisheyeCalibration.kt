package app.alextran.immich.core

import kotlin.math.PI
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.round
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * Lens model of a dual fisheye calibration: the unified camera model of Mei (Insta360 V3 strings), or a plain
 * equidistant fisheye (V1 strings), see docs 16-dual-fisheye-spec.md section 3.
 */
enum class DualFisheyeModel { MEI, EQUIDISTANT }

/**
 * One lens, in pixels of the calibration canvas (one square of [DualFisheyeCalibration.canvasSquare] pixels per lens,
 * side by side: lens 1's [cx] already includes the offset of one square) and in degrees. [radius] is the image circle
 * of an equidistant lens, about 100 degrees off axis on an Insta360 X3; the Mei fields are 0 for such a lens.
 */
data class DualFisheyeLens(
  val cx: Double,
  val cy: Double,
  val yaw: Double = 0.0,
  val pitch: Double = 0.0,
  val roll: Double = 0.0,
  val xi: Double = 0.0,
  val fx: Double = 0.0,
  val fy: Double = 0.0,
  val k1: Double = 0.0,
  val k2: Double = 0.0,
  val k3: Double = 0.0,
  val p1: Double = 0.0,
  val p2: Double = 0.0,
  val radius: Double = 0.0,
)

/**
 * What the players need to draw a raw dual fisheye frame (the two fisheye circles of an Insta360 .insv side by side,
 * lens 0 on the left half) on the sphere: the JSON Flutter sends as rawProjection (docs 16-dual-fisheye-spec.md
 * section 5), parsed, with the rotations of the mapping precomputed. Pure: no Android API, unit tested.
 *
 * Frames: the view frame of the equirectangular output is x right, y down, z forward (its centre); the body frame of
 * the camera is x right, y down, z along the optical axis of lens 0; each lens frame has z along its own axis. The
 * matrices are 3x3, row major, as FloatArray(9): `out = M * in` for column vectors.
 */
data class DualFisheyeCalibration(
  val model: DualFisheyeModel,
  /** Size of the frame Flutter probed, two squares side by side; the effect reads the decoded size itself. */
  val frameWidth: Int,
  val frameHeight: Int,
  /** Side of the square of one lens on the calibration canvas, in canvas pixels. */
  val canvasSquare: Double,
  /** Gravity in the body frame, unit length: (1, 0, 0) for a camera standing upright. */
  val downBody: List<Double>,
  val lenses: List<DualFisheyeLens>,
) {
  /** Frame pixels per canvas pixel for a frame [frameHeight] pixels high: the whole square scales, not a crop. */
  fun canvasToFrameScale(frameHeight: Int = this.frameHeight): Double = frameHeight / canvasSquare

  /** R_i of [index]: body frame to the frame of that lens (spec section 3), row major. */
  fun lensRotation(index: Int): FloatArray = lensRotationOf(lenses[index], index).toFloats()

  /** G: view frame to body frame, which levels the picture with [downBody] (spec section 3), row major. */
  fun bodyFromView(): FloatArray = bodyFromViewOf(downBody).toFloats()

  /** R_i * G: view frame straight to the frame of lens [index], what the shader multiplies the view direction by. */
  fun viewToLens(index: Int): FloatArray =
    multiply(lensRotationOf(lenses[index], index), bodyFromViewOf(downBody)).toFloats()

  /**
   * CPU reference of the shader mapping for lens [index]: the canvas pixel (x, y) that sees the view direction
   * [view] (unit length, view frame), and the angle in degrees between that direction and the lens axis. Used by the
   * tests; the shader computes the same in single precision.
   */
  fun canvasPixel(index: Int, view: DoubleArray): Projection {
    val lens = lenses[index]
    val d = multiply(multiply(lensRotationOf(lens, index), bodyFromViewOf(downBody)), view)
    val theta = acos(d[2].coerceIn(-1.0, 1.0))
    return when (model) {
      DualFisheyeModel.MEI -> {
        val depth = maxOf(d[2] + lens.xi, MIN_DEPTH)
        val mx = d[0] / depth
        val my = d[1] / depth
        val r2 = mx * mx + my * my
        val radial = 1 + r2 * (lens.k1 + r2 * (lens.k2 + r2 * lens.k3))
        val x = radial * mx + 2 * lens.p1 * mx * my + lens.p2 * (r2 + 2 * mx * mx)
        val y = radial * my + lens.p1 * (r2 + 2 * my * my) + 2 * lens.p2 * mx * my
        Projection(lens.fx * x + lens.cx, lens.fy * y + lens.cy, Math.toDegrees(theta))
      }
      DualFisheyeModel.EQUIDISTANT -> {
        val focal = equidistantFocal(lens)
        val off = sqrt(d[0] * d[0] + d[1] * d[1])
        val (ux, uy) = if (off > 0) d[0] / off to d[1] / off else 0.0 to 0.0
        Projection(lens.cx + focal * theta * ux, lens.cy + focal * theta * uy, Math.toDegrees(theta))
      }
    }
  }

  /** A canvas pixel and the angle off the lens axis, in degrees, see [canvasPixel]. */
  data class Projection(val x: Double, val y: Double, val thetaDegrees: Double)

  companion object {
    /** Angle off axis the V1 radius marks on an Insta360 X3 (spec section 3, equidistant fallback). */
    const val EQUIDISTANT_RADIUS_DEGREES = 100.0

    /** The Mei denominator d.z + xi never reaches 0 within 100 degrees; kept away from it all the same. */
    private const val MIN_DEPTH = 1e-3

    /** Studio's forward when leveling: -z of the body, the axis of lens 1 (spec section 3). */
    private val FORWARD_HINT = doubleArrayOf(0.0, 0.0, -1.0)

    /**
     * Forward when gravity runs along the lens axes (the camera filming straight down or up): any level axis would
     * do; body x is the one the Dart and the Swift sides use, so the picture opens on the same heading everywhere.
     */
    private val FALLBACK_FORWARD_HINT = doubleArrayOf(1.0, 0.0, 0.0)

    private val UPRIGHT = listOf(1.0, 0.0, 0.0)

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Parses the rawProjection JSON of spec section 5. Throws IllegalArgumentException (kotlinx SerializationException
     * included) when it is not a dual fisheye calibration with two usable lenses: the players then show the frame as
     * it is. A missing or degenerate downBody means a camera standing upright.
     */
    fun parse(text: String): DualFisheyeCalibration {
      val root = json.parseToJsonElement(text).jsonObject
      require(root.string("kind") == "dualFisheye") { "not a dual fisheye projection: ${root.string("kind")}" }
      val model =
        when (val name = root.string("model")) {
          "mei" -> DualFisheyeModel.MEI
          "equidistant" -> DualFisheyeModel.EQUIDISTANT
          else -> throw IllegalArgumentException("unknown lens model $name")
        }
      val canvasSquare = root.number("canvasSquare") ?: 0.0
      require(canvasSquare > 0) { "no canvas square" }
      val frameWidth = root.integer("frameWidth") ?: 0
      val frameHeight = root.integer("frameHeight") ?: 0
      require(frameWidth > 0 && frameHeight > 0) { "no frame size" }
      val lenses = root["lenses"]?.jsonArray?.map { lensOf(it.jsonObject, model) }.orEmpty()
      require(lenses.size == 2) { "${lenses.size} lenses instead of 2" }
      return DualFisheyeCalibration(
        model = model,
        frameWidth = frameWidth,
        frameHeight = frameHeight,
        canvasSquare = canvasSquare,
        downBody = downOf(root["downBody"]),
        lenses = lenses,
      )
    }

    /** Mirrors the roll about its nearest multiple of 90 degrees, GyroView's reading of the Insta360 roll. */
    fun mirroredRoll(roll: Double): Double = 2 * round(roll / 90.0) * 90.0 - roll

    /** Focal length of an equidistant lens, in canvas pixels per radian. */
    fun equidistantFocal(lens: DualFisheyeLens): Double = lens.radius / Math.toRadians(EQUIDISTANT_RADIUS_DEGREES)

    private fun lensOf(json: JsonObject, model: DualFisheyeModel): DualFisheyeLens {
      val lens =
        DualFisheyeLens(
          cx = json.number("cx") ?: throw IllegalArgumentException("lens without cx"),
          cy = json.number("cy") ?: throw IllegalArgumentException("lens without cy"),
          yaw = json.number("yaw") ?: 0.0,
          pitch = json.number("pitch") ?: 0.0,
          roll = json.number("roll") ?: 0.0,
          xi = json.number("xi") ?: 0.0,
          fx = json.number("fx") ?: 0.0,
          fy = json.number("fy") ?: 0.0,
          k1 = json.number("k1") ?: 0.0,
          k2 = json.number("k2") ?: 0.0,
          k3 = json.number("k3") ?: 0.0,
          p1 = json.number("p1") ?: 0.0,
          p2 = json.number("p2") ?: 0.0,
          radius = json.number("radius") ?: 0.0,
        )
      when (model) {
        DualFisheyeModel.MEI -> require(lens.fx > 0 && lens.fy > 0 && lens.xi >= 0) { "Mei lens without fx, fy or xi" }
        DualFisheyeModel.EQUIDISTANT -> require(lens.radius > 0) { "equidistant lens without radius" }
      }
      return lens
    }

    private fun downOf(element: JsonElement?): List<Double> {
      val values = runCatching { element?.jsonArray?.map { (it as JsonPrimitive).doubleOrNull } }.getOrNull()
      if (values == null || values.size != 3 || values.any { it == null || it.isNaN() }) return UPRIGHT
      val v = values.map { it!! }
      val length = sqrt(v.sumOf { it * it })
      if (length < 1e-6) return UPRIGHT
      return v.map { it / length }
    }

    /** R_i = Rz(mirroredRoll(roll_i)) * Rx(180 degrees * i) * Rx(pitch_i) * Ry(yaw_i), spec section 3. */
    private fun lensRotationOf(lens: DualFisheyeLens, index: Int): Array<DoubleArray> =
      multiply(
        multiply(rotationZ(mirroredRoll(lens.roll)), rotationX(180.0 * index)),
        multiply(rotationX(lens.pitch), rotationY(lens.yaw)),
      )

    /**
     * G = [x_b | down | z_b] (columns): z_b is the forward hint made level (its part along gravity removed), x_b =
     * down x z_b, so that the view's y axis runs along gravity and its z axis faces Studio's forward.
     */
    private fun bodyFromViewOf(downBody: List<Double>): Array<DoubleArray> {
      val down = doubleArrayOf(downBody[0], downBody[1], downBody[2])
      var forward = level(FORWARD_HINT, down)
      if (forward == null) forward = level(FALLBACK_FORWARD_HINT, down) ?: doubleArrayOf(0.0, 0.0, -1.0)
      val right = cross(down, forward)
      return Array(3) { row -> doubleArrayOf(right[row], down[row], forward[row]) }
    }

    /** [hint] without its part along [down], unit length, or null when it runs along [down]. */
    private fun level(hint: DoubleArray, down: DoubleArray): DoubleArray? {
      val along = hint[0] * down[0] + hint[1] * down[1] + hint[2] * down[2]
      val v = DoubleArray(3) { hint[it] - along * down[it] }
      val length = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
      if (length < 1e-6) return null
      return DoubleArray(3) { v[it] / length }
    }

    private fun cross(a: DoubleArray, b: DoubleArray): DoubleArray =
      doubleArrayOf(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])

    private fun rotationX(degrees: Double): Array<DoubleArray> {
      val (c, s) = cosSin(degrees)
      return arrayOf(doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, c, -s), doubleArrayOf(0.0, s, c))
    }

    private fun rotationY(degrees: Double): Array<DoubleArray> {
      val (c, s) = cosSin(degrees)
      return arrayOf(doubleArrayOf(c, 0.0, s), doubleArrayOf(0.0, 1.0, 0.0), doubleArrayOf(-s, 0.0, c))
    }

    private fun rotationZ(degrees: Double): Array<DoubleArray> {
      val (c, s) = cosSin(degrees)
      return arrayOf(doubleArrayOf(c, -s, 0.0), doubleArrayOf(s, c, 0.0), doubleArrayOf(0.0, 0.0, 1.0))
    }

    private fun cosSin(degrees: Double): Pair<Double, Double> {
      val radians = degrees * PI / 180.0
      return cos(radians) to sin(radians)
    }

    private fun multiply(a: Array<DoubleArray>, b: Array<DoubleArray>): Array<DoubleArray> =
      Array(3) { row -> DoubleArray(3) { col -> (0 until 3).sumOf { a[row][it] * b[it][col] } } }

    private fun multiply(m: Array<DoubleArray>, v: DoubleArray): DoubleArray =
      DoubleArray(3) { row -> m[row][0] * v[0] + m[row][1] * v[1] + m[row][2] * v[2] }

    private fun Array<DoubleArray>.toFloats(): FloatArray = FloatArray(9) { this[it / 3][it % 3].toFloat() }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.number(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull

    private fun JsonObject.integer(key: String): Int? =
      (this[key] as? JsonPrimitive)?.let { it.intOrNull ?: it.doubleOrNull?.toInt() }
  }
}
