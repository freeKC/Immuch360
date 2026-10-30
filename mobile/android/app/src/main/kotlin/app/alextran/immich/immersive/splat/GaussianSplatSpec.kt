package app.alextran.immich.immersive.splat

import app.alextran.immich.immersive.integer
import app.alextran.immich.immersive.primitive
import app.alextran.immich.immersive.string
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.longOrNull

/**
 * The gaussianSplat request (the stereoPair JSON of ImmersiveApi.open for a splat file of another tool, lot S5, see
 * GaussianSplatRequest on the Dart side and mobile/test/fixtures/ai_immersive/gaussian_splat_contract_v1.json): the
 * [format] and [formatVersion] of the file, its [gaussians] and the degree of its spherical harmonics as its head said
 * to Flutter, its size in [fileBytes], the most gaussians the headset shows ([maxGaussians], 50 000, or 150 000 with
 * Large splats), the [tool] a comment of a PLY names, and the file [name], under which the orientation the user chose
 * is remembered. The viewer reads the head of the file again, which wins over this JSON.
 */
internal data class GaussianSplatSpec(
  val format: SplatFormat,
  val formatVersion: Int,
  val gaussians: Long,
  val shDegree: Int,
  val fileBytes: Long,
  val maxGaussians: Int,
  val tool: String?,
  val name: String,
) {
  companion object {
    const val KIND = "gaussianSplat"
    const val VERSION = 1

    /** The request of [root], null for another version or format, a missing field or a value that cannot be right */
    fun fromJson(root: JsonObject): GaussianSplatSpec? {
      if (root.string("kind") != KIND || root.integer("version") != VERSION) return null
      val tool =
        when (val value = root["tool"]) {
          null,
          is JsonNull -> null
          else -> root.string("tool") ?: return null
        }
      val spec =
        GaussianSplatSpec(
          format = SplatFormat.of(root.string("format")) ?: return null,
          formatVersion = root.integer("formatVersion") ?: return null,
          gaussians = root.primitive("gaussians")?.takeIf { !it.isString }?.longOrNull ?: return null,
          shDegree = root.integer("shDegree") ?: return null,
          fileBytes = root.primitive("fileBytes")?.takeIf { !it.isString }?.longOrNull ?: return null,
          maxGaussians = root.integer("maxGaussians") ?: return null,
          tool = tool,
          name = root.string("name") ?: return null,
        )
      return spec.takeIf {
        it.formatVersion >= 1 &&
          it.gaussians > 0 &&
          it.shDegree in 0..4 &&
          it.fileBytes > 0 &&
          it.maxGaussians > 0 &&
          it.name.isNotBlank()
      }
    }
  }
}
