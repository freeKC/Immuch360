package app.alextran.immich.core.raw

import java.util.Locale

/**
 * GLSL of the raw 360° stitch, written once for the three projections of section 4 of the projections design (Mei
 * with k1 to k5 and p1, p2; equidistant; Kannala-Brandt with five terms; GoPro EAC with its overlap columns) and
 * emitted twice: GLSL ES 3.00 for [TwoLensCompositor], which reads the two decoded streams as external textures (with
 * the SurfaceTexture transform of each, and the HDR variants), and GLSL ES 1.00 for the side by side frame inside the
 * Media3 effect ([app.alextran.immich.core.DualFisheyeEffect]), which hands a GL_TEXTURE_2D with t = 0 at the bottom.
 *
 * Every lens and face value comes from uniforms ([RawStitchUniforms]), set by the names of [uniformsOf]; a test
 * checks the sources against those lists and compiles them with glslangValidator when it is installed.
 *
 * Output: the quad covers the whole equirectangular frame, v = 1 (the top of the frame, NDC y = +1) at latitude +90
 * degrees, the orientation build 17's effect wrote into the same destinations.
 */
object RawStitchShaders {
  /** How a 10 bit HDR stream is mapped to the 8 bit SDR destinations, see [HdrToneMap]. */
  enum class ToneMap { NONE, HLG, PQ }

  /**
   * A colour variant of the ES 3.00 program: [yuv] reads the raw Y'CbCr values through GL_EXT_YUV_target (10 bit,
   * BT.2020 matrix in the shader); otherwise the driver converts to RGB (samplerExternalOES), maybe at 8 bit.
   */
  data class Color(val yuv: Boolean, val toneMap: ToneMap) {
    val label: String
      get() = if (toneMap == ToneMap.NONE) "SDR" else "${if (yuv) "HDR_YUV" else "HDR_RGB"} $toneMap"

    companion object {
      val SDR = Color(yuv = false, toneMap = ToneMap.NONE)
    }
  }

  /** Uniforms every ES 3.00 program has: the two stream textures, their transforms, which are decoded. */
  val COMMON_UNIFORMS = listOf("uTex0", "uTex1", "uTexTransform0", "uTexTransform1", "uEnabled")

  /** The BT.2020 matrix and offset of the YUV variants. */
  val YUV_UNIFORMS = listOf("uYuvToRgb", "uYuvOffset")

  /** The fisheye pair, the same names in ES 1.00 and 3.00. */
  val FISHEYE_UNIFORMS =
    listOf(
      "uViewToLens0", "uViewToLens1", "uIntr0", "uIntr1", "uK0", "uK1", "uX0", "uX1", "uRegion0", "uRegion1",
      "uHalfTexel0", "uHalfTexel1", "uTexOf0", "uTexOf1", "uEquidistantFocal0", "uEquidistantFocal1", "uModel",
      "uSquare", "uTheta",
    )

  /** The EAC pair. */
  val EAC_UNIFORMS =
    listOf("uViewToCamera") + (0 until 6).map { "uFace$it" } + (0 until 6).map { "uFaceSlot$it" } +
      listOf("uEac", "uEacRight", "uTrackSize")

  /** The side by side texture of the Media3 effect. */
  const val SIDE_BY_SIDE_SAMPLER = "uTexSampler"

  /** Output size of the four tap variant, see [SUPERSAMPLE]. */
  const val OUTPUT_SIZE_UNIFORM = "uOutputSize"

  /**
   * Four reads per output pixel, a quarter pixel apart, against the shimmer of a 1.7 to 1.8 minification without
   * mipmaps (external textures have none). Off in build 18; switched on if the device test shows shimmer.
   */
  const val SUPERSAMPLE = false

  /** The uniforms of the ES 3.00 program of [kind] in [color]. */
  fun uniformsOf(kind: RawKind, color: Color): List<String> =
    COMMON_UNIFORMS + (if (color.yuv) YUV_UNIFORMS else emptyList()) +
      (if (kind == RawKind.EAC_GOPRO) EAC_UNIFORMS else FISHEYE_UNIFORMS) +
      (if (SUPERSAMPLE) listOf(OUTPUT_SIZE_UNIFORM) else emptyList())

  /** BT.2020 Y'CbCr to R'G'B', limited range, column major (Media3's DefaultShaderProgram constants, Apache 2.0). */
  val BT2020_LIMITED_YUV_TO_RGB =
    floatArrayOf(1.1689f, 1.1689f, 1.1689f, 0f, -0.1881f, 2.1502f, 1.6853f, -0.6530f, 0f)

  /** The same, full range. */
  val BT2020_FULL_YUV_TO_RGB = floatArrayOf(1f, 1f, 1f, 0f, -0.1646f, 1.8814f, 1.4746f, -0.5714f, 0f)

  /** Black level of luma and middle of chroma, limited and full range, as fractions of the 10 bit range. */
  val LIMITED_YUV_OFFSET = floatArrayOf(0.0625f, 0.5f, 0.5f)
  val FULL_YUV_OFFSET = floatArrayOf(0f, 0.5f, 0.5f)

  /** The vertex shader of the compositor: the quad, and the output position (0..1, v = 1 at the top) to the pixel. */
  fun vertexEs3(): String =
    """
    #version 300 es
    in vec4 aFramePosition;
    out vec2 vOut;
    void main() {
      gl_Position = aFramePosition;
      vOut = aFramePosition.xy * 0.5 + 0.5;
    }
    """
      .trimIndent()

  /**
   * The fragment shader of the compositor for [kind] in [color]. [essl3External] says whether the driver has
   * GL_OES_EGL_image_external_essl3; without it the source asks for GL_OES_EGL_image_external, as Media3's own ES 3
   * shaders do (drivers accept it there, the reference compiler does not).
   */
  fun fragmentEs3(kind: RawKind, color: Color, essl3External: Boolean = true): String {
    val header = buildString {
      appendLine("#version 300 es")
      appendLine(
        if (essl3External) "#extension GL_OES_EGL_image_external_essl3 : require"
        else "#extension GL_OES_EGL_image_external : require",
      )
      if (color.yuv) {
        appendLine("#extension GL_EXT_YUV_target : require")
        appendLine("#define YUV_INPUT")
      }
      when (color.toneMap) {
        ToneMap.HLG -> appendLine("#define TONE_MAP_HLG")
        ToneMap.PQ -> appendLine("#define TONE_MAP_PQ")
        ToneMap.NONE -> Unit
      }
      if (SUPERSAMPLE) appendLine("#define SUPERSAMPLE")
    }
    val stitch = if (kind == RawKind.EAC_GOPRO) "stitchEac" else "stitchFisheye"
    return header + ES3_INPUTS + COMMON_FUNCTIONS + TONE_MAP + (if (kind == RawKind.EAC_GOPRO) EAC else FISHEYE) +
      """
      void main() {
      #ifdef SUPERSAMPLE
        vec2 q = 0.25 / uOutputSize;
        vec3 color = 0.25 * ($stitch(viewDirection(vOut + vec2(-q.x, -q.y))) +
          $stitch(viewDirection(vOut + vec2(q.x, -q.y))) + $stitch(viewDirection(vOut + vec2(-q.x, q.y))) +
          $stitch(viewDirection(vOut + vec2(q.x, q.y))));
      #else
        vec3 color = $stitch(viewDirection(vOut));
      #endif
        outColor = vec4(toOutput(color), 1.0);
      }
      """
        .trimIndent() + "\n"
  }

  /** The vertex shader of the side by side effect (GLSL ES 1.00, as build 17). */
  fun vertexEs1(): String =
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
   * The fragment shader of the side by side effect: both lenses in the one GL_TEXTURE_2D Media3 hands it (t = 0 at
   * the bottom row), their regions from the JSON. High precision where the GPU has it: the canvas holds about 12000
   * pixels and theta^10 reaches a few hundred, beyond what medium precision keeps. No tone map: Media3 decides the HDR
   * handling of its own pipeline.
   */
  fun fragmentEs1SideBySide(): String =
    """
    #ifdef GL_FRAGMENT_PRECISION_HIGH
    precision highp float;
    #else
    precision mediump float;
    #endif
    uniform sampler2D $SIDE_BY_SIDE_SAMPLER;
    varying vec2 vTexSamplingCoord;

    // Fraction of the frame (top left origin) to its colour; the frame has both lenses
    vec3 sampleTexture(float tex, vec2 frac) {
      return texture2D($SIDE_BY_SIDE_SAMPLER, vec2(frac.x, 1.0 - frac.y)).rgb;
    }

    float enabledOf(float tex) {
      return 1.0;
    }

    """
      .trimIndent() + "\n" + COMMON_FUNCTIONS + FISHEYE +
      """
      void main() {
        gl_FragColor = vec4(stitchFisheye(viewDirection(vTexSamplingCoord)), 1.0);
      }
      """
        .trimIndent() + "\n"

  /** The uniforms of [fragmentEs1SideBySide]; uTexOf is folded away there (one texture). */
  val SIDE_BY_SIDE_UNIFORMS: List<String> = listOf(SIDE_BY_SIDE_SAMPLER) + FISHEYE_UNIFORMS

  /** A GLSL float literal of [value]: always a decimal point, no exponent. */
  private fun literal(value: Double): String {
    val text = String.format(Locale.ROOT, "%.8f", value).trimEnd('0')
    return if (text.endsWith('.')) "${text}0" else text
  }

  /**
   * Samplers, transforms and sampling of the two streams. highp on the samplers: external samplers default to lowp,
   * which would cut 10 bit values. A stream fraction (top left origin) goes through the SurfaceTexture transform
   * (which flips, crops and turns as the decoder needs) after the GL row flip.
   */
  private val ES3_INPUTS =
    """
    precision highp float;
    precision highp int;
    #ifdef YUV_INPUT
    uniform highp __samplerExternal2DY2YEXT uTex0;
    uniform highp __samplerExternal2DY2YEXT uTex1;
    // BT.2020 Y'CbCr to R'G'B' (limited or full range) and the offsets subtracted first
    uniform mat3 uYuvToRgb;
    uniform vec3 uYuvOffset;
    #else
    uniform highp samplerExternalOES uTex0;
    uniform highp samplerExternalOES uTex1;
    #endif
    uniform mat4 uTexTransform0;
    uniform mat4 uTexTransform1;
    // 1 for a decoded stream, 0 for the other one in one lens mode
    uniform vec2 uEnabled;
    #ifdef SUPERSAMPLE
    uniform vec2 uOutputSize;
    #endif
    in vec2 vOut;
    out vec4 outColor;

    vec3 toRgb(vec4 c) {
    #ifdef YUV_INPUT
      return clamp(uYuvToRgb * (c.xyz - uYuvOffset), 0.0, 1.0);
    #else
      return c.rgb;
    #endif
    }

    // Fraction of stream [tex] (top left origin) to its colour
    vec3 sampleTexture(float tex, vec2 frac) {
      vec4 st = vec4(frac.x, 1.0 - frac.y, 0.0, 1.0);
      if (tex < 0.5) return toRgb(texture(uTex0, (uTexTransform0 * st).xy));
      return toRgb(texture(uTex1, (uTexTransform1 * st).xy));
    }

    float enabledOf(float tex) {
      return tex < 0.5 ? uEnabled.x : uEnabled.y;
    }

    """
      .trimIndent() + "\n"

  /** The view direction of an output position: longitude -180 to 180 across, latitude -90 to 90 up. */
  private val COMMON_FUNCTIONS =
    """
    const float PI = 3.14159265358979;

    vec3 viewDirection(vec2 position) {
      float lon = (position.x * 2.0 - 1.0) * PI;
      float lat = (position.y - 0.5) * PI;
      return vec3(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon));
    }

    """
      .trimIndent() + "\n"

  /**
   * HLG or PQ to 8 bit SDR BT.709, after the blend and once per pixel, see [HdrToneMap] for the curve and its
   * reference values. Without a tone map the colour goes out as it is.
   */
  private val TONE_MAP: String
    get() {
      val m = HdrToneMap.BT2020_TO_BT709
      // Column major: the first three numbers are the first column of the row major matrix
      val columns = (0 until 9).joinToString(", ") { literal(m[(it % 3) * 3 + it / 3]) }
      val luma = HdrToneMap.LUMA_2020.joinToString(", ") { literal(it) }
      return """
        #if defined(TONE_MAP_HLG) || defined(TONE_MAP_PQ)
        const mat3 BT2020_TO_BT709 = mat3($columns);
        const vec3 LUMA_2020 = vec3($luma);
        const float KNEE = ${literal(HdrToneMap.KNEE)};

        // BT.2100: signal E' to scene light in 0..1
        float hlgInverseOetf(float e) {
          const float a = 0.17883277;
          const float b = 0.28466892;
          const float c = 0.55991073;
          return e <= 0.5 ? e * e / 3.0 : (exp((e - c) / a) + b) / 12.0;
        }

        // BT.2100: signal E' to display light, 1.0 = 10000 cd/m2
        float pqEotf(float e) {
          const float m1 = 2610.0 / 16384.0;
          const float m2 = 2523.0 / 4096.0 * 128.0;
          const float c1 = 3424.0 / 4096.0;
          const float c2 = 2413.0 / 4096.0 * 32.0;
          const float c3 = 2392.0 / 4096.0 * 32.0;
          float t = pow(clamp(e, 0.0, 1.0), 1.0 / m2);
          return pow(max(t - c1, 0.0) / (c2 - c3 * t), 1.0 / m1);
        }

        vec3 toOutput(vec3 e) {
        #ifdef TONE_MAP_HLG
          vec3 scene = vec3(hlgInverseOetf(e.r), hlgInverseOetf(e.g), hlgInverseOetf(e.b));
          // OOTF of the 1000 cd/m2 reference display (gamma 1.2), then 1.0 = reference white
          vec3 l = scene * pow(max(dot(scene, LUMA_2020), 1e-6), 0.2) *
            (${literal(HdrToneMap.HLG_PEAK_NITS)} / ${literal(HdrToneMap.REFERENCE_WHITE_NITS)});
        #else
          vec3 l = vec3(pqEotf(e.r), pqEotf(e.g), pqEotf(e.b)) *
            (${literal(HdrToneMap.PQ_PEAK_NITS)} / ${literal(HdrToneMap.REFERENCE_WHITE_NITS)});
        #endif
          float y = dot(l, LUMA_2020);
          float yt = y <= KNEE ? y : KNEE + (1.0 - KNEE) * (1.0 - exp(-(y - KNEE) / (1.0 - KNEE)));
          l *= yt / max(y, 1e-6);
          // Gamma 2.2, as Media3's SDR output
          return pow(clamp(BT2020_TO_BT709 * l, 0.0, 1.0), vec3(1.0 / 2.2));
        }
        #else
        vec3 toOutput(vec3 c) {
          return c;
        }
        #endif

        """
        .trimIndent() + "\n"
    }

  /**
   * The fisheye pair (section 4.1 of the projections design): each lens's canvas pixel, its fraction of the lens
   * square, that fraction in the lens region of its stream (kept half a texel inside, so that bilinear reads never
   * reach the other lens of a side by side frame), the blend of the two by angle off axis. Where both lenses see the
   * direction past the blend, the nearer lens alone (as build 17); where none does, black.
   */
  private val FISHEYE =
    """
    // View direction to each lens frame
    uniform mat3 uViewToLens0;
    uniform mat3 uViewToLens1;
    // fx, fy, cx - i * canvasSquare, cy: lens-local canvas pixels
    uniform vec4 uIntr0;
    uniform vec4 uIntr1;
    // k1, k2, k3, k4
    uniform vec4 uK0;
    uniform vec4 uK1;
    // k5, xi, p1, p2
    uniform vec4 uX0;
    uniform vec4 uX1;
    // Where the lens square lies in its stream: x, y, width, height, fractions, top left origin
    uniform vec4 uRegion0;
    uniform vec4 uRegion1;
    // 0.5 / decoded size of the stream of each lens
    uniform vec2 uHalfTexel0;
    uniform vec2 uHalfTexel1;
    // The stream of each lens
    uniform float uTexOf0;
    uniform float uTexOf1;
    // radius / radiusTheta (radians), equidistant only
    uniform float uEquidistantFocal0;
    uniform float uEquidistantFocal1;
    // 0 Mei, 1 equidistant, 2 Kannala-Brandt
    uniform float uModel;
    uniform float uSquare;
    // maxTheta, blendStart, blendEnd, radians
    uniform vec3 uTheta;

    // Canvas pixel (x right, y down, lens-local) that sees the direction d of the lens frame
    vec2 projectLens(vec3 d, vec4 intr, vec4 k, vec4 x, float focal, float theta) {
      if (uModel < 0.5) {
        vec2 m = d.xy / max(d.z + x.y, 1e-3);
        float r2 = dot(m, m);
        float radial = 1.0 + r2 * (k.x + r2 * (k.y + r2 * (k.z + r2 * (k.w + r2 * x.x))));
        vec2 t = vec2(2.0 * x.z * m.x * m.y + x.w * (r2 + 2.0 * m.x * m.x),
                      x.z * (r2 + 2.0 * m.y * m.y) + 2.0 * x.w * m.x * m.y);
        return intr.xy * (radial * m + t) + intr.zw;
      }
      float q = length(d.xy);
      vec2 u = q > 1e-7 ? d.xy / q : vec2(0.0);
      if (uModel < 1.5) return intr.zw + focal * theta * u;
      float t2 = theta * theta;
      float thetaD = theta * (1.0 + t2 * (k.x + t2 * (k.y + t2 * (k.z + t2 * (k.w + t2 * x.x)))));
      return intr.zw + intr.xy * thetaD * u;
    }

    // The colour a lens sees in the direction v, its blend weight in .a; seen is 1 when the lens sees v at all
    vec4 sampleLens(vec3 v, mat3 viewToLens, vec4 intr, vec4 k, vec4 x, float focal, vec4 region, vec2 halfTexel,
                    float tex, out float theta, out float seen) {
      vec3 d = normalize(viewToLens * v);
      theta = atan(length(d.xy), d.z);
      seen = 0.0;
      if (enabledOf(tex) < 0.5 || theta >= uTheta.x) return vec4(0.0);
      vec2 local = projectLens(d, intr, k, x, focal, theta) / uSquare;
      if (local.x < 0.0 || local.y < 0.0 || local.x >= 1.0 || local.y >= 1.0) return vec4(0.0);
      vec2 frac = clamp(region.xy + local * region.zw, region.xy + halfTexel, region.xy + region.zw - halfTexel);
      seen = 1.0;
      return vec4(sampleTexture(tex, frac), 1.0 - smoothstep(uTheta.y, uTheta.z, theta));
    }

    vec3 stitchFisheye(vec3 v) {
      float theta0;
      float theta1;
      float seen0;
      float seen1;
      vec4 a = sampleLens(v, uViewToLens0, uIntr0, uK0, uX0, uEquidistantFocal0, uRegion0, uHalfTexel0, uTexOf0,
                          theta0, seen0);
      vec4 b = sampleLens(v, uViewToLens1, uIntr1, uK1, uX1, uEquidistantFocal1, uRegion1, uHalfTexel1, uTexOf1,
                          theta1, seen1);
      float sum = a.a + b.a;
      if (sum > 0.0) return (a.rgb * a.a + b.rgb * b.a) / sum;
      if (seen0 > 0.5 && seen1 > 0.5) return theta0 <= theta1 ? a.rgb : b.rgb;
      if (seen0 > 0.5) return a.rgb;
      if (seen1 > 0.5) return b.rgb;
      return vec3(0.0);
    }

    """
      .trimIndent() + "\n"

  /**
   * The GoPro EAC pair (section 4.2 of the projections design): the face whose forward axis is nearest the direction
   * (ties keep the first of the table), the face column and row of the direction, and its pixel in the track: the
   * middle slot holds a whole face, the end slots a split face whose two halves share the overlap columns, blended
   * across them. Faces are unrolled uniforms: GlProgram sets no uniform arrays.
   */
  private val EAC =
    """
    uniform mat3 uViewToCamera;
    // Rows: right, down, forward of each face in the camera frame
    uniform mat3 uFace0;
    uniform mat3 uFace1;
    uniform mat3 uFace2;
    uniform mat3 uFace3;
    uniform mat3 uFace4;
    uniform mat3 uFace5;
    // Stream and slot of each face
    uniform vec2 uFaceSlot0;
    uniform vec2 uFaceSlot1;
    uniform vec2 uFaceSlot2;
    uniform vec2 uFaceSlot3;
    uniform vec2 uFaceSlot4;
    uniform vec2 uFaceSlot5;
    // Face, half, overlap, middle; right; the declared track size
    uniform vec4 uEac;
    uniform float uEacRight;
    uniform vec2 uTrackSize;

    void pickFace(mat3 face, vec2 slot, vec3 c, inout vec3 best, inout vec2 bestSlot) {
      vec3 q = face * c;
      if (q.z > best.z) {
        best = q;
        bestSlot = slot;
      }
    }

    // Pixel of a track at its declared size (pixel centres at half pixels) to its colour
    vec3 sampleTrack(float tex, vec2 xy) {
      return sampleTexture(tex, xy / uTrackSize);
    }

    vec3 stitchEac(vec3 v) {
      vec3 c = uViewToCamera * v;
      vec3 q = vec3(0.0, 0.0, -2.0);
      vec2 ts = vec2(0.0);
      pickFace(uFace0, uFaceSlot0, c, q, ts);
      pickFace(uFace1, uFaceSlot1, c, q, ts);
      pickFace(uFace2, uFaceSlot2, c, q, ts);
      pickFace(uFace3, uFaceSlot3, c, q, ts);
      pickFace(uFace4, uFaceSlot4, c, q, ts);
      pickFace(uFace5, uFaceSlot5, c, q, ts);
      if (enabledOf(ts.x) < 0.5) return vec3(0.0);
      float f = uEac.x;
      float halfW = uEac.y;
      float ovl = uEac.z;
      float mid = uEac.w;
      float col = (atan(q.x / q.z) * 4.0 / PI + 1.0) * 0.5 * f;
      float row = clamp((atan(q.y / q.z) * 4.0 / PI + 1.0) * 0.5 * f, 0.5, f - 0.5);
      if (ts.y > 0.5 && ts.y < 1.5) {
        return sampleTrack(ts.x, vec2(clamp(mid + col, mid + 0.5, mid + f - 0.5), row));
      }
      float base = ts.y < 0.5 ? 0.0 : uEacRight;
      float wb = ovl > 0.0 ? clamp((col - 0.5 - (f - halfW)) / ovl, 0.0, 1.0) : step(halfW, col);
      float xa = clamp(base + col, base + 0.5, base + halfW - 0.5);
      float xb = clamp(base + halfW + col - (f - halfW), base + halfW + 0.5, base + 2.0 * halfW - 0.5);
      return mix(sampleTrack(ts.x, vec2(xa, row)), sampleTrack(ts.x, vec2(xb, row)), wb);
    }

    """
      .trimIndent() + "\n"
}
