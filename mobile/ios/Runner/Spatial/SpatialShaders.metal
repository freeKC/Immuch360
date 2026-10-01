#include <metal_stdlib>
using namespace metal;

// Shaders of the Spatial 2.5D video player, driven by SpatialRenderer.swift.
//
// Each frame of a stereoscopic video holds two eyes. A small disparity map is computed on the GPU from the two eyes
// (grayscale downsample, block matching, consistency check, edge aware blur, temporal blend), then the picture seen
// from an in between viewpoint is synthesised by warping both eyes with that map.
//
// Disparity convention: d(x) = xLeft - xRight, positive for near objects, stored as a fraction of the map width
// (resolution independent). The main map is in left image coordinates; the medium and high qualities also keep a
// map in right image coordinates, which tells where the right eye sees what the left eye cannot.
//
// Disparity textures are rg16Float: r is the disparity, g its validity (0 unreliable, 1 reliable).

// Block matching: a 7x7 window, a search of 24 pixels of the map on both sides, 8x8 pixels per threadgroup
#define SPATIAL_RADIUS 3
#define SPATIAL_WINDOW (2 * SPATIAL_RADIUS + 1)
#define SPATIAL_MAX_SEARCH 24
#define SPATIAL_TILE 8
#define SPATIAL_TILE_SIZE (SPATIAL_TILE + 2 * SPATIAL_RADIUS)
#define SPATIAL_SEARCH_SIZE (SPATIAL_TILE_SIZE + 2 * SPATIAL_MAX_SEARCH)

// Same layout as SpatialViewportUniforms in SpatialRenderer.swift
struct SpatialViewportUniforms {
  float4x4 rotation;  // camera space to world, the camera looks towards -z with +y up
  float4 rect;        // the eye in the frame, in texture coordinates: origin xy, size zw
  float4 lens;        // x: tangent of half the horizontal field of view, y: of half the vertical one
  float4 sphere;      // x: longitude span of the eye, in radians: 2 pi for a full sphere, pi for a half one (VR180)
};

// Same layout as SpatialSynthesisUniforms in SpatialRenderer.swift
struct SpatialSynthesisUniforms {
  float4 leftRect;   // the left eye in its texture: origin xy, size zw
  float4 rightRect;  // the right eye in its texture
  float4 view;       // x: viewpoint (0 left eye, 1 right eye), y: width of a map texel, z: 1 when a right map exists,
                     // w: convergence threshold of the warp, in map width fractions
  float4 extra;      // x: search range in map width fractions, to scale the disparity view
};

struct SpatialQuadOut {
  float4 position [[position]];
  float2 uv;  // 0 to 1 across the viewport, origin at the top left
};

constexpr sampler spatialLinear(coord::normalized, address::clamp_to_edge, filter::linear);

// Binomial weights of the 5 tap blur
constant float spatialBlurWeights[5] = {1.0, 4.0, 6.0, 4.0, 1.0};

// Samples an eye at [uv] (0 to 1 across the eye), clamped half a texel inside its rectangle so that the bilinear
// filter never reaches the other eye
static inline half4 spatialSampleEye(texture2d<half> eye, float4 rect, float2 uv) {
  float2 inset = 0.5 / float2(float(eye.get_width()), float(eye.get_height()));
  float2 position = rect.xy + saturate(uv) * rect.zw;
  position = clamp(position, rect.xy + inset, rect.xy + rect.zw - inset);
  return eye.sample(spatialLinear, position);
}

static inline float2 spatialMap(texture2d<float> map, float2 uv) {
  return map.sample(spatialLinear, uv).rg;
}

// MARK: - Drawing

// One triangle that covers the whole viewport
vertex SpatialQuadOut spatialFullscreenVertex(uint vertexId [[vertex_id]]) {
  float2 corner = float2(float((vertexId << 1) & 2u), float(vertexId & 2u));
  SpatialQuadOut out;
  out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
  out.uv = float2(corner.x, 1.0 - corner.y);
  return out;
}

// One eye as it is: the fallback when the stereo path is not available, and layouts that are not stereoscopic
fragment half4 spatialPassthroughFragment(SpatialQuadOut in [[stage_in]],
                                          texture2d<half> frame [[texture(0)]],
                                          constant float4 &rect [[buffer(0)]]) {
  return half4(spatialSampleEye(frame, rect, in.uv).rgb, 1.0h);
}

// The view of a 360 degree eye through a pinhole camera: screen pixel, then direction, then equirectangular
// coordinates. Longitude 0 is the middle of the eye, growing to the right; the top row is the zenith. The eye of a
// half sphere (VR180) spans the longitudes from -pi/2 to pi/2 only: it does not wrap, and behind it is black.
fragment half4 spatialViewportFragment(SpatialQuadOut in [[stage_in]],
                                       texture2d<half> frame [[texture(0)]],
                                       constant SpatialViewportUniforms &uniforms [[buffer(0)]]) {
  float2 ndc = in.uv * 2.0 - 1.0;
  float3 ray = normalize(float3(ndc.x * uniforms.lens.x, -ndc.y * uniforms.lens.y, -1.0));
  float3 direction = (uniforms.rotation * float4(ray, 0.0)).xyz;
  float longitude = atan2(direction.x, -direction.z);
  float latitude = asin(clamp(direction.y, -1.0, 1.0));
  float longitudeSpan = max(uniforms.sphere.x, 0.01);
  float u = 0.5 + longitude / longitudeSpan;
  if (longitudeSpan > 1.5 * M_PI_F) {
    // A full sphere wraps around behind the viewer
    u = fract(u);
  } else if (u < 0.0 || u > 1.0) {
    return half4(0.0h, 0.0h, 0.0h, 1.0h);
  }
  float2 equirect = float2(u, 0.5 - latitude / M_PI_F);
  return half4(spatialSampleEye(frame, uniforms.rect, equirect).rgb, 1.0h);
}

// The in between view. For an output pixel xV at viewpoint p, the left eye pixel is xL = xV + p * d, d being the
// disparity at xL itself: a fixed point, found by iterating from the disparity at xV. The right eye pixel is
// xR = xV - (1 - p) * d. Both are blended with weights 1 - p and p. Where the warp of one eye does not converge (the
// disparity found at its source disagrees with the one used), that eye sees something hidden from the other: the
// other eye is used alone. Where both fail, the nearest reliable disparity along the row (the farther one when there
// are two) warps both eyes, which fills the gap with background. No pixel is ever left black.
fragment half4 spatialSynthesisFragment(SpatialQuadOut in [[stage_in]],
                                        texture2d<half> leftEye [[texture(0)]],
                                        texture2d<half> rightEye [[texture(1)]],
                                        texture2d<float> leftMap [[texture(2)]],
                                        texture2d<float> rightMap [[texture(3)]],
                                        constant SpatialSynthesisUniforms &uniforms [[buffer(0)]]) {
  float p = uniforms.view.x;
  float texel = uniforms.view.y;
  bool hasRightMap = uniforms.view.z > 0.5;
  float threshold = uniforms.view.w;
  float2 uv = in.uv;

  // Left eye, map in left coordinates
  float leftD = spatialMap(leftMap, uv).x;
  for (int i = 0; i < 3; i++) {
    leftD = spatialMap(leftMap, float2(uv.x + p * leftD, uv.y)).x;
  }
  float2 atLeft = spatialMap(leftMap, float2(uv.x + p * leftD, uv.y));
  bool leftOk = abs(atLeft.x - leftD) < threshold && atLeft.y >= 0.5;

  // Right eye, map in right coordinates when there is one (xL = xR + d there), else the same match as the left eye
  float rightD = leftD;
  bool rightOk = leftOk;
  if (hasRightMap) {
    rightD = spatialMap(rightMap, uv).x;
    for (int i = 0; i < 3; i++) {
      rightD = spatialMap(rightMap, float2(uv.x - (1.0 - p) * rightD, uv.y)).x;
    }
    float2 atRight = spatialMap(rightMap, float2(uv.x - (1.0 - p) * rightD, uv.y));
    rightOk = abs(atRight.x - rightD) < threshold && atRight.y >= 0.5;
  }

  float2 leftUv = float2(uv.x + p * leftD, uv.y);
  float2 rightUv = float2(uv.x - (1.0 - p) * rightD, uv.y);
  float leftWeight = 1.0 - p;
  float rightWeight = p;
  if (leftOk && !rightOk) {
    leftWeight = 1.0;
    rightWeight = 0.0;
  } else if (!leftOk && rightOk) {
    leftWeight = 0.0;
    rightWeight = 1.0;
  } else if (!leftOk && !rightOk) {
    float fill = 0.0;
    bool found = false;
    for (int k = 1; k <= 6 && !found; k++) {
      float offset = float(k) * 2.0 * texel;
      float2 before = spatialMap(leftMap, float2(uv.x - offset, uv.y));
      float2 after = spatialMap(leftMap, float2(uv.x + offset, uv.y));
      if (before.y >= 0.5) {
        fill = before.x;
        found = true;
      }
      if (after.y >= 0.5) {
        fill = found ? min(fill, after.x) : after.x;
        found = true;
      }
    }
    if (found) {
      leftUv = float2(uv.x + p * fill, uv.y);
      rightUv = float2(uv.x - (1.0 - p) * fill, uv.y);
    }
  }

  half3 color = half3(0.0h);
  if (leftWeight > 0.0) {
    color += half(leftWeight) * spatialSampleEye(leftEye, uniforms.leftRect, leftUv).rgb;
  }
  if (rightWeight > 0.0) {
    color += half(rightWeight) * spatialSampleEye(rightEye, uniforms.rightRect, rightUv).rgb;
  }
  return half4(color, 1.0h);
}

// Debug view of the left map: mid gray for no disparity, brighter for near, darker for far, red tint where
// unreliable
fragment half4 spatialDisparityFragment(SpatialQuadOut in [[stage_in]],
                                        texture2d<float> leftMap [[texture(0)]],
                                        constant SpatialSynthesisUniforms &uniforms [[buffer(0)]]) {
  float2 value = spatialMap(leftMap, in.uv);
  float range = max(uniforms.extra.x, 0.0001);
  half level = half(saturate(0.5 + 0.5 * value.x / range));
  half3 color = half3(level);
  if (value.y < 0.5) {
    color = mix(color, half3(0.8h, 0.1h, 0.1h), 0.6h);
  }
  return half4(color, 1.0h);
}

// MARK: - Disparity

// Grayscale eye at the size of the map. Four bilinear taps per output pixel approach an area filter for the usual
// downsampling factors (3 to 6).
kernel void spatialGrayDownsample(texture2d<half> eye [[texture(0)]],
                                  texture2d<half, access::write> gray [[texture(1)]],
                                  constant float4 &rect [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
  uint width = gray.get_width();
  uint height = gray.get_height();
  if (gid.x >= width || gid.y >= height) {
    return;
  }
  float2 size = float2(float(width), float(height));
  float2 uv = (float2(gid) + 0.5) / size;
  float2 quarter = 0.25 / size;
  half3 sum = spatialSampleEye(eye, rect, uv + float2(-quarter.x, -quarter.y)).rgb;
  sum += spatialSampleEye(eye, rect, uv + float2(quarter.x, -quarter.y)).rgb;
  sum += spatialSampleEye(eye, rect, uv + float2(-quarter.x, quarter.y)).rgb;
  sum += spatialSampleEye(eye, rect, uv + float2(quarter.x, quarter.y)).rgb;
  half luma = dot(sum * 0.25h, half3(0.299h, 0.587h, 0.114h));
  gray.write(half4(luma, 0.0h, 0.0h, 1.0h), gid);
}

// Sum of absolute differences between the 7x7 window at (x, y) of the base tile (its top left corner, in tile
// coordinates) and the window [shift] pixels to the side in the match tile
static inline float spatialWindowCost(threadgroup const half *baseTile,
                                      threadgroup const half *matchTile,
                                      int x,
                                      int y,
                                      int shift) {
  float cost = 0.0;
  for (int j = 0; j < SPATIAL_WINDOW; j++) {
    int baseRow = (y + j) * SPATIAL_TILE_SIZE + x;
    int matchRow = (y + j) * SPATIAL_SEARCH_SIZE + x + SPATIAL_MAX_SEARCH + shift;
    for (int i = 0; i < SPATIAL_WINDOW; i++) {
      cost += float(abs(baseTile[baseRow + i] - matchTile[matchRow + i]));
    }
  }
  return cost;
}

// Block matching along the rows. config.x is 1 with the left eye as base (xRight = xLeft - d) and -1 with the right
// eye as base (xLeft = xRight + d); config.y is the search range in pixels (24 at most). The tiles of both images
// that the threadgroup needs are first copied to threadgroup memory. Writes the disparity (fraction of the width,
// parabolic sub pixel refinement) and a validity that is 0 on flat windows, which match anywhere.
kernel void spatialDisparity(texture2d<half, access::read> base [[texture(0)]],
                             texture2d<half, access::read> match [[texture(1)]],
                             texture2d<half, access::write> output [[texture(2)]],
                             constant int4 &config [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]],
                             uint2 lid [[thread_position_in_threadgroup]],
                             uint2 groupId [[threadgroup_position_in_grid]]) {
  threadgroup half baseTile[SPATIAL_TILE_SIZE * SPATIAL_TILE_SIZE];
  threadgroup half matchTile[SPATIAL_TILE_SIZE * SPATIAL_SEARCH_SIZE];

  int width = int(base.get_width());
  int height = int(base.get_height());
  int2 maxCoord = int2(width - 1, height - 1);
  // Top left pixel of the base tile: the threadgroup's pixels plus the window radius all around
  int2 origin = int2(groupId) * SPATIAL_TILE - SPATIAL_RADIUS;
  int firstIndex = int(lid.y) * SPATIAL_TILE + int(lid.x);
  int groupSize = SPATIAL_TILE * SPATIAL_TILE;

  for (int index = firstIndex; index < SPATIAL_TILE_SIZE * SPATIAL_TILE_SIZE; index += groupSize) {
    int2 tile = int2(index % SPATIAL_TILE_SIZE, index / SPATIAL_TILE_SIZE);
    int2 coord = clamp(origin + tile, int2(0), maxCoord);
    baseTile[index] = base.read(uint2(coord)).r;
  }
  // The match tile also spans the search range on both sides
  for (int index = firstIndex; index < SPATIAL_TILE_SIZE * SPATIAL_SEARCH_SIZE; index += groupSize) {
    int2 tile = int2(index % SPATIAL_SEARCH_SIZE, index / SPATIAL_SEARCH_SIZE);
    int2 coord = clamp(origin + tile - int2(SPATIAL_MAX_SEARCH, 0), int2(0), maxCoord);
    matchTile[index] = match.read(uint2(coord)).r;
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  // After the barrier only: every thread of the group must reach it
  if (int(gid.x) >= width || int(gid.y) >= height) {
    return;
  }

  int x = int(lid.x);
  int y = int(lid.y);
  int direction = config.x;
  int range = clamp(config.y, 1, SPATIAL_MAX_SEARCH);

  float bestCost = 1.0e30;
  int best = 0;
  for (int d = -range; d <= range; d++) {
    float cost = spatialWindowCost(baseTile, matchTile, x, y, -direction * d);
    if (cost < bestCost) {
      bestCost = cost;
      best = d;
    }
  }

  // Parabola through the costs around the best match
  float refined = float(best);
  if (best > -range && best < range) {
    float before = spatialWindowCost(baseTile, matchTile, x, y, -direction * (best - 1));
    float after = spatialWindowCost(baseTile, matchTile, x, y, -direction * (best + 1));
    float curvature = before - 2.0 * bestCost + after;
    if (curvature > 0.0001) {
      refined += clamp(0.5 * (before - after) / curvature, -0.5, 0.5);
    }
  }

  // Contrast of the base window
  half lowest = 1.0h;
  half highest = 0.0h;
  for (int j = 0; j < SPATIAL_WINDOW; j++) {
    for (int i = 0; i < SPATIAL_WINDOW; i++) {
      half value = baseTile[(y + j) * SPATIAL_TILE_SIZE + x + i];
      lowest = min(lowest, value);
      highest = max(highest, value);
    }
  }
  half validity = (highest - lowest) > 0.02h ? 1.0h : 0.0h;

  output.write(half4(half(refined / float(width)), validity, 0.0h, 1.0h), gid);
}

// Left right consistency: a disparity is reliable when the other map, at the pixel it points to, points back to
// within a pixel. Pixels that point outside the picture are unreliable too.
kernel void spatialConsistency(texture2d<half, access::read> rawLeft [[texture(0)]],
                               texture2d<half, access::read> rawRight [[texture(1)]],
                               texture2d<half, access::write> checkedLeft [[texture(2)]],
                               texture2d<half, access::write> checkedRight [[texture(3)]],
                               uint2 gid [[thread_position_in_grid]]) {
  int width = int(rawLeft.get_width());
  int height = int(rawLeft.get_height());
  if (int(gid.x) >= width || int(gid.y) >= height) {
    return;
  }
  float scale = float(width);
  half2 left = rawLeft.read(gid).rg;
  half2 right = rawRight.read(gid).rg;
  float leftD = float(left.x) * scale;
  float rightD = float(right.x) * scale;

  int inRight = int(round(float(gid.x) - leftD));
  int inLeft = int(round(float(gid.x) + rightD));
  half leftValid = 0.0h;
  half rightValid = 0.0h;
  if (inRight >= 0 && inRight < width) {
    float back = float(rawRight.read(uint2(uint(inRight), gid.y)).r) * scale;
    leftValid = abs(leftD - back) <= 1.0 ? left.y : 0.0h;
  }
  if (inLeft >= 0 && inLeft < width) {
    float back = float(rawLeft.read(uint2(uint(inLeft), gid.y)).r) * scale;
    rightValid = abs(rightD - back) <= 1.0 ? right.y : 0.0h;
  }
  checkedLeft.write(half4(left.x, leftValid, 0.0h, 1.0h), gid);
  checkedRight.write(half4(right.x, rightValid, 0.0h, 1.0h), gid);
}

// One direction of the separable 5 tap blur (config.xy is the step, (1, 0) or (0, 1)). Only reliable disparities
// count, and neighbours of a different brightness in the eye image count less, so that depth edges stay on object
// edges. Small unreliable holes fill from their neighbours; the output validity is the reliable share of the weights.
kernel void spatialGuidedBlur(texture2d<half, access::read> input [[texture(0)]],
                              texture2d<half, access::read> guide [[texture(1)]],
                              texture2d<half, access::write> output [[texture(2)]],
                              constant int4 &config [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
  int2 size = int2(int(input.get_width()), int(input.get_height()));
  if (int(gid.x) >= size.x || int(gid.y) >= size.y) {
    return;
  }
  int2 axis = config.xy;
  float centre = float(guide.read(gid).r);
  float sum = 0.0;
  float reliableWeight = 0.0;
  float totalWeight = 0.0;
  for (int i = -2; i <= 2; i++) {
    int2 coord = clamp(int2(gid) + axis * i, int2(0), size - 1);
    float2 value = float2(input.read(uint2(coord)).rg);
    float similarity = exp(-abs(float(guide.read(uint2(coord)).r) - centre) * 12.0);
    float weight = spatialBlurWeights[i + 2] * similarity;
    totalWeight += weight;
    weight *= value.y;
    sum += weight * value.x;
    reliableWeight += weight;
  }
  float disparity = reliableWeight > 0.0001 ? sum / reliableWeight : 0.0;
  float validity = totalWeight > 0.0001 ? reliableWeight / totalWeight : 0.0;
  output.write(half4(half(disparity), half(validity), 0.0h, 1.0h), gid);
}

// Exponential blend with the previous map, 0.6 old and 0.4 new, against flicker. A reliable value replaces an
// unreliable one; an old reliable value fades out over a few updates when no new one comes. config.x set starts
// afresh (first map, seek, layout change).
kernel void spatialTemporalBlend(texture2d<half, access::read> current [[texture(0)]],
                                 texture2d<half, access::read> history [[texture(1)]],
                                 texture2d<half, access::write> output [[texture(2)]],
                                 constant int4 &config [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
    return;
  }
  float2 now = float2(current.read(gid).rg);
  if (config.x != 0) {
    output.write(half4(half2(now), 0.0h, 1.0h), gid);
    return;
  }
  float2 old = float2(history.read(gid).rg);
  bool nowValid = now.y >= 0.5;
  bool oldValid = old.y >= 0.5;
  float2 result;
  if (nowValid && oldValid) {
    result = float2(mix(now.x, old.x, 0.6), max(now.y, old.y));
  } else if (nowValid) {
    result = now;
  } else if (oldValid) {
    result = float2(old.x, old.y * 0.85);
  } else {
    result = float2(mix(now.x, old.x, 0.6), max(now.y, old.y));
  }
  output.write(half4(half2(result), 0.0h, 1.0h), gid);
}
