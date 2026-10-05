package app.alextran.immich.core.raw

/**
 * The values of the uniforms of the stitch shaders ([RawStitchShaders]) for a [RawProjection], by uniform name, as
 * GlProgram takes them (floats; matrices column major, the way GLSL reads a mat3 uploaded without transpose). Pure,
 * so that the tests check what the GPU gets without a GL context.
 *
 * The fisheye intrinsics are lens-local canvas pixels (lens i's cx minus i times the canvas square): the shader divides
 * them by the square to get the fraction of the lens square, then maps that fraction into the lens region of its
 * texture, so a texture of any decoded size (an original, a transcoded stream, half of a side by side frame) draws
 * the same picture. Only the half texel that keeps bilinear reads inside a region depends on the decoded size, see
 * [halfTexel].
 */
object RawStitchUniforms {
  /** Shader value of each lens model, a float to keep the uniform list the same in GLSL ES 1.00 and 3.00. */
  fun modelValue(model: LensModel?): Float =
    when (model) {
      LensModel.MEI, null -> 0f
      LensModel.EQUIDISTANT -> 1f
      LensModel.KANNALA_BRANDT -> 2f
    }

  /** The uniforms of a fisheye pair that do not change with the decoded size. */
  fun fisheye(projection: RawProjection): Map<String, FloatArray> {
    require(projection.kind == RawKind.DUAL_FISHEYE) { "not a fisheye pair" }
    val values = mutableMapOf<String, FloatArray>()
    val square = projection.canvasSquare
    projection.lenses.forEachIndexed { index, lens ->
      values["uViewToLens$index"] = columnMajor(lens.viewToLens)
      values["uIntr$index"] = floats(lens.fx, lens.fy, lens.cx - index * square, lens.cy)
      values["uK$index"] = floats(lens.k[0], lens.k[1], lens.k[2], lens.k[3])
      values["uX$index"] = floats(lens.k[4], lens.xi, lens.p1, lens.p2)
      values["uRegion$index"] = floats(lens.region[0], lens.region[1], lens.region[2], lens.region[3])
      values["uTexOf$index"] = floats(lens.texture.toDouble())
      values["uEquidistantFocal$index"] =
        floats(if (projection.model == LensModel.EQUIDISTANT) RawProjection.equidistantFocal(lens) else 0.0)
    }
    values["uModel"] = floatArrayOf(modelValue(projection.model))
    values["uSquare"] = floats(square)
    values["uTheta"] =
      floats(
        Math.toRadians(projection.maxThetaDegrees),
        Math.toRadians(projection.blendStartDegrees),
        Math.toRadians(projection.blendEndDegrees),
      )
    return values
  }

  /**
   * The half texel of each lens for textures of the decoded sizes [textureSizes] (width, height of `tracks[k]`), as
   * fractions of the texture: a lens region is read no closer to its border than half a texel, so that bilinear
   * sampling never mixes in the other lens of a side by side frame. A size not known yet counts as the declared one.
   */
  fun halfTexels(projection: RawProjection, textureSizes: List<Pair<Int, Int>?>): Map<String, FloatArray> =
    projection.lenses.withIndex().associate { (index, lens) ->
      val declared = projection.tracks.getOrNull(lens.texture)
      val size = textureSizes.getOrNull(lens.texture) ?: ((declared?.width ?: 0) to (declared?.height ?: 0))
      "uHalfTexel$index" to halfTexel(size.first, size.second)
    }

  /** Half a texel of a [width] x [height] texture, in fractions of it (0 for an unknown size). */
  fun halfTexel(width: Int, height: Int): FloatArray =
    floatArrayOf(if (width > 0) 0.5f / width else 0f, if (height > 0) 0.5f / height else 0f)

  /**
   * The uniforms of the GoPro EAC pair: the view to camera matrix, each face as a matrix whose rows are its right,
   * down and forward axes (so that `face * c` gives the coordinates of c on the face, forward in z), the texture and
   * slot of each face, the geometry and the declared track size the pixel positions are divided by.
   */
  fun eac(projection: RawProjection): Map<String, FloatArray> {
    val geometry = projection.eac ?: throw IllegalArgumentException("not an EAC pair")
    val values = mutableMapOf<String, FloatArray>()
    values["uViewToCamera"] = columnMajor(geometry.viewToCamera)
    geometry.faces.forEachIndexed { index, face ->
      val rows = DoubleArray(9) { i ->
        when (i / 3) {
          0 -> face.right[i % 3]
          1 -> face.down[i % 3]
          else -> face.forward[i % 3]
        }
      }
      values["uFace$index"] = columnMajor(rows)
      values["uFaceSlot$index"] = floats(face.texture.toDouble(), face.slot.toDouble())
    }
    values["uEac"] =
      floats(
        geometry.face.toDouble(),
        geometry.half.toDouble(),
        geometry.overlap.toDouble(),
        geometry.middle.toDouble(),
      )
    values["uEacRight"] = floats(geometry.right.toDouble())
    values["uTrackSize"] = floats(geometry.trackWidth.toDouble(), geometry.face.toDouble())
    return values
  }

  /** Which of the two textures are decoded: 1 for a decoded stream, 0 for the other one in one lens mode. */
  fun enabled(streams: Collection<Int>): FloatArray =
    floatArrayOf(if (0 in streams) 1f else 0f, if (1 in streams) 1f else 0f)

  /** A row major 3x3 matrix as GLSL reads a mat3 uniform (column major, no transpose in GLES 2). */
  fun columnMajor(rowMajor: DoubleArray): FloatArray = FloatArray(9) { rowMajor[(it % 3) * 3 + it / 3].toFloat() }

  private fun floats(vararg values: Double): FloatArray = FloatArray(values.size) { values[it].toFloat() }
}
