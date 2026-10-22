// Immuch360: the GLSL ES 3.00 passes of the Spatial 2.5D renderer on Windows
// (IMMUCH360-NOTE.md, patch 11).
//
// The bodies are those of the phones' SpatialShaders.kt
// (mobile/android/app/src/main/kotlin/app/alextran/immich/spatial/), the same
// text but for one word: the eye pass reads renderer C's intermediate texture,
// a sampler2D, where the phone reads its decoder's samplerExternalOES.
// mobile/test/desktop/video/spatial_shaders_parity_test.dart compares each body
// here with its Kotlin constant and fails when one differs, so that a later fix
// of the phones is not forgotten here; the Windows test of the app
// (spatial_shaders_windows_test.dart) compiles these strings with the ANGLE of
// the build and runs the passes on a synthetic stereo pair.
//
// How |SpatialRenderer| puts a program together: kVertex for every pass but the
// sphere eye; the fragment shader is kFragmentPrefix then the body, with kEyeIo
// between them for the flat eye (the order of SpatialShaders.fragment and
// eyeFragment). The eye of a 360 or VR180 stereo video is drawn by renderer C's
// own equirectangular pass (projection_shaders.h: kVertexSource; kFragmentHeader,
// "#define PROJECTION_KIND 0", kFragmentCommon, kFragmentEquirect) with
// kEyeSphereMain as its main, which also writes in the alpha whether the eye
// covers the direction, as the phones' equirectangular eye pass does: the
// synthesis keeps black what a VR180 eye does not cover.
//
// Orientation: every texture of these passes holds its picture with its first
// row at the top, as renderer C's intermediate texture and output do, where the
// phones keep the first row at the bottom. The passes after the eyes treat all
// rows alike (the matching, the check, the blend and the blur work along the
// rows, the synthesis moves pixels along them), so the same bodies give the same
// picture; only the eye passes place the rows: the flat eye reads its rectangle
// with a top left origin through an identity u_texMatrix, and the sphere eye
// looks up on its first row, as renderer C's view does.

#ifndef SPATIAL_SHADERS_H_
#define SPATIAL_SHADERS_H_

namespace spatial_shaders {

// The start of every fragment shader (SpatialShaders.VERSION and PRECISION)
constexpr const char* kFragmentPrefix = R"glsl(#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
)glsl";

// The inputs and output of the flat eye pass (SpatialShaders.EYE_IO_ESSL3)
constexpr const char* kEyeIo = R"glsl(in vec2 v_uv;
out vec4 fragColor;
)glsl";

// One triangle that covers the target, without vertex attributes: v_uv spans
// 0 to 1 over the viewport, 0 on its first row (SpatialShaders.VERTEX).
constexpr const char* kVertex = R"glsl(#version 300 es
out vec2 v_uv;

void main() {
  // Vertices (0, 0), (2, 0) and (0, 2) in viewport units: the triangle covers the whole viewport
  vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  v_uv = corner;
  gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}
)glsl";

// Pass 1, flat video: one eye of the frame into its eye texture
// (EYE_FLAT_BODY). u_video is renderer C's intermediate texture, u_rect the eye
// in it with a top left origin, u_texMatrix the identity; u_inset keeps the
// bilinear reads one texel away from the other eye.
constexpr const char* kEyeFlat = R"glsl(
uniform sampler2D u_video;
uniform mat4 u_texMatrix;
uniform vec4 u_rect;
uniform vec4 u_inset;

void main() {
  vec2 eyeUv = clamp(v_uv, u_inset.xy, 1.0 - u_inset.zw);
  vec2 frameUv = u_rect.xy + eyeUv * u_rect.zw;
  vec2 st = (u_texMatrix * vec4(frameUv, 0.0, 1.0)).xy;
  fragColor = vec4(texture(u_video, st).rgb, 1.0);
}
)glsl";

// A texture drawn as it is: the left eye of a video that is not stereoscopic,
// and the synthesis scaled up to an output larger than the eyes (COPY).
constexpr const char* kCopy = R"glsl(
uniform sampler2D u_texture;
in vec2 v_uv;
out vec4 fragColor;

void main() {
  fragColor = vec4(texture(u_texture, v_uv).rgb, 1.0);
}
)glsl";

// Pass 2: each eye in grey at the disparity size, four pixels in one RGBA
// texel (GRAY_PACK).
constexpr const char* kGrayPack = R"glsl(
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
)glsl";

// Pass 3: 7 x 7 block matching along the rows, sum of absolute differences,
// parabola for the sub pixel, from the left eye and from the right one
// (DISPARITY). The encoded disparity in r, its validity in g.
constexpr const char* kDisparity = R"glsl(
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
)glsl";

// Pass 3, after the matching: the left right consistency check and the
// temporal blend with the previous map of the ping pong pair (BLEND).
constexpr const char* kBlend = R"glsl(
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
)glsl";

// Pass 4: one direction of the separable 5 tap blur weighted by validity
// (BLUR).
constexpr const char* kBlur = R"glsl(
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
)glsl";

// Pass 5: the view at u_viewpoint (0 the left camera, 1 the right one) by
// backward warping, occlusion tests, holes filled from the background side
// (SYNTHESIS).
constexpr const char* kSynthesis = R"glsl(
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
  if (texture(u_left, uv).a < 0.5) {
    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }
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
)glsl";

// The disparity map instead of the synthesis, for the troubleshooting overlay:
// near bright, far dark, unreliable pixels tinted red (SHOW_DISPARITY).
constexpr const char* kShowDisparity = R"glsl(
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
)glsl";

// The main of renderer C's equirectangular pass (projection_shaders.h,
// kFragmentMain) for one eye of a 360 or VR180 stereo video: the same view, the
// same filters, and the coverage in the alpha, 0 for the directions outside
// the part of the sphere the eye covers (uCrop), as EYE_EQUIRECT_BODY of the
// phones writes it.
constexpr const char* kEyeSphereMain = R"glsl(
// The direction of the sphere seen at a position of the eye texture; its first
// row looks up
vec3 directionAt(vec2 position) {
  vec3 ray = vec3(position.x * uTanHalfFov.x, -position.y * uTanHalfFov.y, 1.0);
  return normalize(uViewToSphere * ray);
}

// 1 where the eye covers the direction d, 0 outside its part of the sphere
float coverage(vec3 d) {
  if (uCrop.z > 0.999) return 1.0;
  float lon = atan(d.x, d.z);
  float lat = asin(clamp(d.y, -1.0, 1.0));
  vec2 local = (vec2(0.5 + lon / (2.0 * PI), 0.5 - lat / PI) - uCrop.xy) / uCrop.zw;
  return (local.x < 0.0 || local.x > 1.0 || local.y < 0.0 || local.y > 1.0) ? 0.0 : 1.0;
}

void main() {
  vec3 colour;
  if (uSharp > 0.5 && uTexelsPerPixel >= 1.25) {
    // Four reads on a rotated grid inside the pixel, as kFragmentMain
    vec2 pixel = 2.0 / uOutputSize;
    colour = 0.25 * (sampleSphere(directionAt(vPosition + pixel * vec2(-0.125, -0.375))) +
                     sampleSphere(directionAt(vPosition + pixel * vec2(0.375, -0.125))) +
                     sampleSphere(directionAt(vPosition + pixel * vec2(0.125, 0.375))) +
                     sampleSphere(directionAt(vPosition + pixel * vec2(-0.375, 0.125))));
  } else {
    colour = sampleSphere(directionAt(vPosition));
  }
  outColor = vec4(colour, coverage(directionAt(vPosition)));
}
)glsl";

}  // namespace spatial_shaders

#endif  // SPATIAL_SHADERS_H_
