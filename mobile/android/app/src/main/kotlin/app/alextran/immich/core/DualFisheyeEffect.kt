package app.alextran.immich.core

import android.content.Context
import android.graphics.Matrix
import android.opengl.GLES20
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import androidx.media3.effect.MatrixTransformation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.Renderer
import app.alextran.immich.core.raw.RawKind
import app.alextran.immich.core.raw.RawLayout
import app.alextran.immich.core.raw.RawProjection
import app.alextran.immich.core.raw.RawStitchShaders
import app.alextran.immich.core.raw.RawStitchUniforms
import kotlin.math.roundToInt

/**
 * Media3 video effect that stitches the frame of a raw 360° video whose two fisheye lenses are side by side in one
 * track (an Insta360 .insv of the X3 and earlier: lens 0 on the left half) into an equirectangular frame, which the
 * players then map on the sphere like any 360° video. The mapping is the one of section 4.1 of the projections design,
 * see [RawProjection]: for every output texel the view direction, rotated into each lens, the Mei, equidistant or
 * Kannala-Brandt projection to a pixel of that lens' square, the square's region of the frame, and a blend of the two
 * lenses by angle off their axes. The shader is the GLSL ES 1.00 emission of [RawStitchShaders], the same mapping the
 * lens compositor draws for two tracks or two files.
 *
 * ExoPlayer runs it on its own GL thread once [ExoPlayer.setVideoEffects] got it before prepare. A shader that cannot
 * be built (a GL error on an unusual GPU) logs and lets the frame through as it is, the two circles then show on the
 * sphere instead of an error.
 */
@OptIn(UnstableApi::class)
class DualFisheyeEffect(
  private val projection: RawProjection,
  /**
   * The largest stitched frame worth drawing, the size of the surface it ends on (0 for the decoded size): a 5.7K
   * frame stitched at its own size and scaled down to a 4K surface afterwards would cost twice the fragment work.
   */
  private val maxOutputWidth: Int = 0,
  private val maxOutputHeight: Int = 0,
) : GlEffect {
  init {
    require(projection.kind == RawKind.DUAL_FISHEYE && projection.layout == RawLayout.SIDE_BY_SIDE) {
      "the effect stitches side by side fisheye frames only"
    }
  }

  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
    try {
      DualFisheyeShaderProgram(projection, useHdr, maxOutputWidth, maxOutputHeight)
    } catch (e: Exception) {
      // A GL error (GlUtil.GlException), or a uniform the driver optimized away (a null from GlProgram)
      Log.e(TAG, "cannot build the dual fisheye shader, the raw frame shows as it is", e)
      passthrough(context, useHdr)
    }

  /** The identity matrix through Media3's default shader: a plain copy of the frame. */
  private fun passthrough(context: Context, useHdr: Boolean): GlShaderProgram =
    MatrixTransformation { Matrix() }.toGlShaderProgram(context, useHdr)

  companion object {
    private const val TAG = "DualFisheyeEffect"

    /**
     * A failure of the Media3 frame processor the effect runs in, at its creation (the EGL or GL setup) or while
     * drawing: the players then play the frame unstitched.
     */
    fun isStitchingError(error: PlaybackException): Boolean =
      error.errorCode == PlaybackException.ERROR_CODE_VIDEO_FRAME_PROCESSOR_INIT_FAILED ||
        error.errorCode == PlaybackException.ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED

    /**
     * The effect for the rawProjection JSON of Flutter, or null (logged) when it cannot be read or is not a side by
     * side fisheye frame.
     */
    fun fromJson(json: String?): DualFisheyeEffect? {
      if (json.isNullOrBlank()) return null
      return try {
        DualFisheyeEffect(RawProjection.parse(json))
      } catch (e: IllegalArgumentException) {
        Log.e(TAG, "unreadable dual fisheye calibration, the raw frame shows as it is: ${e.message}")
        null
      }
    }

    /**
     * Tells the video renderer of [player] the size of the plain Surface it renders to, once the effects are on. With
     * effects, Media3 draws the frame itself into that Surface and must know its size, which it only learns by itself
     * for a SurfaceView or a TextureView: setVideoSurface reports an unknown size, so this goes after every
     * setVideoSurface (the renderer also hands the new Surface to the effect pipeline only through this message).
     */
    fun setOutputResolution(player: ExoPlayer, width: Int, height: Int) {
      for (index in 0 until player.rendererCount) {
        if (player.getRendererType(index) != C.TRACK_TYPE_VIDEO) continue
        player
          .createMessage(player.getRenderer(index))
          .setType(Renderer.MSG_SET_VIDEO_OUTPUT_RESOLUTION)
          .setPayload(Size(width, height))
          .send()
      }
    }
  }
}

/**
 * The shader of [DualFisheyeEffect], with the uniforms of [RawStitchUniforms]: the two view to lens rotations, the
 * intrinsics of each lens in lens-local canvas pixels, the region of each lens in the frame, the lens model and
 * limits, and the half texel of the decoded frame (set in [configure], so that a transcoded stream at another
 * resolution maps the same way).
 *
 * Texture orientation: Media3 hands each effect a GL_TEXTURE_2D in the OpenGL convention, the texture of the decoder
 * already turned by the SurfaceTexture transform: t = 0 is the bottom row of the picture and t = 1 its top, and the
 * output is drawn the same way (t = 1 at the top of the frame, latitude +90 degrees). The regions count rows from the
 * top, hence the 1 - y flip when sampling.
 */
@OptIn(UnstableApi::class)
private class DualFisheyeShaderProgram(
  private val projection: RawProjection,
  useHdr: Boolean,
  private val maxOutputWidth: Int,
  private val maxOutputHeight: Int,
) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ useHdr, /* texturePoolCapacity= */ 1) {
  private val glProgram = GlProgram(RawStitchShaders.vertexEs1(), RawStitchShaders.fragmentEs1SideBySide())

  init {
    // The quad covers the whole output, from -1 to 1 in normalized device coordinates
    glProgram.setBufferAttribute(
      "aFramePosition",
      GlUtil.getNormalizedCoordinateBounds(),
      GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
    )
    // Uniforms a driver folds away (the texture index of each lens, both 0 here) are skipped
    for ((name, value) in RawStitchUniforms.fisheye(projection)) glProgram.setFloatsUniformIfPresent(name, value)
  }

  override fun configure(inputWidth: Int, inputHeight: Int): Size {
    for ((name, value) in RawStitchUniforms.halfTexels(projection, listOf(inputWidth to inputHeight))) {
      glProgram.setFloatsUniformIfPresent(name, value)
    }
    // The stitched frame is drawn straight at the size of the surface it ends on, no larger than the decoded frame,
    // keeping its shape: the shader only works in normalized output coordinates
    var scale = 1.0
    if (maxOutputWidth > 0) scale = minOf(scale, maxOutputWidth.toDouble() / inputWidth)
    if (maxOutputHeight > 0) scale = minOf(scale, maxOutputHeight.toDouble() / inputHeight)
    val width = (inputWidth * scale).roundToInt().coerceAtLeast(1)
    val height = (inputHeight * scale).roundToInt().coerceAtLeast(1)
    return Size(width, height)
  }

  override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
    try {
      glProgram.use()
      glProgram.setSamplerTexIdUniform(RawStitchShaders.SIDE_BY_SIDE_SAMPLER, inputTexId, /* texUnitIndex= */ 0)
      glProgram.bindAttributesAndUniforms()
      // The four vertex triangle strip forms the quad
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, /* first= */ 0, /* count= */ 4)
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e, presentationTimeUs)
    }
  }

  override fun release() {
    super.release()
    try {
      glProgram.delete()
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e)
    }
  }
}
