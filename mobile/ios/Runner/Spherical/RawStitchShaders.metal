#include <metal_stdlib>
using namespace metal;

// Shaders of the raw 360 stitcher, driven by RawStitchRenderer.swift for RawStitchCompositor.swift: each frame of a raw
// two lens recording (one or two source pictures) becomes one equirectangular frame. Output pixel (i, j) of a W x H
// frame looks at longitude ((i + 0.5) / W * 2 - 1) * pi and latitude pi / 2 - (j + 0.5) / H * pi, in the view frame
// x right, y down, z ahead. The math is the reference of docs 18-design-projections-and-parsers.md section 4 (the Dart
// stitcher and the Android shader compute the same thing), with texture coordinates from the top left corner, as
// Metal samples a pixel buffer. Every function name starts with rawStitch: the app has one default library.
//
// Sources are biplanar Y'CbCr 4:2:0 pictures: texture 2k is the luma plane of source k, texture 2k + 1 its chroma.

// Same layout as RawStitchLensUniforms in RawStitchRenderer.swift: float4 members only
struct RawStitchLens {
  float4 row0;        // xyz: row 0 of viewToLens, from the view direction to the lens frame
  float4 row1;
  float4 row2;
  float4 projection;  // fx / S, fy / S, (cx - i S) / S, cy / S: from the lens point to the fraction of the lens square
  float4 radial;      // k1, k2, k3, k4 (mei: of r^2; kannala-brandt: of theta^2)
  float4 extra;       // k5, xi (mei), p1, p2 (mei)
  float4 region;      // the lens square in its source, fractions from the top left corner: origin xy, size zw
  float4 source;      // x: source index (0 or 1), y: 1 when that source has a frame, zw: half a texel of that source
};

// Same layout as RawStitchFaceUniforms in RawStitchRenderer.swift
struct RawStitchFace {
  float4 forward;     // xyz: where the face looks, camera frame; w: its source
  float4 right;       // xyz: the right of the face; w: its slot (0 and 2 split, 1 whole)
  float4 down;        // xyz: the bottom of the face
};

// Same layout as RawStitchUniforms in RawStitchRenderer.swift
struct RawStitchUniforms {
  RawStitchLens lens[2];
  RawStitchFace faces[6];
  float4 camera0;     // xyz: rows of viewToCamera (eac)
  float4 camera1;
  float4 camera2;
  float4 settings;    // x: projection (0 mei, 1 equidistant, 2 kannala-brandt, 3 eac), y: output width, z: height
  float4 angles;      // x: largest angle off axis, y: blend start, z: blend end (radians)
  float4 presence;    // x: 1 when source 0 has a frame, y: the same for source 1
  float4 eac;         // x: face size F, y: half, z: overlap, w: middle (pixels of the declared track size)
  float4 eacTrack;    // x: right, y: declared track width, z: declared track height
  float4 range0;      // source 0: luma scale, luma offset, chroma scale, chroma offset
  float4 range1;
  float4 colorMatrix0;  // source 0: Cr to R, Cb to G, Cr to G, Cb to B
  float4 colorMatrix1;
};

struct RawStitchVertexOut {
  float4 position [[position]];
};

constexpr sampler rawStitchSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// One triangle over the whole output
vertex RawStitchVertexOut rawStitchVertex(uint vertexId [[vertex_id]]) {
  float2 corner = float2(float((vertexId << 1) & 2u), float(vertexId & 2u));
  RawStitchVertexOut out;
  out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

// The direction an output pixel shows. Metal's fragment position counts from the top left corner of the target, at
// pixel centres, and row 0 of the output pixel buffer is the top of the picture: the zenith.
static inline float3 rawStitchViewDirection(float2 pixel, float4 settings) {
  float2 uv = pixel / settings.yz;
  float longitude = (uv.x * 2.0 - 1.0) * M_PI_F;
  float latitude = M_PI_2_F - uv.y * M_PI_F;
  return float3(cos(latitude) * sin(longitude), -sin(latitude), cos(latitude) * cos(longitude));
}

// Gamma encoded RGB of a biplanar 4:2:0 picture at uv; the chroma plane holds Cb in r and Cr in g
static inline float3 rawStitchColor(texture2d<float> luma, texture2d<float> chroma, float2 uv, float4 range,
                                    float4 colorMatrix) {
  float y = luma.sample(rawStitchSampler, uv).r * range.x - range.y;
  float2 c = chroma.sample(rawStitchSampler, uv).rg * range.z - range.w;
  return saturate(float3(y + colorMatrix.x * c.y, y - colorMatrix.y * c.x - colorMatrix.z * c.y,
                         y + colorMatrix.w * c.x));
}

static inline float3 rawStitchSource(int sourceIndex, float2 uv, constant RawStitchUniforms& u,
                                     texture2d<float> luma0, texture2d<float> chroma0,
                                     texture2d<float> luma1, texture2d<float> chroma1) {
  if (sourceIndex == 0) {
    return rawStitchColor(luma0, chroma0, uv, u.range0, u.colorMatrix0);
  }
  return rawStitchColor(luma1, chroma1, uv, u.range1, u.colorMatrix1);
}

// The lens point of a unit direction d of the lens frame, theta off axis; times (fx, fy) plus (cx, cy) it is the
// canvas pixel. Mei: the unified model, radial factor 1 + k1 r^2 + ... + k5 r^10 and one tangential pair.
// Equidistant: theta along the direction. Kannala-Brandt: theta (1 + k1 theta^2 + ... + k5 theta^10) along the
// direction.
static inline float2 rawStitchLensPoint(constant RawStitchLens& lens, float3 d, float theta, int model) {
  if (model == 0) {
    float2 m = d.xy / max(d.z + lens.extra.y, 0.001);
    float r2 = dot(m, m);
    float radial = 1.0 + r2 * (lens.radial.x + r2 * (lens.radial.y + r2 * (lens.radial.z
      + r2 * (lens.radial.w + r2 * lens.extra.x))));
    float p1 = lens.extra.z;
    float p2 = lens.extra.w;
    return float2(radial * m.x + 2.0 * p1 * m.x * m.y + p2 * (r2 + 2.0 * m.x * m.x),
                  radial * m.y + p1 * (r2 + 2.0 * m.y * m.y) + 2.0 * p2 * m.x * m.y);
  }
  float planar = length(d.xy);
  float2 unitPlanar = planar > 0.000001 ? d.xy / planar : float2(0.0);
  if (model == 1) {
    return unitPlanar * theta;
  }
  float t2 = theta * theta;
  float distorted = theta * (1.0 + t2 * (lens.radial.x + t2 * (lens.radial.y + t2 * (lens.radial.z
    + t2 * (lens.radial.w + t2 * lens.extra.x)))));
  return unitPlanar * distorted;
}

// Two fisheye lenses: a lens counts where its source has a frame, the direction is less than the largest angle off its
// axis and the point lands inside its square; it is sampled clamped half a texel inside its region (so that a side by
// side frame never blends in the other lens) and weighs 1 - smoothstep(blend start, blend end, theta). The weights are
// normalised; where every weight is zero, the counted lens nearer its axis gives the pixel, and black where no lens
// counts.
fragment float4 rawStitchFisheyeFragment(RawStitchVertexOut fragmentIn [[stage_in]],
                                         constant RawStitchUniforms& u [[buffer(0)]],
                                         texture2d<float> luma0 [[texture(0)]],
                                         texture2d<float> chroma0 [[texture(1)]],
                                         texture2d<float> luma1 [[texture(2)]],
                                         texture2d<float> chroma1 [[texture(3)]]) {
  float3 viewDirection = rawStitchViewDirection(fragmentIn.position.xy, u.settings);
  int model = int(u.settings.x + 0.5);
  float3 colorSum = float3(0.0);
  float weightSum = 0.0;
  float nearestAngle = 10.0;
  float3 nearestColor = float3(0.0);
  bool counted = false;
  for (int index = 0; index < 2; index++) {
    constant RawStitchLens& lens = u.lens[index];
    if (lens.source.y < 0.5) {
      continue;
    }
    float3 d = normalize(float3(dot(lens.row0.xyz, viewDirection), dot(lens.row1.xyz, viewDirection),
                                dot(lens.row2.xyz, viewDirection)));
    float theta = acos(clamp(d.z, -1.0, 1.0));
    if (theta >= u.angles.x) {
      continue;
    }
    float2 fraction = lens.projection.xy * rawStitchLensPoint(lens, d, theta, model) + lens.projection.zw;
    if (fraction.x < 0.0 || fraction.y < 0.0 || fraction.x >= 1.0 || fraction.y >= 1.0) {
      continue;
    }
    float2 uv = clamp(lens.region.xy + fraction * lens.region.zw, lens.region.xy + lens.source.zw,
                      lens.region.xy + lens.region.zw - lens.source.zw);
    float3 color = rawStitchSource(int(lens.source.x + 0.5), uv, u, luma0, chroma0, luma1, chroma1);
    float weight = 1.0 - smoothstep(u.angles.y, u.angles.z, theta);
    colorSum += weight * color;
    weightSum += weight;
    if (theta < nearestAngle) {
      nearestAngle = theta;
      nearestColor = color;
    }
    counted = true;
  }
  if (weightSum > 0.0) {
    return float4(colorSum / weightSum, 1.0);
  }
  if (counted) {
    return float4(nearestColor, 1.0);
  }
  return float4(0.0, 0.0, 0.0, 1.0);
}

// A strip of a GoPro .360 at x, y in pixels of its declared size (pixel centres at half pixels)
static inline float3 rawStitchStrip(int sourceIndex, float x, float y, constant RawStitchUniforms& u,
                                    texture2d<float> luma0, texture2d<float> chroma0,
                                    texture2d<float> luma1, texture2d<float> chroma1) {
  float2 uv = float2(x / u.eacTrack.y, y / u.eacTrack.z);
  return rawStitchSource(sourceIndex, uv, u, luma0, chroma0, luma1, chroma1);
}

// GoPro MAX and MAX 2: two strips of three equi-angular faces of F x F, a split face, the whole middle face, another
// split face. The face is the one of the table whose forward axis is nearest the direction (the first one on a tie). A
// split face holds face columns [0, half) in its first half and [F - half, F) in its second; the columns in both (the
// overlap) blend linearly from the first half to the second.
fragment float4 rawStitchEacFragment(RawStitchVertexOut fragmentIn [[stage_in]],
                                     constant RawStitchUniforms& u [[buffer(0)]],
                                     texture2d<float> luma0 [[texture(0)]],
                                     texture2d<float> chroma0 [[texture(1)]],
                                     texture2d<float> luma1 [[texture(2)]],
                                     texture2d<float> chroma1 [[texture(3)]]) {
  float3 viewDirection = rawStitchViewDirection(fragmentIn.position.xy, u.settings);
  float3 c = float3(dot(u.camera0.xyz, viewDirection), dot(u.camera1.xyz, viewDirection),
                    dot(u.camera2.xyz, viewDirection));
  int best = 0;
  float bestDot = -2.0;
  for (int index = 0; index < 6; index++) {
    float s = dot(c, u.faces[index].forward.xyz);
    if (s > bestDot) {
      bestDot = s;
      best = index;
    }
  }
  constant RawStitchFace& face = u.faces[best];
  int sourceIndex = int(face.forward.w + 0.5);
  int slot = int(face.right.w + 0.5);
  float present = sourceIndex == 0 ? u.presence.x : u.presence.y;
  if (present < 0.5) {
    return float4(0.0, 0.0, 0.0, 1.0);
  }
  float faceSize = u.eac.x;
  float halfWidth = u.eac.y;
  float overlap = u.eac.z;
  float middle = u.eac.w;
  float rightStart = u.eacTrack.x;
  float facing = max(bestDot, 0.0001);
  float column = (atan(dot(c, face.right.xyz) / facing) * (4.0 / M_PI_F) + 1.0) * 0.5 * faceSize;
  float row = clamp((atan(dot(c, face.down.xyz) / facing) * (4.0 / M_PI_F) + 1.0) * 0.5 * faceSize, 0.5,
                    faceSize - 0.5);
  if (slot == 1) {
    float x = clamp(middle + column, middle + 0.5, middle + faceSize - 0.5);
    return float4(rawStitchStrip(sourceIndex, x, row, u, luma0, chroma0, luma1, chroma1), 1.0);
  }
  float base = slot == 0 ? 0.0f : rightStart;
  float secondWeight = overlap > 0.0 ? clamp((column - 0.5 - (faceSize - halfWidth)) / overlap, 0.0, 1.0)
                                     : step(halfWidth, column);
  float firstX = clamp(base + column, base + 0.5, base + halfWidth - 0.5);
  float secondX = clamp(base + halfWidth + column - (faceSize - halfWidth), base + halfWidth + 0.5,
                        base + 2.0 * halfWidth - 0.5);
  float3 firstColor = rawStitchStrip(sourceIndex, firstX, row, u, luma0, chroma0, luma1, chroma1);
  float3 secondColor = rawStitchStrip(sourceIndex, secondX, row, u, luma0, chroma0, luma1, chroma1);
  return float4(mix(firstColor, secondColor, secondWeight), 1.0);
}
