package app.alextran.immich.immersive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * What the stereo quad of the viewer is asked to show, read once from the stereoPair JSON of ImmersiveApi.open: an
 * Apple spatial photo (two HEIF items, see [StereoPairSpec]), a flat photo holding two eyes side by side (ours, made
 * from a 2D photo by a computer, or another tool's, see [SbsPhotoSpec]), or a flat photo whose right eye the headset
 * makes from its estimated depth (see [DepthReliefSpec]), or a photo that carries a 3D scene a computer made from one
 * photo (see [VolumetricSceneSpec]); and the flat 3D photos told by their file name (see [FlatStereoSpec]) and the
 * ordinary photos opened on the big screen (see [BigScreenSpec]), each with a contract of its own. The JSON of the last three is frozen in
 * mobile/test/fixtures/ai_immersive/stereo_pair_contract_v1.json, which the Dart side writes against
 * (design-final 2026-10-26, section 4.1, and design-final 2026-10-27, section 8.5). A kind or a version this build does
 * not know reads as none: the viewer then shows the photo flat, as before.
 */
internal sealed interface StereoPhotoKind {
  /** The relief was estimated by AI: the quad says so, and stays within 60 degrees (see StereoComposer.maxAngle). */
  val isEstimatedRelief: Boolean

  /** The left eye is the photo itself, untouched: the 2D button says "2D (original)". */
  val leftEyeIsOriginal: Boolean

  data class HeicPair(val spec: StereoPairSpec) : StereoPhotoKind {
    override val isEstimatedRelief: Boolean
      get() = false

    override val leftEyeIsOriginal: Boolean
      get() = false
  }

  data class Sbs(val spec: SbsPhotoSpec) : StereoPhotoKind {
    override val isEstimatedRelief: Boolean
      get() = spec.origin == SbsPhotoSpec.Origin.ESTIMATED_DEPTH

    override val leftEyeIsOriginal: Boolean
      get() = spec.leftEye == SbsPhotoSpec.LeftEye.ORIGINAL
  }

  data class DepthRelief(val spec: DepthReliefSpec) : StereoPhotoKind {
    override val isEstimatedRelief: Boolean
      get() = true

    override val leftEyeIsOriginal: Boolean
      get() = true
  }

  /**
   * A flat 3D photo told by its file name (see [FlatStereoSpec]): its two eyes cut from the frame as it packs them. The
   * file of another tool: the quad claims nothing about how it was made.
   */
  data class Flat(val spec: FlatStereoSpec) : StereoPhotoKind {
    override val isEstimatedRelief: Boolean
      get() = false

    override val leftEyeIsOriginal: Boolean
      get() = false
  }

  /**
   * An ordinary photo opened with "View on a big screen" (see [BigScreenSpec]): one picture, upright as its EXIF says,
   * shown whole on the flat screen in front of the user. Nothing to claim about it.
   */
  data object BigScreen : StereoPhotoKind {
    override val isEstimatedRelief: Boolean
      get() = false

    override val leftEyeIsOriginal: Boolean
      get() = false
  }

  /**
   * The quad shows the preview of the file flat, as it showed an unknown kind, until the scene viewer takes this kind
   * before the quad: no relief label, no "2D (original)".
   */
  data class VolumetricScene(val spec: VolumetricSceneSpec) : StereoPhotoKind {
    override val isEstimatedRelief: Boolean
      get() = false

    override val leftEyeIsOriginal: Boolean
      get() = false
  }

  companion object {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The request [text] holds, null for a missing or damaged JSON, another kind or version (a newer Flutter side),
     * or values that cannot be right. kotlinx.serialization rather than org.json, which is a stub in the JVM tests.
     */
    fun parse(text: String?): StereoPhotoKind? {
      if (text.isNullOrBlank()) return null
      val root =
        try {
          json.parseToJsonElement(text) as? JsonObject
        } catch (e: Exception) {
          // Not JSON at all: shown flat, as an unknown kind (the viewer logs it)
          null
        } ?: return null
      return when (root.string("kind")) {
        StereoPairSpec.KIND -> StereoPairSpec.parse(text)?.let(::HeicPair)
        SbsPhotoSpec.KIND -> SbsPhotoSpec.fromJson(root)?.let(::Sbs)
        DepthReliefSpec.KIND -> DepthReliefSpec.fromJson(root)?.let(::DepthRelief)
        VolumetricSceneSpec.KIND -> VolumetricSceneSpec.fromJson(root)?.let(::VolumetricScene)
        FlatStereoSpec.KIND -> FlatStereoSpec.fromJson(root)?.let(::Flat)
        BigScreenSpec.KIND -> if (BigScreenSpec.fromJson(root)) BigScreen else null
        else -> null
      }
    }
  }
}

/**
 * The bigScreen request (the stereoPair JSON of ImmersiveApi.open for an ordinary photo or video opened with "View on
 * a big screen", see BigScreenRequest on the Dart side and mobile/test/fixtures/ai_immersive/big_screen_contract_v1.json):
 * a photo goes on the stereo quad as one picture ([StereoPhotoKind.BigScreen]), a video on the flat video screen, both
 * whole, larger than the 2D window shows them. "View on a big screen" is an idea of Gaurav Mukherjee (gmfun/Immuch360,
 * branch quest/flat-3d, commit 502779b0b), carried here by its own kind rather than a flat format.
 */
internal object BigScreenSpec {
  const val KIND = "bigScreen"
  const val VERSION = 1

  /** Whether [root] is a request of this kind and version. */
  fun fromJson(root: JsonObject): Boolean = root.string("kind") == KIND && root.integer("version") == VERSION

  /** Whether [text] holds a request this build reads. */
  fun isRequest(text: String?): Boolean = StereoPhotoKind.parse(text) == StereoPhotoKind.BigScreen
}

/** The value of [key] when it is there and not null. */
internal fun JsonObject.primitive(key: String): JsonPrimitive? =
  (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }

/** The text of [key] when it is a JSON string. */
internal fun JsonObject.string(key: String): String? = primitive(key)?.takeIf { it.isString }?.content

/** The whole number of [key] when it is a JSON number without a fraction. */
internal fun JsonObject.integer(key: String): Int? = primitive(key)?.takeIf { !it.isString }?.intOrNull

/** The finite number of [key] when it is a JSON number. */
internal fun JsonObject.finite(key: String): Double? =
  primitive(key)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() }

/**
 * How the viewer first shows a relief it made (ReliefViewMode in lib/domain/models/ai_immersive): both eyes on the
 * stereo quad, or the photo on a mesh moved by its depth map that follows the head (2.5D, experimental, see
 * [ReliefMesh]). The 3D button of the quad switches between 3D, 2.5D and 2D whatever the request says.
 */
internal enum class ReliefViewMode(val json: String) {
  STEREO("stereo"),
  MESH_25D("mesh25d");

  companion object {
    /** The mode of [value]; stereo for a missing value or one this build does not know, the safe default */
    fun of(value: String?): ReliefViewMode = entries.firstOrNull { it.json == value } ?: STEREO
  }
}

/**
 * A flat photo whose relief the headset estimates (design-final 2026-10-26, sections 3.4 and 3.7): the model file on
 * the headset and its size, checked before it loads, its identifier, the key of the cached depth map (a file name of
 * the cache, so 64 hexadecimal digits and nothing else), the settings of relief-v1, the quarter turns the user gave
 * the photo, clockwise, and the [mode] it first shows in ("mode" is written for 2.5D only: without it, stereo). Read
 * here; the relief itself comes with the AI relief of the headset.
 */
internal data class DepthReliefSpec(
  val model: String,
  val modelSize: Long,
  val modelId: String,
  val cacheKey: String,
  val parallax: Double,
  val convergence: Double,
  val quarterTurns: Int,
  val mode: ReliefViewMode = ReliefViewMode.STEREO,
) {
  companion object {
    const val KIND = "depthRelief"
    const val VERSION = 1

    private val cacheKeyForm = Regex("[0-9a-f]{64}")

    /** The request of [root], null for another version, a missing field or a value that cannot be right. */
    fun fromJson(root: JsonObject): DepthReliefSpec? {
      if (root.string("kind") != KIND || root.integer("version") != VERSION) return null
      fun number(key: String): Double? =
        root.primitive(key)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() }
      val spec =
        DepthReliefSpec(
          model = root.string("model") ?: return null,
          modelSize = root.primitive("modelSize")?.takeIf { !it.isString }?.longOrNull ?: return null,
          modelId = root.string("modelId") ?: return null,
          cacheKey = root.string("cacheKey") ?: return null,
          parallax = number("parallax") ?: return null,
          convergence = number("convergence") ?: return null,
          quarterTurns = (root.integer("quarterTurns") ?: return null) and 3,
          mode = ReliefViewMode.of(root.string("mode")),
        )
      return spec.takeIf {
        it.model.isNotBlank() &&
          it.modelSize > 0 &&
          it.modelId.isNotBlank() &&
          cacheKeyForm.matches(it.cacheKey) &&
          it.parallax >= 0 &&
          it.convergence in 0.0..1.0
      }
    }
  }
}

/**
 * A photo that carries a 3D scene (design-final 2026-10-27, sections 3.2 and 8.5): a JPEG preview, then the scene in
 * the glb-layers-v1 [format] in the last [sceneLength] bytes of the file, checked by [sceneSha256]. The sizes are those
 * the gate of the headset weighs before reading the scene; the [safe] zone is in metres around the eye at the start,
 * after the comfort [scale]; [fovDegrees] is the horizontal field of view of the photo. [flags] are the quality flags
 * of the file, a token this build does not know kept and left aside by the viewer. The XMP at the head of the file is
 * read again when the scene opens, and wins over this JSON.
 */
internal data class VolumetricSceneSpec(
  val format: String,
  val sceneLength: Long,
  val sceneSha256: String,
  val meshes: Int,
  val vertices: Int,
  val triangles: Int,
  val textureMax: Int,
  val scale: Double,
  val safe: SafeZone,
  val fovDegrees: Double,
  val origin: Origin,
  val flags: List<String>,
) {
  /** How far the eye may go from where it started, in metres, before the scene flattens (SceneNavigator). */
  data class SafeZone(val lateral: Double, val vertical: Double, val forward: Double, val backward: Double)

  enum class Origin(val json: String) {
    RECONSTRUCTED_FROM_PHOTO("reconstructedFromPhoto"),
    UNKNOWN("unknown"),
  }

  companion object {
    const val KIND = "volumetricScene"
    const val VERSION = 1

    /** The only scene format this build reads: our meshes and their textures, see GlbReader. */
    const val FORMAT = "glb-layers-v1"

    private val sha256Form = Regex("[0-9a-f]{64}")

    /**
     * The request of [root], null for another version or format, a missing field or a value that cannot be right. An
     * origin this build does not know reads as unknown, as the Dart side reads it.
     */
    fun fromJson(root: JsonObject): VolumetricSceneSpec? {
      if (root.string("kind") != KIND || root.integer("version") != VERSION) return null
      if (root.string("format") != FORMAT) return null
      val safe = root["safe"] as? JsonObject ?: return null
      val flags =
        when (val value = root["flags"]) {
          null,
          is JsonNull -> emptyList()
          is JsonArray -> value.mapNotNull { (it as? JsonPrimitive)?.takeIf { flag -> flag.isString }?.content }
          else -> return null
        }
      val spec =
        VolumetricSceneSpec(
          format = FORMAT,
          sceneLength = root.primitive("sceneLength")?.takeIf { !it.isString }?.longOrNull ?: return null,
          sceneSha256 = root.string("sceneSha256") ?: return null,
          meshes = root.integer("meshes") ?: return null,
          vertices = root.integer("vertices") ?: return null,
          triangles = root.integer("triangles") ?: return null,
          textureMax = root.integer("textureMax") ?: return null,
          scale = root.finite("scale") ?: return null,
          safe =
            SafeZone(
              lateral = safe.finite("lateral") ?: return null,
              vertical = safe.finite("vertical") ?: return null,
              forward = safe.finite("forward") ?: return null,
              backward = safe.finite("backward") ?: return null,
            ),
          fovDegrees = root.finite("fovDegrees") ?: return null,
          origin = root.string("origin").let { value -> Origin.entries.firstOrNull { it.json == value } }
            ?: Origin.UNKNOWN,
          flags = flags,
        )
      return spec.takeIf {
        it.sceneLength > 0 &&
          sha256Form.matches(it.sceneSha256) &&
          it.meshes > 0 &&
          it.vertices > 0 &&
          it.triangles > 0 &&
          it.textureMax > 0 &&
          it.scale > 0 &&
          it.safe.lateral >= 0 &&
          it.safe.vertical >= 0 &&
          it.safe.forward >= 0 &&
          it.safe.backward >= 0 &&
          it.fovDegrees > 0 &&
          it.fovDegrees < 180
      }
    }
  }
}
