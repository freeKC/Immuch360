package app.alextran.immich.immersive

import kotlinx.serialization.json.Json
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
 * makes from its estimated depth (see [DepthReliefSpec]). The JSON of the last two is frozen in
 * mobile/test/fixtures/ai_immersive/stereo_pair_contract_v1.json, which the Dart side writes against
 * (design-final 2026-10-26, section 4.1). A kind or a version this build does not know reads as none: the viewer then
 * shows the photo flat, as before.
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
        else -> null
      }
    }
  }
}

/** The value of [key] when it is there and not null. */
internal fun JsonObject.primitive(key: String): JsonPrimitive? =
  (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }

/** The text of [key] when it is a JSON string. */
internal fun JsonObject.string(key: String): String? = primitive(key)?.takeIf { it.isString }?.content

/** The whole number of [key] when it is a JSON number without a fraction. */
internal fun JsonObject.integer(key: String): Int? = primitive(key)?.takeIf { !it.isString }?.intOrNull

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
