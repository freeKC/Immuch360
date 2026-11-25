#version 460 core

// Spatial 2.5D of a 3D photo on the computers (release 53, lot P2): the view of the scene from the viewpoint p, between
// the left eye (0) and the right one (1), drawn from both eyes of the photo and its disparity map
// (lib/desktop/spatial/stereo_disparity.dart, computed once per photo). The steps are those of the SYNTHESIS pass of the
// phones (SpatialShaders.kt): for an output pixel x, the left source is xL = x + p d(xL) and the right source
// xR = x - (1 - p) d(xR), each found by three fixed point steps; an eye whose step does not settle sees an occluded point
// and is left out; when both are, the nearest pixel along the row where one works gives the colour, the farther first,
// so that a hole is never black. Mode 1 shows the left map instead: near bright, far dark, unreliable pixels reddish.
//
// Everything is in the coordinates of one eye (0 to 1, y down, as Flutter draws); the eyes are read from the frame of
// the photo through their rectangles, kept half a texel away from the other eye. The SkSL backend of Flutter accepts
// loops with constant bounds only: the searches end with break rather than in their conditions.

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
// 0 the scene, 1 the depth map
uniform float uMode;

uniform sampler2D uFrame;
uniform sampler2D uMap;

out vec4 fragColor;

vec3 eyeColor(vec4 rect, vec2 uv) {
  vec2 inside = clamp(uv, uInset, 1.0 - uInset);
  return texture(uFrame, rect.xy + inside * rect.zw).rgb;
}

vec3 leftColor(vec2 uv) {
  return eyeColor(uLeftRect, uv);
}

vec3 rightColor(vec2 uv) {
  return eyeColor(uRightRect, uv);
}

float leftDisparity(float x, float y) {
  return uDecode.x + texture(uMap, vec2(x, y)).r * uDecode.y;
}

float rightDisparity(float x, float y) {
  return uDecode.x + texture(uMap, vec2(x, y)).g * uDecode.y;
}

// 1.0 when the source x lies on the eye, with a margin of half a texel
float inside(float x) {
  float margin = uParams.z;
  return (x >= -margin && x <= 1.0 + margin) ? 1.0 : 0.0;
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

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;

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
