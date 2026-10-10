// Immuch360: the GLSL ES 3.00 passes of renderer C (IMMUCH360-NOTE.md, patch 6).
//
// One fragment program per projection, put together by |ProjectionRenderer|
// in this order: kFragmentHeader, "#define PROJECTION_KIND <n>",
// kFragmentCommon, kFragmentStreams for the two stitches only, the part of the
// projection (kFragmentEquirect, kFragmentFisheye or kFragmentEac),
// kFragmentMain. The vertex program is the same for all. The Windows test of
// the app compiles exactly these strings with the ANGLE of the build
// (mobile/test/desktop/video/plugin_shaders_windows_test.dart reads this
// file), so a source that ANGLE refuses fails there before it reaches a
// player.
//
// Frames, as everywhere in this pass:
// - The intermediate texture holds the video as mpv draws it into an FBO with
//   MPV_RENDER_PARAM_FLIP_Y left at 0: its first row is the top of the
//   picture, so a point of the frame (fractions, top left origin) is its
//   texture coordinate as it is.
// - The output is the pbuffer of |ANGLESurfaceManager|, which media_kit fills
//   the same way: its first row is the top of what Flutter shows.
// - The sphere: x right, y up, z towards the centre column of an
//   equirectangular frame (longitude 0, u = 0.5), the frame of the photo
//   sphere of the app (panorama_viewer.widget.dart, _SpherePainter). The
//   stitch functions of the phones (RawStitchShaders.kt) take y down; the
//   main function turns the direction over for them.

#ifndef PROJECTION_SHADERS_H_
#define PROJECTION_SHADERS_H_

namespace projection_shaders {

// One triangle that covers the output; vPosition is the position in
// normalised device coordinates, y = -1 on the first row of the output.
constexpr const char* kVertexSource = R"glsl(#version 300 es
out vec2 vPosition;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)) * 2.0 - 1.0;
  vPosition = p;
  gl_Position = vec4(p, 0.0, 1.0);
}
)glsl";

constexpr const char* kFragmentHeader = R"glsl(#version 300 es
)glsl";

// What every projection has: the frame, the view and the two filters.
constexpr const char* kFragmentCommon = R"glsl(
precision highp float;
precision highp int;

uniform sampler2D uSource;
// A ray of the view (x right, y up, z ahead) to the frame of the sphere
uniform mat3 uViewToSphere;
// tan of half the horizontal and of half the vertical field of view
uniform vec2 uTanHalfFov;
// 1 while the view rests (the sharper filter), 0 while it moves (bilinear)
uniform float uSharp;
// Size of the output in pixels
uniform vec2 uOutputSize;
// Texels of the frame per output pixel at the centre of the view: above
// 1.25 the view shrinks the frame and four reads per pixel replace the
// bicubic one, against the shimmer of a minification without mipmaps
uniform float uTexelsPerPixel;

in vec2 vPosition;
out vec4 outColor;

const float PI = 3.14159265358979;

// Catmull-Rom over the 4 x 4 texels around st, in nine bilinear reads
// (the weights of the two middle texels of each axis folded into one read)
vec4 catmullRom(vec2 st) {
  vec2 size = vec2(textureSize(uSource, 0));
  vec2 position = st * size;
  vec2 centre1 = floor(position - 0.5) + 0.5;
  vec2 f = position - centre1;
  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
  vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
  vec2 w3 = f * f * (-0.5 + 0.5 * f);
  vec2 w12 = w1 + w2;
  vec2 t0 = (centre1 - 1.0) / size;
  vec2 t3 = (centre1 + 2.0) / size;
  vec2 t12 = (centre1 + w2 / w12) / size;
  vec4 c = texture(uSource, vec2(t0.x, t0.y)) * w0.x * w0.y;
  c += texture(uSource, vec2(t12.x, t0.y)) * w12.x * w0.y;
  c += texture(uSource, vec2(t3.x, t0.y)) * w3.x * w0.y;
  c += texture(uSource, vec2(t0.x, t12.y)) * w0.x * w12.y;
  c += texture(uSource, vec2(t12.x, t12.y)) * w12.x * w12.y;
  c += texture(uSource, vec2(t3.x, t12.y)) * w3.x * w12.y;
  c += texture(uSource, vec2(t0.x, t3.y)) * w0.x * w3.y;
  c += texture(uSource, vec2(t12.x, t3.y)) * w12.x * w3.y;
  c += texture(uSource, vec2(t3.x, t3.y)) * w3.x * w3.y;
  return clamp(c, 0.0, 1.0);
}

// The colour at a point of the frame (fractions, top left origin)
vec3 sampleFrame(vec2 frame) {
  if (uSharp > 0.5 && uTexelsPerPixel < 1.25) {
    return catmullRom(frame).rgb;
  }
  return texture(uSource, frame).rgb;
}
)glsl";

// PROJECTION_KIND 0: an equirectangular frame, mono or one eye of a stereo
// frame, over the whole sphere or its front half (VR180).
constexpr const char* kFragmentEquirect = R"glsl(
// Where the eye shown lies in the frame: x, y, width, height, fractions, top
// left origin (StereoLayout.leftEyeRect, or the right eye's)
uniform vec4 uEye;
// The part of the sphere that eye covers, in fractions of the equirectangular
// frame of the whole sphere (u 0.5 ahead, v 0 up): (0, 0, 1, 1) for 360
// degrees, (0.25, 0, 0.5, 1) for VR180; black outside
uniform vec4 uCrop;

vec3 sampleSphere(vec3 d) {
  float lon = atan(d.x, d.z);
  float lat = asin(clamp(d.y, -1.0, 1.0));
  vec2 s = vec2(0.5 + lon / (2.0 * PI), 0.5 - lat / PI);
  vec2 local = (s - uCrop.xy) / uCrop.zw;
  if (uCrop.z > 0.999) {
    local.x = fract(local.x);
  }
  if (local.x < 0.0 || local.x > 1.0 || local.y < 0.0 || local.y > 1.0) {
    return vec3(0.0);
  }
  return sampleFrame(uEye.xy + local * uEye.zw);
}
)glsl";

// What both stitches share: the decoded streams of a raw video are side by
// side in the frame (one for a side by side file, two once lavfi-complex has
// stacked two tracks or two files with hstack), stream k in the k-th
// |uTracks| part of its width.
constexpr const char* kFragmentStreams = R"glsl(
// Number of streams side by side in the frame
uniform float uTracks;
// 1 for a stream that is decoded, 0 for the other one in one lens mode
uniform vec2 uEnabled;

// Fraction of stream tex (top left origin) to its colour
vec3 sampleTexture(float tex, vec2 frac) {
  return sampleFrame(vec2((tex + frac.x) / uTracks, frac.y));
}

float enabledOf(float tex) {
  return tex < 0.5 ? uEnabled.x : uEnabled.y;
}

// Half a texel of a stream, in fractions of it: the reads of a lens stay that
// far inside its region, so that a bilinear read never mixes in the lens next
// to it
vec2 halfTexelOfStreams() {
  return vec2(0.5 * uTracks, 0.5) / vec2(textureSize(uSource, 0));
}
)glsl";

// PROJECTION_KIND 1: a pair of fisheye lenses (Mei, equidistant,
// Kannala-Brandt), the FISHEYE part of RawStitchShaders.kt with the half
// texel computed here from the size of the intermediate texture.
constexpr const char* kFragmentFisheye = R"glsl(
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
// Where the lens square lies in its stream: x, y, width, height, fractions,
// top left origin
uniform vec4 uRegion0;
uniform vec4 uRegion1;
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

// Canvas pixel (x right, y down, lens-local) that sees the direction d of the
// lens frame
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

// The colour a lens sees in the direction v, its blend weight in .a; seen is
// 1 when the lens sees v at all
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

vec3 stitch(vec3 v) {
  vec2 halfTexel = halfTexelOfStreams();
  float theta0;
  float theta1;
  float seen0;
  float seen1;
  vec4 a = sampleLens(v, uViewToLens0, uIntr0, uK0, uX0, uEquidistantFocal0, uRegion0, halfTexel, uTexOf0,
                      theta0, seen0);
  vec4 b = sampleLens(v, uViewToLens1, uIntr1, uK1, uX1, uEquidistantFocal1, uRegion1, halfTexel, uTexOf1,
                      theta1, seen1);
  float sum = a.a + b.a;
  if (sum > 0.0) return (a.rgb * a.a + b.rgb * b.a) / sum;
  if (seen0 > 0.5 && seen1 > 0.5) return theta0 <= theta1 ? a.rgb : b.rgb;
  if (seen0 > 0.5) return a.rgb;
  if (seen1 > 0.5) return b.rgb;
  return vec3(0.0);
}
)glsl";

// PROJECTION_KIND 2: the two EAC tracks of a GoPro .360, the EAC part of
// RawStitchShaders.kt.
constexpr const char* kFragmentEac = R"glsl(
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

// Pixel of a track at its declared size (pixel centres at half pixels) to its
// colour
vec3 sampleTrack(float tex, vec2 xy) {
  return sampleTexture(tex, xy / uTrackSize);
}

vec3 stitch(vec3 v) {
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
)glsl";

constexpr const char* kFragmentMain = R"glsl(
vec3 sampleView(vec2 position) {
  // The first row of the output is the top of the view
  vec3 ray = vec3(position.x * uTanHalfFov.x, -position.y * uTanHalfFov.y, 1.0);
  vec3 d = normalize(uViewToSphere * ray);
#if PROJECTION_KIND == 0
  return sampleSphere(d);
#else
  // The stitches take y down: (cos lat sin lon, -sin lat, cos lat cos lon)
  return stitch(vec3(d.x, -d.y, d.z));
#endif
}

void main() {
  vec3 colour;
  if (uSharp > 0.5 && uTexelsPerPixel >= 1.25) {
    // Four reads on a rotated grid inside the pixel
    vec2 pixel = 2.0 / uOutputSize;
    colour = 0.25 * (sampleView(vPosition + pixel * vec2(-0.125, -0.375)) +
                     sampleView(vPosition + pixel * vec2(0.375, -0.125)) +
                     sampleView(vPosition + pixel * vec2(0.125, 0.375)) +
                     sampleView(vPosition + pixel * vec2(-0.375, 0.125)));
  } else {
    colour = sampleView(vPosition);
  }
  outColor = vec4(colour, 1.0);
}
)glsl";

}  // namespace projection_shaders

#endif  // PROJECTION_SHADERS_H_
