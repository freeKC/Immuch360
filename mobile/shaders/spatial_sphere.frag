#version 460 core

// Spatial 2.5D of a 360 degree or VR180 3D photo on the computers (release 53, lot P3): the look around view of the sphere,
// as the 360 degree photo viewer draws it (yaw, pitch and the vertical field of view of the moment), seen from the
// viewpoint p between the left eye (0) and the right one (1). Each output pixel is turned into the direction it looks
// at, then into the point of each equirectangular eye that direction falls on; from there the steps are those of
// shaders/spatial_photo.frag (the SYNTHESIS pass of the phones), along the rows of the eyes: the eyes of a stereo
// sphere differ along their rows only (the omnidirectional stereo of 360 degree cameras and stitchers, the 3D panoramas of
// the app), so the disparity map measured once on the whole eyes holds for every direction. On the whole sphere the
// rows go round: the reads wrap at the seam instead of stopping at an edge. Mode 1 shows the left map instead (near
// bright, far dark, unreliable pixels reddish), mode 2 the left eye alone (the depth not measured yet, or not at all).
//
// Constant bound loops with break, as the SkSL backend of Flutter wants.

#include <flutter/runtime_effect.glsl>

precision highp float;

// Output width and height, in pixels
uniform vec2 uSize;
// The left and right eyes in the frame: x, y, width, height, as fractions of the frame
uniform vec4 uLeftRect;
uniform vec4 uRightRect;
// Half a texel of the frame, in eye coordinates (x, y): how far the reads stay from the edge of an eye
uniform vec2 uInset;
// The disparity of a map channel value v (0 to 1) is uDecode.x + v uDecode.y, in eye widths
uniform vec2 uDecode;
// The settled threshold and the search step (both in eye widths), the margin of an eye, the viewpoint p
uniform vec4 uParams;
// The yaw and the pitch of the view (radians, right and up positive), its focal length in output pixels, 1.0 when the
// eyes cover the whole sphere (their rows wrap)
uniform vec4 uView;
// The part of the sphere each eye covers: left, top, width, height, as fractions of the whole sphere
uniform vec4 uCrop;
// 0 the scene, 1 the depth map, 2 the left eye alone
uniform float uMode;

uniform sampler2D uFrame;
uniform sampler2D uMap;

out vec4 fragColor;

const float PI = 3.14159265358979;

bool wraps() {
  return uView.w > 0.5;
}

// x of an eye, brought back onto the eye where its rows go round
float wrapX(float x) {
  return wraps() ? fract(x) : x;
}

vec3 eyeColor(vec4 rect, vec2 uv) {
  vec2 inside = clamp(vec2(wrapX(uv.x), uv.y), uInset, 1.0 - uInset);
  return texture(uFrame, rect.xy + inside * rect.zw).rgb;
}

vec3 leftColor(vec2 uv) {
  return eyeColor(uLeftRect, uv);
}

vec3 rightColor(vec2 uv) {
  return eyeColor(uRightRect, uv);
}

float leftDisparity(float x, float y) {
  return uDecode.x + texture(uMap, vec2(wrapX(x), y)).r * uDecode.y;
}

float rightDisparity(float x, float y) {
  return uDecode.x + texture(uMap, vec2(wrapX(x), y)).g * uDecode.y;
}

// 1.0 when the source x lies on the eye, with a margin of half a texel; always on a whole sphere
float inside(float x) {
  float margin = uParams.z;
  return (wraps() || (x >= -margin && x <= 1.0 + margin)) ? 1.0 : 0.0;
}

// The left source x, the disparity used, and 1.0 when the steps settled
vec3 solveLeft(vec2 uv) {
  float p = uParams.w;
  float d = leftDisparity(uv.x, uv.y);
  for (int i = 0; i < 3; i++) {
    d = leftDisparity(uv.x + p * d, uv.y);
  }
  float x = uv.x + p * d;
  float settled = abs(leftDisparity(x, uv.y) - d) < uParams.x ? 1.0 : 0.0;
  return vec3(x, d, settled);
}

// The right source x, the disparity used, and 1.0 when the steps settled
vec3 solveRight(vec2 uv) {
  float q = 1.0 - uParams.w;
  float d = rightDisparity(uv.x, uv.y);
  for (int i = 0; i < 3; i++) {
    d = rightDisparity(uv.x - q * d, uv.y);
  }
  float x = uv.x - q * d;
  float settled = abs(rightDisparity(x, uv.y) - d) < uParams.x ? 1.0 : 0.0;
  return vec3(x, d, settled);
}

// The point of an eye (0 to 1 over the eye) the output pixel at frag looks at, and 1.0 when the eye covers it. The
// projection of the 360 degree photo viewer (panorama_viewer.widget.dart, _SpherePainter) the other way round.
vec3 eyePoint(vec2 frag) {
  vec2 c = frag - uSize * 0.5;
  vec3 ray = normalize(vec3(c.x, -c.y, uView.z));
  float cp = cos(uView.y);
  float sp = sin(uView.y);
  vec3 w = vec3(ray.x, ray.y * cp + ray.z * sp, ray.z * cp - ray.y * sp);
  float longitude = mod(atan(w.x, w.z) + uView.x + PI, 2.0 * PI) - PI;
  float latitude = asin(clamp(w.y, -1.0, 1.0));
  vec2 sphere = vec2(0.5 + longitude / (2.0 * PI), 0.5 - latitude / PI);
  vec2 eye = (sphere - uCrop.xy) / uCrop.zw;
  if (wraps()) {
    eye.x = fract(eye.x);
  }
  float covered = eye.x >= 0.0 && eye.x <= 1.0 && eye.y >= 0.0 && eye.y <= 1.0 ? 1.0 : 0.0;
  return vec3(eye, covered);
}

void main() {
  vec3 point = eyePoint(FlutterFragCoord().xy);
  if (point.z < 0.5) {
    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }
  vec2 uv = point.xy;

  if (uMode > 1.5) {
    fragColor = vec4(leftColor(uv), 1.0);
    return;
  }
  if (uMode > 0.5) {
    vec4 m = texture(uMap, uv);
    vec3 color = vec3(m.r);
    if (m.b < 0.5) {
      color *= vec3(1.0, 0.55, 0.55);
    }
    fragColor = vec4(color, 1.0);
    return;
  }

  float p = uParams.w;
  vec3 left = solveLeft(uv);
  vec3 right = solveRight(uv);
  float leftInside = inside(left.x);
  float rightInside = inside(right.x);
  float leftWeight = max(1.0 - p, 0.001) * left.z * leftInside;
  float rightWeight = max(p, 0.001) * right.z * rightInside;
  if (leftWeight + rightWeight > 0.0) {
    vec3 l = leftColor(vec2(left.x, uv.y));
    vec3 r = rightColor(vec2(right.x, uv.y));
    fragColor = vec4((leftWeight * l + rightWeight * r) / (leftWeight + rightWeight), 1.0);
    return;
  }

  // Both eyes failed: look along the row, closest first, for a pixel where one eye works
  vec3 color = vec3(0.0);
  float smallest = 1.0e9;
  bool found = false;
  for (int k = 1; k <= 4; k++) {
    for (int s = 0; s < 2; s++) {
      float side = s == 0 ? -1.0 : 1.0;
      vec2 near = vec2(uv.x + side * float(k) * uParams.y, uv.y);
      vec3 nearLeft = solveLeft(near);
      if (nearLeft.z * inside(nearLeft.x) > 0.5 && nearLeft.y < smallest) {
        smallest = nearLeft.y;
        color = leftColor(vec2(nearLeft.x, uv.y));
        found = true;
      }
      vec3 nearRight = solveRight(near);
      if (nearRight.z * inside(nearRight.x) > 0.5 && nearRight.y < smallest) {
        smallest = nearRight.y;
        color = rightColor(vec2(nearRight.x, uv.y));
        found = true;
      }
    }
    if (found) {
      break;
    }
  }
  if (!found) {
    // Last resort: the plain blend of the unsettled sources that lie on their eye, or the left eye as it is
    float wl = max(1.0 - p, 0.001) * leftInside;
    float wr = max(p, 0.001) * rightInside;
    if (wl + wr > 0.0) {
      color = (wl * leftColor(vec2(left.x, uv.y)) + wr * rightColor(vec2(right.x, uv.y))) / (wl + wr);
    } else {
      color = leftColor(uv);
    }
  }
  fragColor = vec4(color, 1.0);
}
