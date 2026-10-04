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
import kotlin.math.roundToInt

/**
 * Media3 video effect that stitches the frame of a raw dual fisheye video (an Insta360 .insv: the two fisheye circles
 * side by side, lens 0 on the left half) into an equirectangular frame of the same size, which the players then map
 * on the sphere like any 360° video. The mapping is the one of docs 16-dual-fisheye-spec.md section 3, see
 * [DualFisheyeCalibration]: for every output texel the view direction, rotated into each lens, the Mei (or
 * equidistant) projection to a pixel of that lens' square, and a blend of the two lenses between 85 and 95 degrees off
 * their axes.
 *
 * ExoPlayer runs it on its own GL thread once [ExoPlayer.setVideoEffects] got it before prepare. A shader that cannot
 * be built (a GL error on an unusual GPU) logs and lets the frame through as it is, the two circles then show on the
 * sphere instead of an error.
 */
@OptIn(UnstableApi::class)
class DualFisheyeEffect(
  private val calibration: DualFisheyeCalibration,
  /**
   * The largest stitched frame worth drawing, the size of the surface it ends on (0 for the decoded size): a 5.7K
   * frame stitched at its own size and scaled down to a 4K surface afterwards would cost twice the fragment work.
   */
  private val maxOutputWidth: Int = 0,
  private val maxOutputHeight: Int = 0,
) : GlEffect {
  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
    try {
      DualFisheyeShaderProgram(calibration, useHdr, maxOutputWidth, maxOutputHeight)
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

    /** The effect for the rawProjection JSON of Flutter, or null (logged) when it cannot be read. */
    fun fromJson(json: String?): DualFisheyeEffect? {
      if (json.isNullOrBlank()) return null
      return try {
        DualFisheyeEffect(DualFisheyeCalibration.parse(json))
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
 * The shader of [DualFisheyeEffect]. Uniforms: the two view to lens rotations (R_i * G, computed once on the CPU,
 * the same as multiplying by G then R_i in the shader), the intrinsics of each lens in canvas pixels, the canvas to
 * frame scale and the frame size (set in [configure] from the decoded size, so that a transcoded stream at another
 * resolution maps the same way), and the lens model.
 *
 * Texture orientation: Media3 hands each effect a GL_TEXTURE_2D in the OpenGL convention, the texture of the decoder
 * already turned by the SurfaceTexture transform: t = 0 is the bottom row of the picture and t = 1 its top, and the
 * output is drawn the same way (t = 1 at the top of the frame, latitude +90 degrees). The canvas pixels of the
 * calibration count rows from the top, hence the 1 - y flip when sampling.
 */
@OptIn(UnstableApi::class)
private class DualFisheyeShaderProgram(
  calibration: DualFisheyeCalibration,
  useHdr: Boolean,
  private val maxOutputWidth: Int,
  private val maxOutputHeight: Int,
) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ useHdr, /* texturePoolCapacity= */ 1) {
  private val glProgram = GlProgram(VERTEX_SHADER, FRAGMENT_SHADER)
  private val canvasSquare = calibration.canvasSquare

  init {
    // The quad covers the whole output, from -1 to 1 in normalized device coordinates
    glProgram.setBufferAttribute(
      "aFramePosition",
      GlUtil.getNormalizedCoordinateBounds(),
      GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
    )
    glProgram.setFloatsUniform("uViewToLens0", columnMajor(calibration.viewToLens(0)))
    glProgram.setFloatsUniform("uViewToLens1", columnMajor(calibration.viewToLens(1)))
    val equidistant = calibration.model == DualFisheyeModel.EQUIDISTANT
    calibration.lenses.forEachIndexed { index, lens ->
      // An equidistant lens uses its focal length in both fx and fy and no distortion
      val focal = DualFisheyeCalibration.equidistantFocal(lens)
      val fx = if (equidistant) focal else lens.fx
      val fy = if (equidistant) focal else lens.fy
      glProgram.setFloatsUniform(
        "uIntrinsics$index",
        floatArrayOf(fx.toFloat(), fy.toFloat(), lens.cx.toFloat(), lens.cy.toFloat()),
      )
      glProgram.setFloatsUniform(
        "uDistortion$index",
        floatArrayOf(lens.k1.toFloat(), lens.k2.toFloat(), lens.k3.toFloat(), lens.xi.toFloat()),
      )
      glProgram.setFloatsUniform("uTangential$index", floatArrayOf(lens.p1.toFloat(), lens.p2.toFloat()))
    }
    glProgram.setFloatUniform("uEquidistant", if (equidistant) 1f else 0f)
  }

  override fun configure(inputWidth: Int, inputHeight: Int): Size {
    // Two squares side by side: the square of one lens is half the width, the whole height. Each axis scales on its
    // own, so that a frame that is not exactly 2:1 still maps the whole square of each lens
    glProgram.setFloatsUniform(
      "uCanvasToFrame",
      floatArrayOf((inputWidth / 2.0 / canvasSquare).toFloat(), (inputHeight / canvasSquare).toFloat()),
    )
    glProgram.setFloatsUniform("uFrameSize", floatArrayOf(inputWidth.toFloat(), inputHeight.toFloat()))
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
      glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, /* texUnitIndex= */ 0)
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

  private companion object {
    /** A row major 3x3 matrix as GLSL reads a mat3 uniform (column major, no transpose in GLES 2). */
    fun columnMajor(rowMajor: FloatArray): FloatArray = FloatArray(9) { rowMajor[(it % 3) * 3 + it / 3] }

    /** The texture coordinate of each corner of the quad, from 0 to 1 */
    val VERTEX_SHADER =
      """
      attribute vec4 aFramePosition;
      varying vec2 vTexSamplingCoord;
      void main() {
        gl_Position = aFramePosition;
        vTexSamplingCoord = aFramePosition.xy * 0.5 + 0.5;
      }
      """
        .trimIndent()

    /**
     * GLSL ES 1.00, in high precision where the GPU has it: the Mei projection divides small numbers and the canvas
     * holds about 12000 pixels, beyond what medium precision keeps to the pixel. Angles are in radians: 100, 85 and
     * 95 degrees.
     */
    val FRAGMENT_SHADER =
      """
      #ifdef GL_FRAGMENT_PRECISION_HIGH
      precision highp float;
      #else
      precision mediump float;
      #endif

      uniform sampler2D uTexSampler;
      // View direction to the frame of each lens: R_i * G
      uniform mat3 uViewToLens0;
      uniform mat3 uViewToLens1;
      // fx, fy, cx, cy of each lens, in canvas pixels
      uniform vec4 uIntrinsics0;
      uniform vec4 uIntrinsics1;
      // k1, k2, k3, xi of each lens
      uniform vec4 uDistortion0;
      uniform vec4 uDistortion1;
      // p1, p2 of each lens
      uniform vec2 uTangential0;
      uniform vec2 uTangential1;
      // Frame pixels per canvas pixel, horizontally and vertically
      uniform vec2 uCanvasToFrame;
      // Width and height of the decoded frame, in pixels
      uniform vec2 uFrameSize;
      // 1 for the equidistant model, 0 for Mei
      uniform float uEquidistant;
      varying vec2 vTexSamplingCoord;

      const float PI = 3.14159265358979;
      const float MAX_THETA = 1.74532925;
      const float BLEND_START = 1.48352986;
      const float BLEND_END = 1.65806279;

      // Canvas pixel (x right, y down from the top) that sees the direction d of the lens frame
      vec2 project(vec3 d, vec4 intrinsics, vec4 distortion, vec2 tangential) {
        if (uEquidistant > 0.5) {
          float theta = acos(clamp(d.z, -1.0, 1.0));
          float off = length(d.xy);
          vec2 direction = off > 1e-6 ? d.xy / off : vec2(0.0);
          return intrinsics.zw + intrinsics.xy * theta * direction;
        }
        vec2 m = d.xy / max(d.z + distortion.w, 1e-3);
        float r2 = dot(m, m);
        float radial = 1.0 + r2 * (distortion.x + r2 * (distortion.y + r2 * distortion.z));
        float p1 = tangential.x;
        float p2 = tangential.y;
        vec2 distorted = vec2(
          radial * m.x + 2.0 * p1 * m.x * m.y + p2 * (r2 + 2.0 * m.x * m.x),
          radial * m.y + p1 * (r2 + 2.0 * m.y * m.y) + 2.0 * p2 * m.x * m.y);
        return intrinsics.xy * distorted + intrinsics.zw;
      }

      // Texture coordinate of the canvas pixel, kept inside the square of the lens (index 0 left, 1 right) so that
      // bilinear sampling never reaches the other lens; inside is 1 when the pixel lies in that square, else 0
      vec2 textureCoord(vec2 canvas, float index, out float inside) {
        vec2 pixel = canvas * uCanvasToFrame;
        float side = uFrameSize.x * 0.5;
        float left = index * side;
        inside = step(left, pixel.x) * step(pixel.x, left + side - 1.0)
          * step(0.0, pixel.y) * step(pixel.y, uFrameSize.y - 1.0);
        vec2 kept = clamp(pixel, vec2(left, 0.0), vec2(left + side - 1.0, uFrameSize.y - 1.0));
        // A pixel value is the centre of that pixel; texture rows count from the bottom
        return vec2((kept.x + 0.5) / uFrameSize.x, 1.0 - (kept.y + 0.5) / uFrameSize.y);
      }

      void main() {
        float lon = (vTexSamplingCoord.x * 2.0 - 1.0) * PI;
        float lat = (vTexSamplingCoord.y - 0.5) * PI;
        vec3 view = vec3(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon));
        vec3 d0 = uViewToLens0 * view;
        vec3 d1 = uViewToLens1 * view;
        float theta0 = acos(clamp(d0.z, -1.0, 1.0));
        float theta1 = acos(clamp(d1.z, -1.0, 1.0));
        float inside0;
        float inside1;
        vec2 uv0 = textureCoord(project(d0, uIntrinsics0, uDistortion0, uTangential0), 0.0, inside0);
        vec2 uv1 = textureCoord(project(d1, uIntrinsics1, uDistortion1, uTangential1), 1.0, inside1);
        float w0 = inside0 * step(theta0, MAX_THETA) * (1.0 - smoothstep(BLEND_START, BLEND_END, theta0));
        float w1 = inside1 * step(theta1, MAX_THETA) * (1.0 - smoothstep(BLEND_START, BLEND_END, theta1));
        vec4 color0 = texture2D(uTexSampler, uv0);
        vec4 color1 = texture2D(uTexSampler, uv1);
        float sum = w0 + w1;
        if (sum > 0.0) {
          gl_FragColor = (w0 * color0 + w1 * color1) / sum;
        } else {
          // Outside both blends (past 95 degrees, or off the squares): the nearer lens
          gl_FragColor = theta0 <= theta1 ? color0 : color1;
        }
      }
      """
        .trimIndent()
  }
}
