#version 460 core

// Stitches the frame of a raw dual fisheye camera (an Insta360 .insp photo: lens 0 in the left square, lens 1 in the
// right one) into an equirect picture, one output pixel at a time, with the same steps as dual_fisheye_math.dart
// (docs/16-dual-fisheye-spec.md, section 3): the view direction of the pixel, levelled into the body frame of the
// camera (G), turned into the frame of each lens (R_i), projected with the Mei model (V3 and V6 calibrations, five
// radial terms) or as an equidistant fisheye (V1), and the two lenses blended between 85 and 95 degrees off their axes.
//
// The two lenses are written out rather than kept in uniform arrays: Impeller and the SkSL backend do not index
// uniform arrays dynamically. Matrices and vectors go as vec4, whose layout is the same on every backend; the Dart side
// sets them by name (DualFisheyeStitcher).

#include <flutter/runtime_effect.glsl>

precision highp float;

// Output width, output height, frame width, frame height, in pixels
uniform vec4 uSizes;
// Frame pixels per canvas pixel, model (0 Mei, 1 equidistant), unused, unused
uniform vec4 uParams;
// Rows of G, from the view to the body frame (w unused)
uniform vec4 uG0;
uniform vec4 uG1;
uniform vec4 uG2;
// Rows of R_0 and R_1, from the body frame to the frame of each lens (w unused)
uniform vec4 uR00;
uniform vec4 uR01;
uniform vec4 uR02;
uniform vec4 uR10;
uniform vec4 uR11;
uniform vec4 uR12;
// Per lens, in canvas pixels: (xi, fx, fy, radius), (cx, cy, p1, p2), (k1, k2, k3, index of its square), (k4, k5 of the
// V6 strings, 0 otherwise, unused, unused)
uniform vec4 uLens0Mei;
uniform vec4 uLens0Centre;
uniform vec4 uLens0K;
uniform vec4 uLens0K45;
uniform vec4 uLens1Mei;
uniform vec4 uLens1Centre;
uniform vec4 uLens1K;
uniform vec4 uLens1K45;

uniform sampler2D uSource;

out vec4 fragColor;

const float PI = 3.14159265358979;
const float DEGREE = PI / 180.0;
// A lens is read up to 100 degrees off its axis, where the image circle of an X3 ends
const float MAX_THETA = 100.0;
const float BLEND_START = 85.0;
const float BLEND_END = 95.0;

vec3 rotate(vec4 row0, vec4 row1, vec4 row2, vec3 v) {
  return vec3(dot(row0.xyz, v), dot(row1.xyz, v), dot(row2.xyz, v));
}

// Where the unit direction d of the frame of a lens lands in the frame (xy, frame pixels), how far it is off the axis
// of the lens (z, degrees), and whether the lens sees it there (w, 1 or 0): less than MAX_THETA off axis, and inside
// the square of the lens in the frame
vec4 project(vec3 d, vec4 mei, vec4 centre, vec4 k, vec4 k45) {
  float theta = acos(clamp(d.z, -1.0, 1.0)) / DEGREE;
  if (theta >= MAX_THETA) {
    return vec4(0.0, 0.0, theta, 0.0);
  }
  vec2 canvas;
  if (uParams.y < 0.5) {
    // Mei: projected from a point xi behind the centre of the unit sphere, then radial and tangential distortion
    float depth = d.z + mei.x;
    if (depth <= 0.000001) {
      return vec4(0.0, 0.0, theta, 0.0);
    }
    vec2 m = d.xy / depth;
    float r2 = dot(m, m);
    float radial = 1.0 + r2 * (k.x + r2 * (k.y + r2 * (k.z + r2 * (k45.x + r2 * k45.y))));
    vec2 distorted = vec2(
      radial * m.x + 2.0 * centre.z * m.x * m.y + centre.w * (r2 + 2.0 * m.x * m.x),
      radial * m.y + centre.z * (r2 + 2.0 * m.y * m.y) + 2.0 * centre.w * m.x * m.y
    );
    canvas = vec2(mei.y * distorted.x, mei.z * distorted.y) + centre.xy;
  } else {
    // Equidistant: the distance to the centre grows with the angle, the radius at MAX_THETA
    float planar = length(d.xy);
    canvas = centre.xy;
    if (planar > 0.000001) {
      canvas += mei.w * theta / MAX_THETA * d.xy / planar;
    }
  }
  vec2 frame = canvas * uParams.x;
  float side = uSizes.w;
  bool inside = frame.x >= k.w * side && frame.x < min((k.w + 1.0) * side, uSizes.z) && frame.y >= 0.0 &&
    frame.y < side;
  return vec4(frame, theta, inside ? 1.0 : 0.0);
}

void main() {
  vec2 position = FlutterFragCoord().xy;
  float lon = (position.x / uSizes.x * 2.0 - 1.0) * PI;
  float lat = PI / 2.0 - position.y / uSizes.y * PI;
  vec3 view = vec3(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon));
  vec3 body = rotate(uG0, uG1, uG2, view);

  vec4 sample0 = project(rotate(uR00, uR01, uR02, body), uLens0Mei, uLens0Centre, uLens0K, uLens0K45);
  vec4 sample1 = project(rotate(uR10, uR11, uR12, body), uLens1Mei, uLens1Centre, uLens1K, uLens1K45);

  float weight0 = sample0.w * (1.0 - smoothstep(BLEND_START, BLEND_END, sample0.z));
  float weight1 = sample1.w * (1.0 - smoothstep(BLEND_START, BLEND_END, sample1.z));
  float total = weight0 + weight1;
  if (total <= 0.0) {
    if (sample0.w + sample1.w <= 0.0) {
      // Neither lens sees this direction
      fragColor = vec4(0.0, 0.0, 0.0, 1.0);
      return;
    }
    // Both past the blend, or the other lens off its square: the lens closer to its axis alone
    weight0 = sample0.w > 0.0 && (sample1.w <= 0.0 || sample0.z <= sample1.z) ? 1.0 : 0.0;
    weight1 = 1.0 - weight0;
    total = 1.0;
  }

  vec2 frameSize = uSizes.zw;
  vec4 colour = vec4(0.0);
  if (weight0 > 0.0) {
    colour += weight0 * texture(uSource, sample0.xy / frameSize);
  }
  if (weight1 > 0.0) {
    colour += weight1 * texture(uSource, sample1.xy / frameSize);
  }
  fragColor = vec4(colour.rgb / total, 1.0);
}
