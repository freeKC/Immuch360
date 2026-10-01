package app.alextran.immich.spatial

/**
 * GLSL ES 3.00 sources of the Spatial 2.5D renderer, with GLSL ES 1.00 variants of the eye passes for the drivers
 * that only sample the video in GLSL ES 1.00. Every pass draws one triangle that covers its target.
 *
 * Conventions shared by all the passes:
 * - texture coordinates start at the bottom left corner, like GL, so every texture keeps the orientation of the
 *   video frame;
 * - the eye textures hold one eye each, at the output size, and every disparity texture covers a whole eye;
 * - a disparity d is xLeft - xRight (positive for near objects) and is stored encoded as d * scale + 0.5, so that
 *   RGBA8 and RGBA16F targets work alike;
 * - a disparity map holds the left map in r (disparity) and g (validity), the right map in b and a.
 */
internal object SpatialShaders {
  private const val VERSION = "#version 300 es\n"
  private const val EXTERNAL = "#extension GL_OES_EGL_image_external_essl3 : require\n"
  private const val PRECISION = "precision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"

  /**
   * GLSL ES 1.00 header of the eye passes, for the drivers that only expose GL_OES_EGL_image_external. The macros
   * let the ES 3.00 bodies compile unchanged: texture() becomes texture2D() and fragColor becomes gl_FragColor.
   */
  private const val EYE_HEADER_ESSL1 = "#version 100\n" +
    "#extension GL_OES_EGL_image_external : require\n" +
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n" +
    "#define texture texture2D\n" +
    "#define fragColor gl_FragColor\n" +
    "varying vec2 v_uv;\n"

  /** Inputs and outputs of the GLSL ES 3.00 eye passes, declared by the header in the GLSL ES 1.00 variants */
  private const val EYE_IO_ESSL3 = "in vec2 v_uv;\nout vec4 fragColor;\n"

  /** Fragment shader source: version, extension when [external], precision, then [body] */
  private fun fragment(body: String, external: Boolean = false): String =
    VERSION + (if (external) EXTERNAL else "") + PRECISION + body.trimIndent()

  /** Eye pass source: the GLSL ES 3.00 shader when [essl3], otherwise its GLSL ES 1.00 variant */
  private fun eyeFragment(body: String, essl3: Boolean): String =
    if (essl3) fragment(EYE_IO_ESSL3 + body.trimIndent(), external = true) else EYE_HEADER_ESSL1 + body.trimIndent()

  /** One triangle covering the viewport, without vertex attributes. v_uv spans [0, 1] over the viewport. */
  val VERTEX: String = VERSION + """
    out vec2 v_uv;

    void main() {
      // Vertices (0, 0), (2, 0) and (0, 2) in viewport units: the triangle covers the whole viewport
      vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
      v_uv = corner;
      gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    }
  """.trimIndent()

  /**
   * GLSL ES 1.00 vertex shader of the eye pass fallbacks: ES does not link stages of different versions, and
   * gl_VertexID does not exist in GLSL ES 1.00, so the corners come from the attribute at location 0.
   */
  val VERTEX_ESSL1: String = """
    #version 100
    attribute vec2 a_corner;
    varying vec2 v_uv;

    void main() {
      v_uv = a_corner;
      gl_Position = vec4(a_corner * 2.0 - 1.0, 0.0, 1.0);
    }
  """.trimIndent()

  /** Attribute names of [VERTEX_ESSL1], in location order */
  val VERTEX_ESSL1_ATTRIBUTES = arrayOf("a_corner")

  /**
   * Pass 1, flat video: copies one eye of the video frame. u_rect is the eye inside the frame (offset, size).
   * u_inset moves the sides of the eye that touch the other eye (left, bottom, right, top, in eye units) inwards,
   * so that bilinear filtering of an upscaled eye never reads the other eye across the seam.
   */
  private val EYE_FLAT_BODY = """
    uniform samplerExternalOES u_video;
    uniform mat4 u_texMatrix;
    uniform vec4 u_rect;
    uniform vec4 u_inset;

    void main() {
      vec2 eyeUv = clamp(v_uv, u_inset.xy, 1.0 - u_inset.zw);
      vec2 frameUv = u_rect.xy + eyeUv * u_rect.zw;
      vec2 st = (u_texMatrix * vec4(frameUv, 0.0, 1.0)).xy;
      fragColor = vec4(texture(u_video, st).rgb, 1.0);
    }
    """

  /** [EYE_FLAT_BODY] in GLSL ES 3.00 when [essl3], otherwise in GLSL ES 1.00 (with [VERTEX_ESSL1]) */
  fun eyeFlat(essl3: Boolean): String = eyeFragment(EYE_FLAT_BODY, essl3)

  /**
   * Pass 1, 360 video: renders the viewport of one eye from its equirectangular image. u_rotation holds the right,
   * up and forward directions of the camera as columns, u_tanHalfFov the tangents of the half fields of view.
   * u_longitudeSpan is 2 pi for a full 360 image, pi for a 180 image; directions outside the image are black.
   */
  private val EYE_EQUIRECT_BODY = """
    uniform samplerExternalOES u_video;
    uniform mat4 u_texMatrix;
    uniform vec4 u_rect;
    uniform mat3 u_rotation;
    uniform vec2 u_tanHalfFov;
    uniform float u_longitudeSpan;

    const float PI = 3.14159265;

    void main() {
      vec2 ndc = v_uv * 2.0 - 1.0;
      vec3 dir = normalize(u_rotation * vec3(ndc * u_tanHalfFov, 1.0));
      // Longitude 0 looks along -z, positive to the right; latitude positive upwards
      float longitude = atan(dir.x, -dir.z);
      float latitude = asin(clamp(dir.y, -1.0, 1.0));
      float u = 0.5 + longitude / u_longitudeSpan;
      if (u_longitudeSpan > 4.0) u = fract(u);
      if (u < 0.0 || u > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
      }
      // Stay half a texel away from the edges so that filtering never reads the other eye
      vec2 eq = vec2(clamp(u, 0.0005, 0.9995), clamp(0.5 + latitude / PI, 0.0005, 0.9995));
      vec2 frameUv = u_rect.xy + eq * u_rect.zw;
      vec2 st = (u_texMatrix * vec4(frameUv, 0.0, 1.0)).xy;
      fragColor = vec4(texture(u_video, st).rgb, 1.0);
    }
    """

  /** [EYE_EQUIRECT_BODY] in GLSL ES 3.00 when [essl3], otherwise in GLSL ES 1.00 (with [VERTEX_ESSL1]) */
  fun eyeEquirect(essl3: Boolean): String = eyeFragment(EYE_EQUIRECT_BODY, essl3)

  /** Draws a texture as is: the left eye fallback, and the flat result of videos that are not stereoscopic */
  val COPY: String = fragment(
    """
    uniform sampler2D u_texture;
    in vec2 v_uv;
    out vec4 fragColor;

    void main() {
      fragColor = vec4(texture(u_texture, v_uv).rgb, 1.0);
    }
    """,
  )

  /**
   * Pass 2: downsamples one eye to grayscale at the disparity size. Each output pixel x packs the gray values of
   * the pixels x, x + 1, x + 2 and x + 3, so that the block matching reads four pixels per fetch. u_texel is one
   * disparity pixel in texture coordinates.
   */
  val GRAY_PACK: String = fragment(
    """
    uniform sampler2D u_eye;
    uniform vec2 u_texel;
    out vec4 fragColor;

    float luma(vec2 uv) {
      return dot(texture(u_eye, uv).rgb, vec3(0.299, 0.587, 0.114));
    }

    // Average of four bilinear taps spread over the disparity pixel whose bottom left corner is origin
    float cell(vec2 origin) {
      return 0.25 * (
        luma((origin + vec2(0.25, 0.25)) * u_texel) +
        luma((origin + vec2(0.75, 0.25)) * u_texel) +
        luma((origin + vec2(0.25, 0.75)) * u_texel) +
        luma((origin + vec2(0.75, 0.75)) * u_texel)
      );
    }

    void main() {
      vec2 origin = floor(gl_FragCoord.xy);
      fragColor = vec4(
        cell(origin),
        cell(origin + vec2(1.0, 0.0)),
        cell(origin + vec2(2.0, 0.0)),
        cell(origin + vec2(3.0, 0.0))
      );
    }
    """,
  )

  /**
   * Pass 3: horizontal block matching. For each pixel of the reference eye, finds the shift of the other eye with
   * the smallest sum of absolute differences over a 7x7 window, refines it with a parabola, and marks flat areas
   * (no texture to match) and windows that leave the image as unreliable.
   * u_direction is 1 when the reference is the left eye (the other pixel is x - d), -1 for the right eye (x + d).
   * Output: r = encoded disparity, g = validity (0 or 1).
   */
  val DISPARITY: String = fragment(
    """
    uniform sampler2D u_reference;
    uniform sampler2D u_other;
    uniform int u_searchRange;
    uniform int u_direction;
    uniform float u_encode;
    out vec4 fragColor;

    const vec4 ONE = vec4(1.0);
    // The second fetch of a row covers x + 1 to x + 4: the window stops at x + 3
    const vec4 FIRST_THREE = vec4(1.0, 1.0, 1.0, 0.0);
    const float NO_COST = 1.0e9;
    // Mean absolute deviation under which a window is too flat to match (gray values in [0, 1])
    const float MIN_CONTRAST = 0.008;

    void main() {
      ivec2 size = textureSize(u_reference, 0);
      ivec2 p = ivec2(gl_FragCoord.xy);

      // The reference window stays in registers: 7 rows of 2 packed fetches
      int rows[7];
      vec4 reference[14];
      float mean = 0.0;
      for (int r = 0; r < 7; r++) {
        rows[r] = clamp(p.y + r - 3, 0, size.y - 1);
        reference[2 * r] = texelFetch(u_reference, ivec2(clamp(p.x - 3, 0, size.x - 1), rows[r]), 0);
        reference[2 * r + 1] =
          texelFetch(u_reference, ivec2(clamp(p.x + 1, 0, size.x - 1), rows[r]), 0) * FIRST_THREE;
        mean += dot(reference[2 * r], ONE) + dot(reference[2 * r + 1], ONE);
      }
      mean /= 49.0;
      float contrast = 0.0;
      for (int r = 0; r < 7; r++) {
        contrast += dot(abs(reference[2 * r] - mean), ONE) + dot(abs(reference[2 * r + 1] - mean), FIRST_THREE);
      }
      contrast /= 49.0;

      // Scan every shift and keep the best one with the costs of its two neighbours for the sub pixel step
      float best = NO_COST;
      int bestShift = 0;
      float before = NO_COST;
      float after = NO_COST;
      float previous = NO_COST;
      bool takeNext = false;
      for (int d = -u_searchRange; d <= u_searchRange; d++) {
        int x = p.x - u_direction * d;
        float cost = NO_COST;
        if (x - 3 >= 0 && x + 3 < size.x) {
          cost = 0.0;
          for (int r = 0; r < 7; r++) {
            vec4 a = texelFetch(u_other, ivec2(x - 3, rows[r]), 0);
            vec4 b = texelFetch(u_other, ivec2(x + 1, rows[r]), 0);
            cost += dot(abs(reference[2 * r] - a), ONE) + dot(abs(reference[2 * r + 1] - b), FIRST_THREE);
          }
        }
        if (takeNext) {
          after = cost;
          takeNext = false;
        }
        if (cost < best) {
          best = cost;
          bestShift = d;
          before = previous;
          after = NO_COST;
          takeNext = true;
        }
        previous = cost;
      }

      // Parabola through the best cost and its two neighbours
      float subPixel = 0.0;
      if (before < NO_COST && after < NO_COST) {
        float curvature = before - 2.0 * best + after;
        if (curvature > 1.0e-5) subPixel = clamp(0.5 * (before - after) / curvature, -0.5, 0.5);
      }
      float disparity = float(bestShift) + subPixel;

      bool inside = p.x >= 3 && p.x + 3 < size.x;
      float valid = (best < NO_COST && contrast > MIN_CONTRAST && inside) ? 1.0 : 0.0;
      fragColor = vec4(clamp(disparity * u_encode + 0.5, 0.0, 1.0), valid, 0.0, 1.0);
    }
    """,
  )

  /**
   * Pass 3, after the matching: left to right consistency check (when u_check is 1) and temporal blend with the
   * previous map. A left pixel is kept when the right pixel it matches points back to it within u_tolerance
   * disparity pixels, and the other way round for the right map. Without the check, the right map copies the left
   * one. A reliable new value replaces mix(old, new, u_newWeight); an unreliable one keeps the old value.
   */
  val BLEND: String = fragment(
    """
    uniform sampler2D u_rawLeft;
    uniform sampler2D u_rawRight;
    uniform sampler2D u_previous;
    uniform int u_check;
    uniform float u_newWeight;
    uniform float u_encode;
    uniform float u_tolerance;
    out vec4 fragColor;

    float decode(float encoded) {
      return (encoded - 0.5) / u_encode;
    }

    vec2 blend(float oldValue, float oldValidity, float newValue, float newValidity) {
      float value = oldValue;
      if (newValidity > 0.5) value = oldValidity > 0.05 ? mix(oldValue, newValue, u_newWeight) : newValue;
      return vec2(value, mix(oldValidity, newValidity, u_newWeight));
    }

    void main() {
      ivec2 p = ivec2(gl_FragCoord.xy);
      int lastX = textureSize(u_rawLeft, 0).x - 1;
      vec4 left = texelFetch(u_rawLeft, p, 0);
      vec4 right = left;
      float leftValid = left.g;
      float rightValid = left.g;
      if (u_check == 1) {
        right = texelFetch(u_rawRight, p, 0);
        rightValid = right.g;
        float leftDisparity = decode(left.r);
        float rightDisparity = decode(right.r);
        // The right pixel matched by this left pixel, and its own disparity
        int xRight = clamp(int(floor(float(p.x) - leftDisparity + 0.5)), 0, lastX);
        vec4 back = texelFetch(u_rawRight, ivec2(xRight, p.y), 0);
        if (back.g < 0.5 || abs(decode(back.r) - leftDisparity) > u_tolerance) leftValid = 0.0;
        // The left pixel matched by this right pixel
        int xLeft = clamp(int(floor(float(p.x) + rightDisparity + 0.5)), 0, lastX);
        vec4 forth = texelFetch(u_rawLeft, ivec2(xLeft, p.y), 0);
        if (forth.g < 0.5 || abs(decode(forth.r) - rightDisparity) > u_tolerance) rightValid = 0.0;
      }
      vec4 previous = texelFetch(u_previous, p, 0);
      vec2 leftMap = blend(previous.r, previous.g, left.r, leftValid);
      vec2 rightMap = blend(previous.b, previous.a, right.r, rightValid);
      fragColor = vec4(leftMap, rightMap);
    }
    """,
  )

  /**
   * Pass 4: one direction of a separable 5 tap blur of a disparity map (u_direction is (1, 0) or (0, 1)). Each
   * disparity is weighted by its validity, so unreliable pixels take the values of their reliable neighbours.
   */
  val BLUR: String = fragment(
    """
    uniform sampler2D u_map;
    uniform ivec2 u_direction;
    out vec4 fragColor;

    void main() {
      ivec2 p = ivec2(gl_FragCoord.xy);
      ivec2 last = textureSize(u_map, 0) - 1;
      float kernel[5] = float[5](1.0, 4.0, 6.0, 4.0, 1.0);
      float leftSum = 0.0;
      float leftWeight = 0.0;
      float leftValidity = 0.0;
      float rightSum = 0.0;
      float rightWeight = 0.0;
      float rightValidity = 0.0;
      for (int i = 0; i < 5; i++) {
        vec4 s = texelFetch(u_map, clamp(p + u_direction * (i - 2), ivec2(0), last), 0);
        float k = kernel[i];
        float wl = k * (s.g + 0.01);
        leftSum += wl * s.r;
        leftWeight += wl;
        leftValidity += k * s.g;
        float wr = k * (s.a + 0.01);
        rightSum += wr * s.b;
        rightWeight += wr;
        rightValidity += k * s.a;
      }
      fragColor = vec4(leftSum / leftWeight, leftValidity / 16.0, rightSum / rightWeight, rightValidity / 16.0);
    }
    """,
  )

  /**
   * Pass 5: synthesis of the view at u_viewpoint (0 = left camera, 1 = right camera) by backward warping.
   * For an output pixel x, the left source is xL = x + p * d(xL), found by iterating from d(x); the right source is
   * xR = x - (1 - p) * d(xR) with the right map, or xL - d without it (u_hasRightMap is 0). An eye whose iteration
   * does not settle (the disparity at the source differs from the one used by more than u_threshold) sees an
   * occluded point and is left out. A source outside the eye texture (beyond half a texel) is left out too: the
   * clamped border column it would read shows another part of the scene. When both eyes fail, the nearest neighbour
   * along the row where one eye works gives the colour, preferring the background, so a hole is never black.
   * Disparities decode to texture units with (encoded - 0.5) * u_decode.
   */
  val SYNTHESIS: String = fragment(
    """
    uniform sampler2D u_left;
    uniform sampler2D u_right;
    uniform sampler2D u_map;
    uniform float u_viewpoint;
    uniform float u_decode;
    uniform float u_threshold;
    uniform float u_searchStep;
    uniform int u_hasRightMap;
    in vec2 v_uv;
    out vec4 fragColor;

    float leftDisparity(float x, float y) {
      return (texture(u_map, vec2(x, y)).r - 0.5) * u_decode;
    }

    float rightDisparity(float x, float y) {
      return (texture(u_map, vec2(x, y)).b - 0.5) * u_decode;
    }

    // 1.0 when the source x lies on the eye texture, with a margin of half an eye texel
    float inside(float x) {
      float margin = 0.5 / float(textureSize(u_left, 0).x);
      return (x >= -margin && x <= 1.0 + margin) ? 1.0 : 0.0;
    }

    // Returns the left source x, the disparity used, and 1.0 when the iteration settled
    vec3 solveLeft(vec2 uv) {
      float p = u_viewpoint;
      float d = leftDisparity(uv.x, uv.y);
      for (int i = 0; i < 3; i++) d = leftDisparity(uv.x + p * d, uv.y);
      float x = uv.x + p * d;
      float settled = abs(leftDisparity(x, uv.y) - d) < u_threshold ? 1.0 : 0.0;
      return vec3(x, d, settled);
    }

    // Returns the right source x, the disparity used, and 1.0 when the iteration settled
    vec3 solveRight(vec2 uv, vec3 left) {
      if (u_hasRightMap == 0) return vec3(left.x - left.y, left.y, left.z);
      float q = 1.0 - u_viewpoint;
      float d = rightDisparity(uv.x, uv.y);
      for (int i = 0; i < 3; i++) d = rightDisparity(uv.x - q * d, uv.y);
      float x = uv.x - q * d;
      float settled = abs(rightDisparity(x, uv.y) - d) < u_threshold ? 1.0 : 0.0;
      return vec3(x, d, settled);
    }

    void main() {
      vec2 uv = v_uv;
      float p = u_viewpoint;
      vec3 left = solveLeft(uv);
      vec3 right = solveRight(uv, left);
      float leftInside = inside(left.x);
      float rightInside = inside(right.x);
      float leftWeight = max(1.0 - p, 0.001) * left.z * leftInside;
      float rightWeight = max(p, 0.001) * right.z * rightInside;
      if (leftWeight + rightWeight > 0.0) {
        vec3 l = texture(u_left, vec2(left.x, uv.y)).rgb;
        vec3 r = texture(u_right, vec2(right.x, uv.y)).rgb;
        fragColor = vec4((leftWeight * l + rightWeight * r) / (leftWeight + rightWeight), 1.0);
        return;
      }

      // Both eyes failed: look along the row, closest first, for a pixel where one eye works
      vec3 color = vec3(0.0);
      float smallest = 1.0e9;
      bool found = false;
      for (int k = 1; k <= 4 && !found; k++) {
        for (int side = -1; side <= 1; side += 2) {
          vec2 near = vec2(uv.x + float(side * k) * u_searchStep, uv.y);
          vec3 nearLeft = solveLeft(near);
          if (nearLeft.z * inside(nearLeft.x) > 0.5 && nearLeft.y < smallest) {
            smallest = nearLeft.y;
            color = texture(u_left, vec2(nearLeft.x, uv.y)).rgb;
            found = true;
          }
          vec3 nearRight = solveRight(near, nearLeft);
          if (nearRight.z * inside(nearRight.x) > 0.5 && nearRight.y < smallest) {
            smallest = nearRight.y;
            color = texture(u_right, vec2(nearRight.x, uv.y)).rgb;
            found = true;
          }
        }
      }
      if (!found) {
        // Last resort: the plain blend of the unsettled sources that lie on their eye, or the left eye as is
        float wl = max(1.0 - p, 0.001) * leftInside;
        float wr = max(p, 0.001) * rightInside;
        if (wl + wr > 0.0) {
          vec3 l = texture(u_left, vec2(left.x, uv.y)).rgb;
          vec3 r = texture(u_right, vec2(right.x, uv.y)).rgb;
          color = (wl * l + wr * r) / (wl + wr);
        } else {
          color = texture(u_left, uv).rgb;
        }
      }
      fragColor = vec4(color, 1.0);
    }
    """,
  )

  /**
   * Debug view of the left disparity map: near objects bright, far ones dark, unreliable pixels tinted red.
   * u_gain stretches the search range to the full gray scale.
   */
  val SHOW_DISPARITY: String = fragment(
    """
    uniform sampler2D u_map;
    uniform float u_gain;
    in vec2 v_uv;
    out vec4 fragColor;

    void main() {
      vec4 m = texture(u_map, v_uv);
      float gray = clamp(0.5 + (m.r - 0.5) * u_gain, 0.0, 1.0);
      vec3 color = vec3(gray);
      if (m.g < 0.5) color *= vec3(1.0, 0.55, 0.55);
      fragColor = vec4(color, 1.0);
    }
    """,
  )
}
