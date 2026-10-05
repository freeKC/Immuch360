package app.alextran.immich.core.raw

import app.alextran.immich.core.DualFisheyeCalibration
import app.alextran.immich.core.DualFisheyeModel
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject

/** Projection family of a raw 360° video: a pair of fisheye lenses, or the two EAC tracks of a GoPro .360. */
enum class RawKind { DUAL_FISHEYE, EAC_GOPRO }

/**
 * How the lenses are stored: both side by side in one video track (lens 0 on the left), in two video tracks of one
 * file, or in one video track of each of two files (an Insta360 split pair).
 */
enum class RawLayout { SIDE_BY_SIDE, TWO_TRACKS, TWO_FILES }

/** Lens model of a fisheye pair, the same for both lenses. */
enum class LensModel { MEI, EQUIDISTANT, KANNALA_BRANDT }

/**
 * One decoded input, texture unit k of the shaders being `tracks[k]`. [file] is 0 for the url the player was given,
 * 1 for the second file of a split pair; [trackId] is the tkhd track_ID Media3 exposes as Format.id; [width] and
 * [height] the coded size the sample entry declares (0 when unknown), the decoded size wins at run time.
 */
class RawTrack(
  val file: Int,
  val videoTrack: Int,
  val trackId: Int?,
  val width: Int,
  val height: Int,
  val codec: String?,
  val codecs: String?,
  val bitDepth: Int,
  /** Frames per second when the JSON tells it, 0 otherwise: the players then read it from the decoded format. */
  val frameRate: Double,
) {
  val pixels: Long
    get() = width.toLong() * height
}

/**
 * One fisheye lens, in pixels of the calibration canvas (one square of [RawProjection.canvasSquare] pixels per lens,
 * lens i's square starting at x = i S, so lens 1's [cx] includes S). [region] is where that square lies in its
 * texture `tracks[texture]`: x, y, width, height as fractions, top left origin. [viewToLens] is the 3x3 matrix, row
 * major, that takes a view direction to the lens frame (leveling included, computed by Flutter): normative.
 */
class RawLens(
  val texture: Int,
  val region: DoubleArray,
  val cx: Double,
  val cy: Double,
  val fx: Double,
  val fy: Double,
  val xi: Double,
  /** k1 to k5: the Mei radial terms in r^2 to r^10, or the Kannala-Brandt terms in theta^3 to theta^11. */
  val k: DoubleArray,
  val p1: Double,
  val p2: Double,
  /** Equidistant only: the image circle radius, in canvas pixels, at [radiusTheta] degrees off axis. */
  val radius: Double,
  val radiusTheta: Double,
  val viewToLens: DoubleArray,
)

/**
 * One cube face of a GoPro EAC pair: the track ([texture]) and the slot of that track (1 is the whole middle face, 0
 * and 2 the split faces at both ends) that hold it, and its basis in the camera frame.
 */
class EacFace(
  val texture: Int,
  val slot: Int,
  val forward: DoubleArray,
  val right: DoubleArray,
  val down: DoubleArray,
)

/**
 * The layout of the two EAC tracks of a GoPro .360, in pixels of a track at its declared size: faces of [face]
 * pixels, split faces of two halves of [half] columns that share [overlap] columns, the middle face at x =
 * [middle], the right slot at x = [right]. [viewToCamera] (row major) takes a view direction to the camera frame of
 * the face table; it may be a reflection (the MAX's quarter turn after a flip of y).
 */
class EacGeometry(
  val face: Int,
  val overlap: Int,
  val half: Int,
  val middle: Int,
  val right: Int,
  val viewToCamera: DoubleArray,
  val faces: List<EacFace>,
) {
  /** Declared width of a track: the left slot, the middle face, the right slot. */
  val trackWidth: Int
    get() = right + 2 * half
}

/**
 * The rawProjection JSON of Flutter (version 2, docs 18-design-projections-and-parsers.md section 3; version 1, the
 * build 16 and 17 JSON without "version", converted), parsed and checked. Pure: no Android API, so that the parser,
 * the CPU reference of the shaders and the planner run in the JVM tests. [parse] throws IllegalArgumentException with
 * the reason when the JSON is not one the players can draw; they then play the file unstitched and log the reason.
 *
 * Frames: the view frame of the equirectangular output is x right, y down, z forward (its centre column); an output
 * direction is `(cos lat sin lon, -sin lat, cos lat cos lon)`.
 */
class RawProjection(
  /** 2, or 1 for a JSON of build 16 or 17 converted by [parse]. */
  val version: Int,
  val kind: RawKind,
  val layout: RawLayout,
  /** "Insta360 X3", "Osmo 360", "GoPro MAX": for the logs only. */
  val camera: String?,
  /** Size of the stitched equirectangular frame worth drawing; the players cap it with their own limits. */
  val frameWidth: Int,
  val frameHeight: Int,
  val tracks: List<RawTrack>,
  val secondUrl: String?,
  val secondFallbackUrl: String?,
  /** The lens held by tracks[0] and tracks[1], for the logs: [RawLens.texture] is normative. */
  val trackOrder: List<Int>?,
  val model: LensModel?,
  val canvasSquare: Double,
  val maxThetaDegrees: Double,
  val blendStartDegrees: Double,
  val blendEndDegrees: Double,
  val lenses: List<RawLens>,
  val eac: EacGeometry?,
) {
  /** The lenses come in two decoded streams (two tracks or two files): the compositor's job, not the effect's. */
  val isLensLayout: Boolean
    get() = layout != RawLayout.SIDE_BY_SIDE

  /** Number of decoded streams: 1 side by side, 2 otherwise. */
  val streamCount: Int
    get() = tracks.size

  /**
   * The stream kept when only one can be decoded: the one that holds what the view opens on. For a fisheye pair, the
   * texture of the lens whose axis is nearest the view's forward direction (row 2 of viewToLens is the lens axis in
   * the view frame, its z the cosine to forward): Insta360 lens 1 (Studio's forward), DJI's front lens. For EAC, the
   * track of the face nearest forward.
   */
  fun primaryStream(): Int {
    if (kind == RawKind.EAC_GOPRO) {
      val geometry = eac ?: return 0
      val forward = multiply(geometry.viewToCamera, doubleArrayOf(0.0, 0.0, 1.0))
      return geometry.faces.maxByOrNull { dot(it.forward, forward) }?.texture ?: 0
    }
    return lenses.maxByOrNull { it.viewToLens[8] }?.texture ?: 0
  }

  /** The file (0 for the url, 1 for the second url) of the decoded stream [stream]. */
  fun fileOfStream(stream: Int): Int = tracks.getOrNull(stream)?.file ?: 0

  /**
   * CPU reference of the fisheye shader for lens [index] (section 4.1 of the projections design): where the lens sees
   * the view direction [view] (unit length), or null when it does not (past maxTheta, or off its square).
   */
  fun lensSample(index: Int, view: DoubleArray): LensSample? {
    val lens = lenses[index]
    val d = normalize(multiply(lens.viewToLens, view))
    val theta = atan2(sqrt(d[0] * d[0] + d[1] * d[1]), d[2])
    if (theta >= Math.toRadians(maxThetaDegrees)) return null
    val (px, py) = projectLens(lens, d, theta)
    val localX = (px - index * canvasSquare) / canvasSquare
    val localY = py / canvasSquare
    if (localX < 0 || localX >= 1 || localY < 0 || localY >= 1) return null
    val region = lens.region
    val weight = 1 - smoothstep(Math.toRadians(blendStartDegrees), Math.toRadians(blendEndDegrees), theta)
    return LensSample(
      lens = index,
      texture = lens.texture,
      canvasX = px,
      canvasY = py,
      textureX = region[0] + localX * region[2],
      textureY = region[1] + localY * region[3],
      thetaDegrees = Math.toDegrees(theta),
      weight = weight,
    )
  }

  /**
   * CPU reference of the whole fisheye shader: the lenses that colour [view] with their shares (adding up to 1), the
   * lens with the smaller angle alone when both see it past the blend, nothing when no lens sees it. [enabled] says
   * which streams are decoded (one lens mode).
   */
  fun fisheyeSamples(view: DoubleArray, enabled: Set<Int> = tracks.indices.toSet()): List<LensSample> {
    val seen = lenses.indices.mapNotNull { lensSample(it, view) }.filter { it.texture in enabled }
    val sum = seen.sumOf { it.weight }
    if (sum > 0) return seen.filter { it.weight > 0 }.map { it.copy(weight = it.weight / sum) }
    return seen.minByOrNull { it.thetaDegrees }?.let { listOf(it.copy(weight = 1.0)) } ?: emptyList()
  }

  /**
   * CPU reference of the EAC shader (section 4.2 of the projections design): the reads of the tracks that colour
   * [view], in pixels of the declared track size (continuous, pixel centres at half pixels), with their weights. A
   * split face blends its two halves over the overlap columns; reads of weight 0 are dropped.
   */
  fun eacSamples(view: DoubleArray): List<EacSample> {
    val geometry = eac ?: return emptyList()
    val c = multiply(geometry.viewToCamera, view)
    var best = geometry.faces.first()
    var bestDot = dot(c, best.forward)
    for (face in geometry.faces.drop(1)) {
      val value = dot(c, face.forward)
      // Ties keep the first face of the table, as the shader does with its strict comparison
      if (value > bestDot) {
        best = face
        bestDot = value
      }
    }
    val f = geometry.face.toDouble()
    val half = geometry.half.toDouble()
    val overlap = geometry.overlap.toDouble()
    val middle = geometry.middle.toDouble()
    val col = (atan(dot(c, best.right) / bestDot) * 4 / PI + 1) / 2 * f
    val row = ((atan(dot(c, best.down) / bestDot) * 4 / PI + 1) / 2 * f).coerceIn(0.5, f - 0.5)
    if (best.slot == 1) {
      return listOf(EacSample(best.texture, (middle + col).coerceIn(middle + 0.5, middle + f - 0.5), row, 1.0))
    }
    val base = if (best.slot == 0) 0.0 else geometry.right.toDouble()
    val second =
      if (overlap > 0) ((col - 0.5 - (f - half)) / overlap).coerceIn(0.0, 1.0) else if (col >= half) 1.0 else 0.0
    val xa = (base + col).coerceIn(base + 0.5, base + half - 0.5)
    val xb = (base + half + col - (f - half)).coerceIn(base + half + 0.5, base + 2 * half - 0.5)
    return listOf(EacSample(best.texture, xa, row, 1 - second), EacSample(best.texture, xb, row, second)).filter {
      it.weight > 0
    }
  }

  /** One log line: what the players stitch, without any URL. */
  fun summary(): String {
    val sizes = tracks.joinToString(",") { "${it.width}x${it.height}" }
    val ids = tracks.joinToString(",") { "${it.file}:${it.trackId ?: "?"}" }
    val what =
      when (kind) {
        RawKind.DUAL_FISHEYE ->
          "dualFisheye ${jsonName(model)} lenses in textures ${lenses.joinToString(",") { it.texture.toString() }}, " +
            "theta $maxThetaDegrees/$blendStartDegrees/$blendEndDegrees"
        RawKind.EAC_GOPRO -> "eacGoPro face ${eac?.face} overlap ${eac?.overlap}"
      }
    return "v$version ${camera ?: "unknown camera"} $what layout ${jsonName(layout)} tracks $ids $sizes " +
      "output ${frameWidth}x$frameHeight"
  }

  /** The JSON names, for the logs: what Flutter sent. */
  private fun jsonName(layout: RawLayout): String =
    when (layout) {
      RawLayout.SIDE_BY_SIDE -> "sideBySide"
      RawLayout.TWO_TRACKS -> "twoTracks"
      RawLayout.TWO_FILES -> "twoFiles"
    }

  private fun jsonName(model: LensModel?): String =
    when (model) {
      LensModel.MEI -> "mei"
      LensModel.EQUIDISTANT -> "equidistant"
      LensModel.KANNALA_BRANDT -> "kannalaBrandt"
      null -> "none"
    }

  private fun projectLens(lens: RawLens, d: DoubleArray, theta: Double): Pair<Double, Double> {
    val k = lens.k
    return when (model) {
      LensModel.MEI, null -> {
        val depth = max(d[2] + lens.xi, MIN_DEPTH)
        val mx = d[0] / depth
        val my = d[1] / depth
        val r2 = mx * mx + my * my
        val radial = 1 + r2 * (k[0] + r2 * (k[1] + r2 * (k[2] + r2 * (k[3] + r2 * k[4]))))
        val x = radial * mx + 2 * lens.p1 * mx * my + lens.p2 * (r2 + 2 * mx * mx)
        val y = radial * my + lens.p1 * (r2 + 2 * my * my) + 2 * lens.p2 * mx * my
        (lens.fx * x + lens.cx) to (lens.fy * y + lens.cy)
      }
      LensModel.EQUIDISTANT -> {
        val focal = equidistantFocal(lens)
        val (ux, uy) = unitXy(d)
        (lens.cx + focal * theta * ux) to (lens.cy + focal * theta * uy)
      }
      LensModel.KANNALA_BRANDT -> {
        val t2 = theta * theta
        val thetaD = theta * (1 + t2 * (k[0] + t2 * (k[1] + t2 * (k[2] + t2 * (k[3] + t2 * k[4])))))
        val (ux, uy) = unitXy(d)
        (lens.cx + lens.fx * thetaD * ux) to (lens.cy + lens.fy * thetaD * uy)
      }
    }
  }

  /** What a lens sees of a view direction, see [lensSample]: canvas pixel, texture fraction, angle, blend weight. */
  data class LensSample(
    val lens: Int,
    val texture: Int,
    val canvasX: Double,
    val canvasY: Double,
    val textureX: Double,
    val textureY: Double,
    val thetaDegrees: Double,
    val weight: Double,
  )

  /** One read of an EAC track, see [eacSamples]: track, x and y in declared pixels, share of the output pixel. */
  data class EacSample(val texture: Int, val x: Double, val y: Double, val weight: Double)

  companion object {
    /** The Mei denominator d.z + xi never reaches 0 within the field of a lens; kept away from it all the same. */
    private const val MIN_DEPTH = 1e-3

    /** Insta360 limits, the defaults of a JSON that does not give its own (version 1 never does). */
    const val DEFAULT_MAX_THETA = 100.0
    const val DEFAULT_BLEND_START = 85.0
    const val DEFAULT_BLEND_END = 95.0

    /** Angle off axis of an equidistant radius when the JSON does not tell: the Insta360 V1 reading. */
    const val DEFAULT_RADIUS_THETA = 100.0

    private val json = Json { ignoreUnknownKeys = true }

    /** View direction of longitude [lonDegrees] and latitude [latDegrees], for the tests and the logs. */
    fun view(lonDegrees: Double, latDegrees: Double): DoubleArray {
      val lon = Math.toRadians(lonDegrees)
      val lat = Math.toRadians(latDegrees)
      return doubleArrayOf(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon))
    }

    /** Focal length of an equidistant lens, in canvas pixels per radian. */
    fun equidistantFocal(lens: RawLens): Double = lens.radius / Math.toRadians(lens.radiusTheta)

    /**
     * Parses the rawProjection JSON of Flutter. Version 2 is checked against the rules of section 3.4 of the
     * projections design; a JSON without "version" is the side by side JSON of builds 16 and 17, read by
     * [DualFisheyeCalibration.parse] and converted so that it draws the same picture. Throws IllegalArgumentException
     * (kotlinx SerializationException included) with the reason otherwise.
     */
    fun parse(text: String): RawProjection {
      val root = json.parseToJsonElement(text) as? JsonObject ?: throw IllegalArgumentException("not a JSON object")
      val version = root["version"]
      if (version == null || version is JsonNull) return fromVersion1(DualFisheyeCalibration.parse(text))
      require(root.integer("version") == 2) { "version $version, not 2" }
      val kind =
        when (val name = root.string("kind")) {
          "dualFisheye" -> RawKind.DUAL_FISHEYE
          "eacGoPro" -> RawKind.EAC_GOPRO
          else -> throw IllegalArgumentException("unknown kind $name")
        }
      val layout =
        when (val name = root.string("layout")) {
          "sideBySide" -> RawLayout.SIDE_BY_SIDE
          "twoTracks" -> RawLayout.TWO_TRACKS
          "twoFiles" -> RawLayout.TWO_FILES
          else -> throw IllegalArgumentException("unknown layout $name")
        }
      val tracks = root.array("tracks").map { trackOf(it.jsonObject) }
      val expectedTracks = if (layout == RawLayout.SIDE_BY_SIDE) 1 else 2
      require(tracks.size == expectedTracks) { "${tracks.size} tracks for the layout $layout" }
      val secondUrl = root.string("secondUrl")?.takeIf { it.isNotBlank() }
      for (track in tracks) {
        require(track.file == 0 || track.file == 1) { "file ${track.file}" }
        require(track.file == 0 || (layout == RawLayout.TWO_FILES && secondUrl != null)) {
          "a track in a second file without secondUrl"
        }
      }
      when (layout) {
        RawLayout.TWO_FILES ->
          require(tracks.map { it.file }.toSet() == setOf(0, 1)) { "twoFiles needs one track in each file" }
        RawLayout.TWO_TRACKS -> {
          // Media3 tells the lens tracks apart by their tkhd track_ID (Format.id) only
          val ids = tracks.map { it.trackId }
          require(ids.all { it != null && it > 0 } && ids.distinct().size == 2) {
            "twoTracks without two distinct track IDs: $ids"
          }
        }
        RawLayout.SIDE_BY_SIDE -> Unit
      }
      require(kind != RawKind.EAC_GOPRO || layout == RawLayout.TWO_TRACKS) { "eacGoPro is always twoTracks" }
      val frameWidth = root.integer("frameWidth") ?: 0
      val frameHeight = root.integer("frameHeight") ?: 0
      require(frameWidth > 0 && frameHeight > 0) { "no frame size" }
      val trackOrder = runCatching { root.array("trackOrder").map { (it as JsonPrimitive).intOrNull!! } }.getOrNull()
      val common = Common(kind, layout, root.string("camera"), frameWidth, frameHeight, tracks, secondUrl,
        root.string("secondFallbackUrl")?.takeIf { it.isNotBlank() && secondUrl != null }, trackOrder)
      return when (kind) {
        RawKind.DUAL_FISHEYE -> fisheyeOf(root, common)
        RawKind.EAC_GOPRO -> eacOf(root, common)
      }
    }

    /** The fields every kind has, carried from [parse] to the kind's own reader. */
    private class Common(
      val kind: RawKind,
      val layout: RawLayout,
      val camera: String?,
      val frameWidth: Int,
      val frameHeight: Int,
      val tracks: List<RawTrack>,
      val secondUrl: String?,
      val secondFallbackUrl: String?,
      val trackOrder: List<Int>?,
    )

    private fun fisheyeOf(root: JsonObject, common: Common): RawProjection {
      val model =
        when (val name = root.string("model")) {
          "mei" -> LensModel.MEI
          "equidistant" -> LensModel.EQUIDISTANT
          "kannalaBrandt" -> LensModel.KANNALA_BRANDT
          else -> throw IllegalArgumentException("unknown lens model $name")
        }
      val canvasSquare = root.number("canvasSquare") ?: 0.0
      require(canvasSquare > 0 && canvasSquare.isFinite()) { "no canvas square" }
      val maxTheta = root.number("maxTheta") ?: DEFAULT_MAX_THETA
      val blendStart = root.number("blendStart") ?: DEFAULT_BLEND_START
      val blendEnd = root.number("blendEnd") ?: DEFAULT_BLEND_END
      require(blendStart > 0 && blendStart < blendEnd && blendEnd <= maxTheta && maxTheta <= 180) {
        "theta limits $blendStart, $blendEnd, $maxTheta"
      }
      val lenses = root.array("lenses").map { lensOf(it.jsonObject, model, common.tracks.size) }
      require(lenses.size == 2) { "${lenses.size} lenses instead of 2" }
      return RawProjection(
        version = 2,
        kind = common.kind,
        layout = common.layout,
        camera = common.camera,
        frameWidth = common.frameWidth,
        frameHeight = common.frameHeight,
        tracks = common.tracks,
        secondUrl = common.secondUrl,
        secondFallbackUrl = common.secondFallbackUrl,
        trackOrder = common.trackOrder,
        model = model,
        canvasSquare = canvasSquare,
        maxThetaDegrees = maxTheta,
        blendStartDegrees = blendStart,
        blendEndDegrees = blendEnd,
        lenses = lenses,
        eac = null,
      )
    }

    private fun lensOf(json: JsonObject, model: LensModel, textures: Int): RawLens {
      val texture = json.integer("texture") ?: throw IllegalArgumentException("lens without texture")
      require(texture in 0 until textures) { "lens texture $texture of $textures" }
      val region = json.numbers("region") ?: throw IllegalArgumentException("lens without region")
      require(
        region.size == 4 && region.all { it.isFinite() } && region[0] >= 0 && region[1] >= 0 && region[2] > 0 &&
          region[3] > 0 && region[0] + region[2] <= 1 + 1e-9 && region[1] + region[3] <= 1 + 1e-9,
      ) { "region ${region.toList()} outside the texture" }
      val viewToLens = json.numbers("viewToLens") ?: throw IllegalArgumentException("lens without viewToLens")
      require(viewToLens.size == 9 && viewToLens.all { it.isFinite() }) { "viewToLens is not 9 finite numbers" }
      require(abs(determinant(viewToLens) - 1) < 1e-3) { "viewToLens is not a rotation" }
      val lens =
        RawLens(
          texture = texture,
          region = region,
          cx = json.number("cx") ?: throw IllegalArgumentException("lens without cx"),
          cy = json.number("cy") ?: throw IllegalArgumentException("lens without cy"),
          fx = json.number("fx") ?: 0.0,
          fy = json.number("fy") ?: 0.0,
          xi = json.number("xi") ?: 0.0,
          k = DoubleArray(5) { json.number("k${it + 1}") ?: 0.0 },
          p1 = json.number("p1") ?: 0.0,
          p2 = json.number("p2") ?: 0.0,
          radius = json.number("radius") ?: 0.0,
          radiusTheta = json.number("radiusTheta") ?: DEFAULT_RADIUS_THETA,
          viewToLens = viewToLens,
        )
      when (model) {
        LensModel.MEI -> require(lens.fx > 0 && lens.fy > 0 && lens.xi >= 0) { "Mei lens without fx, fy or xi" }
        LensModel.KANNALA_BRANDT -> require(lens.fx > 0 && lens.fy > 0) { "Kannala-Brandt lens without fx or fy" }
        LensModel.EQUIDISTANT ->
          require(lens.radius > 0 && lens.radiusTheta > 0) { "equidistant lens without radius" }
      }
      require(listOf(lens.cx, lens.cy, lens.fx, lens.fy, lens.xi, lens.p1, lens.p2).all { it.isFinite() } &&
        lens.k.all { it.isFinite() }) { "lens with a value that is not finite" }
      return lens
    }

    private fun eacOf(root: JsonObject, common: Common): RawProjection {
      val face = root.integer("face") ?: 0
      val overlap = root.integer("overlap") ?: -1
      val half = root.integer("half") ?: 0
      val middle = root.integer("middle") ?: 0
      val right = root.integer("right") ?: 0
      require(face > 0 && overlap >= 0 && half > 0) { "EAC geometry face $face overlap $overlap half $half" }
      require(middle == 2 * half && right == middle + face) { "EAC slots middle $middle right $right" }
      for (track in common.tracks) {
        require(track.width == right + 2 * half && track.height == face) {
          "EAC track ${track.width}x${track.height} for faces of $face"
        }
      }
      val viewToCamera = root.numbers("viewToCamera") ?: throw IllegalArgumentException("no viewToCamera")
      require(viewToCamera.size == 9 && viewToCamera.all { it.isFinite() }) { "viewToCamera is not 9 numbers" }
      // A reflection is allowed: the MAX's matrix flips y before its quarter turn
      require(abs(abs(determinant(viewToCamera)) - 1) < 1e-3) { "viewToCamera is not orthonormal" }
      val faces = root.array("faces").map { faceOf(it.jsonObject) }
      require(faces.size == 6) { "${faces.size} EAC faces instead of 6" }
      val slots = faces.map { it.texture to it.slot }.toSet()
      require(slots == (0..1).flatMap { t -> (0..2).map { t to it } }.toSet()) { "EAC faces do not fill every slot" }
      return RawProjection(
        version = 2,
        kind = common.kind,
        layout = common.layout,
        camera = common.camera,
        frameWidth = common.frameWidth,
        frameHeight = common.frameHeight,
        tracks = common.tracks,
        secondUrl = common.secondUrl,
        secondFallbackUrl = common.secondFallbackUrl,
        trackOrder = common.trackOrder,
        model = null,
        canvasSquare = 0.0,
        maxThetaDegrees = 0.0,
        blendStartDegrees = 0.0,
        blendEndDegrees = 0.0,
        lenses = emptyList(),
        eac = EacGeometry(face, overlap, half, middle, right, viewToCamera, faces),
      )
    }

    private fun faceOf(json: JsonObject): EacFace {
      val face =
        EacFace(
          texture = json.integer("texture") ?: -1,
          slot = json.integer("slot") ?: -1,
          forward = json.numbers("forward") ?: DoubleArray(0),
          right = json.numbers("right") ?: DoubleArray(0),
          down = json.numbers("down") ?: DoubleArray(0),
        )
      val basis = listOf(face.forward, face.right, face.down)
      require(basis.all { it.size == 3 && it.all { v -> v.isFinite() } }) { "EAC face without its three axes" }
      // Unit and orthogonal: the shader divides by the forward component and takes the others as tangents
      for (a in basis.indices) {
        for (b in basis.indices) {
          require(abs(dot(basis[a], basis[b]) - if (a == b) 1.0 else 0.0) < 1e-3) { "EAC face axes not orthonormal" }
        }
      }
      return face
    }

    private fun trackOf(json: JsonObject): RawTrack =
      RawTrack(
        file = json.integer("file") ?: 0,
        videoTrack = json.integer("videoTrack") ?: 0,
        trackId = json.integer("trackId"),
        width = (json.integer("width") ?: 0).coerceAtLeast(0),
        height = (json.integer("height") ?: 0).coerceAtLeast(0),
        codec = json.string("codec"),
        codecs = json.string("codecs"),
        bitDepth = json.integer("bitDepth") ?: 0,
        frameRate = json.number("frameRate")?.takeIf { it.isFinite() && it > 0 } ?: 0.0,
      )

    /**
     * A JSON of builds 16 and 17 as version 2: side by side, lens i in its half of the one frame, the canvas
     * convention unchanged, viewToLens computed the build 17 way ([DualFisheyeCalibration.viewToLens]), so that the
     * picture does not move.
     */
    private fun fromVersion1(calibration: DualFisheyeCalibration): RawProjection {
      val model = if (calibration.model == DualFisheyeModel.MEI) LensModel.MEI else LensModel.EQUIDISTANT
      val lenses =
        calibration.lenses.mapIndexed { index, lens ->
          RawLens(
            texture = 0,
            region = doubleArrayOf(0.5 * index, 0.0, 0.5, 1.0),
            cx = lens.cx,
            cy = lens.cy,
            fx = lens.fx,
            fy = lens.fy,
            xi = lens.xi,
            k = doubleArrayOf(lens.k1, lens.k2, lens.k3, 0.0, 0.0),
            p1 = lens.p1,
            p2 = lens.p2,
            radius = lens.radius,
            radiusTheta = DualFisheyeCalibration.EQUIDISTANT_RADIUS_DEGREES,
            viewToLens = calibration.viewToLens(index).map { it.toDouble() }.toDoubleArray(),
          )
        }
      val track =
        RawTrack(0, 0, null, calibration.frameWidth, calibration.frameHeight, null, null, 0, 0.0)
      return RawProjection(
        version = 1,
        kind = RawKind.DUAL_FISHEYE,
        layout = RawLayout.SIDE_BY_SIDE,
        camera = null,
        frameWidth = calibration.frameWidth,
        frameHeight = calibration.frameHeight,
        tracks = listOf(track),
        secondUrl = null,
        secondFallbackUrl = null,
        trackOrder = null,
        model = model,
        canvasSquare = calibration.canvasSquare,
        maxThetaDegrees = DEFAULT_MAX_THETA,
        blendStartDegrees = DEFAULT_BLEND_START,
        blendEndDegrees = DEFAULT_BLEND_END,
        lenses = lenses,
        eac = null,
      )
    }

    internal fun multiply(m: DoubleArray, v: DoubleArray): DoubleArray =
      DoubleArray(3) { row -> m[row * 3] * v[0] + m[row * 3 + 1] * v[1] + m[row * 3 + 2] * v[2] }

    internal fun dot(a: DoubleArray, b: DoubleArray): Double = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

    internal fun determinant(m: DoubleArray): Double =
      m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])

    private fun normalize(v: DoubleArray): DoubleArray {
      val length = sqrt(dot(v, v))
      return if (length > 0) DoubleArray(3) { v[it] / length } else v
    }

    /** The unit direction of d.xy, (0, 0) on the axis where it has none. */
    private fun unitXy(d: DoubleArray): Pair<Double, Double> {
      val length = sqrt(d[0] * d[0] + d[1] * d[1])
      return if (length > 1e-12) (d[0] / length) to (d[1] / length) else 0.0 to 0.0
    }

    /** GLSL smoothstep, so that the CPU reference blends exactly like the shaders. */
    internal fun smoothstep(edge0: Double, edge1: Double, x: Double): Double {
      val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0.0, 1.0)
      return t * t * (3 - 2 * t)
    }

    private fun JsonObject.string(key: String): String? =
      (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.number(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull

    private fun JsonObject.integer(key: String): Int? =
      (this[key] as? JsonPrimitive)?.let { primitive ->
        primitive.intOrNull
          ?: primitive.doubleOrNull?.takeIf { it == Math.rint(it) && abs(it) < Int.MAX_VALUE }?.toInt()
      }

    private fun JsonObject.array(key: String): JsonArray =
      this[key] as? JsonArray ?: throw IllegalArgumentException("no $key")

    private fun JsonObject.numbers(key: String): DoubleArray? =
      runCatching {
        (this[key] as JsonArray).map { (it as JsonPrimitive).doubleOrNull!! }.toDoubleArray()
      }.getOrNull()
  }
}
