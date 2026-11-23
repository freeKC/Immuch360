// The pixel work of "Enhance (AI)" around its models, pure and synchronous (run in an isolate by the engine): the app
// tiles of Rebuild details and Natural and their feathered blend, the resizing of Sharpen (half size in, the x4 result
// back to the size of the photo), the colour fix and the strength.
//
// The tiles are those of the probe of 23 November 2026 (probe-e0.md, section 7; make_dgl_tiled.py and vosr_run.py):
// 512 px with 64 px of overlap, a step of 448 px and a last tile against each edge, so that a 12 MP photo of 4000 x
// 3000 takes 63 tiles and a 3 MP one 20. Each tile is weighted by a linear ramp over the overlap from both of its sides
// (blend_tiles.py): no seam was seen at 100 percent on text, paving or carvings.
//
// The colour fix is that of VOSR (its wavelet fix, which the probe ran as a Gaussian blur of sigma 5): the low
// frequencies of the photo, the high ones of the result. SeedVR2 shifts tones on every photo (more contrast and
// saturation), so Rebuild details takes it too. The blur is three box blurs of radius 5 in a row (sigma about 5.5),
// whose cost does not grow with the radius.
//
// Every picture here is RGBA bytes, rows top to bottom, alpha 255.

import 'dart:math' as math;
import 'dart:typed_data';

/// One tile of a picture: its top left corner and its size, in pixels
typedef EnhanceTile = ({int x, int y, int width, int height});

/// The tile size and overlap of the probe for SeedVR2 and VOSR
const enhanceTileSize = 512;
const enhanceTileOverlap = 64;

/// The starts of the tiles of [tile] pixels along [length], overlapping by [overlap]: every step of tile less overlap,
/// then the last one against the end (positions() of make_dgl_tiled.py). A length shorter than the tile is one tile.
List<int> tileStarts(int length, int tile, int overlap) {
  final size = math.min(tile, length);
  final last = math.max(length - size, 0);
  final step = math.max(1, size - overlap);
  return <int>{for (var at = 0; at <= last; at += step) at, last}.toList()..sort();
}

/// The tiles of a picture of [width] x [height], row after row, all of the same size: [tile] or the picture's own
/// side when it is smaller
List<EnhanceTile> planTiles(int width, int height, {int tile = enhanceTileSize, int overlap = enhanceTileOverlap}) {
  final tileWidth = math.min(tile, width);
  final tileHeight = math.min(tile, height);
  return [
    for (final y in tileStarts(height, tileHeight, overlap))
      for (final x in tileStarts(width, tileWidth, overlap)) (x: x, y: y, width: tileWidth, height: tileHeight),
  ];
}

/// The weight of each column (or row) of a tile of [size] pixels: rising from 1/overlap to 1 over [overlap] pixels on
/// both sides; 1 everywhere without an overlap
Float32List featherRamp(int size, int overlap) {
  final ramp = Float32List(size);
  for (var i = 0; i < size; i++) {
    ramp[i] = overlap <= 0 ? 1 : math.min(math.min(i + 1, overlap), math.min(size - i, overlap)) / overlap;
  }
  return ramp;
}

/// Adds tiles into one picture, each weighted by its feather, then gives their weighted mean
class TileBlender {
  TileBlender(this.width, this.height) : _sum = Float32List(width * height * 3), _weight = Float32List(width * height);

  final int width;
  final int height;
  final Float32List _sum;
  final Float32List _weight;

  /// Adds [rgba], the pixels of [tile] (its width times its height), with a ramp over [overlap]
  void add(EnhanceTile tile, Uint8List rgba, {required int overlap}) {
    if (rgba.length != tile.width * tile.height * 4) {
      throw ArgumentError('A tile of ${tile.width} x ${tile.height} holds ${tile.width * tile.height * 4} bytes');
    }
    final columns = featherRamp(tile.width, overlap);
    final rows = featherRamp(tile.height, overlap);
    for (var y = 0; y < tile.height; y++) {
      final row = rows[y];
      final into = (tile.y + y) * width + tile.x;
      for (var x = 0; x < tile.width; x++) {
        final weight = row * columns[x];
        final from = 4 * (y * tile.width + x);
        final at = into + x;
        _sum[3 * at] += rgba[from] * weight;
        _sum[3 * at + 1] += rgba[from + 1] * weight;
        _sum[3 * at + 2] += rgba[from + 2] * weight;
        _weight[at] += weight;
      }
    }
  }

  /// The blended picture. Throws [StateError] when a pixel was in no tile.
  Uint8List toRgba() {
    final out = Uint8List(width * height * 4);
    for (var at = 0; at < width * height; at++) {
      final weight = _weight[at];
      if (weight <= 0) {
        throw StateError('The pixel ${at % width}, ${at ~/ width} is in no tile');
      }
      out[4 * at] = _byte(_sum[3 * at] / weight);
      out[4 * at + 1] = _byte(_sum[3 * at + 1] / weight);
      out[4 * at + 2] = _byte(_sum[3 * at + 2] / weight);
      out[4 * at + 3] = 255;
    }
    return out;
  }
}

int _byte(double value) => value <= 0 ? 0 : (value >= 255 ? 255 : (value + 0.5).toInt());

/// [rgba] of [width] x [height] at [toWidth] x [toHeight]: the mean of the pixels each one covers when it shrinks on
/// both sides (half size averages blocks of four), bilinear otherwise
Uint8List resizeRgba(Uint8List rgba, int width, int height, int toWidth, int toHeight) {
  if (toWidth == width && toHeight == height) {
    return Uint8List.fromList(rgba);
  }
  if (toWidth <= width && toHeight <= height) {
    return _area(rgba, width, height, toWidth, toHeight);
  }
  return _bilinear(rgba, width, height, toWidth, toHeight);
}

/// For each pixel of an axis of [to] pixels made from [from]: the first source pixel it covers and the share of each
typedef _Cover = ({int first, Float32List shares});

List<_Cover> _covers(int from, int to) {
  final scale = from / to;
  return [for (var i = 0; i < to; i++) _coverOf(i * scale, (i + 1) * scale, from)];
}

_Cover _coverOf(double start, double end, int from) {
  final first = start.floor();
  final last = math.min(from - 1, (end - 1e-9).floor());
  final shares = Float32List(last - first + 1);
  final span = end - start;
  for (var j = first; j <= last; j++) {
    final covered = math.min(end, j + 1.0) - math.max(start, j.toDouble());
    shares[j - first] = covered / span;
  }
  return (first: first, shares: shares);
}

Uint8List _area(Uint8List rgba, int width, int height, int toWidth, int toHeight) {
  final columns = _covers(width, toWidth);
  final rows = _covers(height, toHeight);
  // Across first, then down, three channels in floats
  final across = Float32List(toWidth * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < toWidth; x++) {
      final cover = columns[x];
      var r = 0.0;
      var g = 0.0;
      var b = 0.0;
      for (var k = 0; k < cover.shares.length; k++) {
        final from = 4 * (y * width + cover.first + k);
        final share = cover.shares[k];
        r += rgba[from] * share;
        g += rgba[from + 1] * share;
        b += rgba[from + 2] * share;
      }
      final at = 3 * (y * toWidth + x);
      across[at] = r;
      across[at + 1] = g;
      across[at + 2] = b;
    }
  }
  final out = Uint8List(toWidth * toHeight * 4);
  for (var y = 0; y < toHeight; y++) {
    final cover = rows[y];
    for (var x = 0; x < toWidth; x++) {
      var r = 0.0;
      var g = 0.0;
      var b = 0.0;
      for (var k = 0; k < cover.shares.length; k++) {
        final from = 3 * ((cover.first + k) * toWidth + x);
        final share = cover.shares[k];
        r += across[from] * share;
        g += across[from + 1] * share;
        b += across[from + 2] * share;
      }
      final at = 4 * (y * toWidth + x);
      out[at] = _byte(r);
      out[at + 1] = _byte(g);
      out[at + 2] = _byte(b);
      out[at + 3] = 255;
    }
  }
  return out;
}

Uint8List _bilinear(Uint8List rgba, int width, int height, int toWidth, int toHeight) {
  final out = Uint8List(toWidth * toHeight * 4);
  final scaleX = width / toWidth;
  final scaleY = height / toHeight;
  for (var y = 0; y < toHeight; y++) {
    final fy = ((y + 0.5) * scaleY - 0.5).clamp(0.0, height - 1.0);
    final y0 = fy.floor();
    final y1 = math.min(y0 + 1, height - 1);
    final dy = fy - y0;
    for (var x = 0; x < toWidth; x++) {
      final fx = ((x + 0.5) * scaleX - 0.5).clamp(0.0, width - 1.0);
      final x0 = fx.floor();
      final x1 = math.min(x0 + 1, width - 1);
      final dx = fx - x0;
      final at = 4 * (y * toWidth + x);
      for (var c = 0; c < 3; c++) {
        final top = rgba[4 * (y0 * width + x0) + c] * (1 - dx) + rgba[4 * (y0 * width + x1) + c] * dx;
        final bottom = rgba[4 * (y1 * width + x0) + c] * (1 - dx) + rgba[4 * (y1 * width + x1) + c] * dx;
        out[at + c] = _byte(top * (1 - dy) + bottom * dy);
      }
      out[at + 3] = 255;
    }
  }
  return out;
}

/// [rgba] of [width] x [height] grown to [toWidth] x [toHeight] by mirroring its right and bottom edges without
/// repeating them (numpy's reflect, as vosr_run.py pads a picture smaller than a tile); an edge of one pixel repeats
Uint8List reflectPad(Uint8List rgba, int width, int height, int toWidth, int toHeight) {
  int mirror(int i, int size) {
    if (i < size) {
      return i;
    }
    final back = 2 * (size - 1) - i;
    return back < 0 ? 0 : back;
  }

  final out = Uint8List(toWidth * toHeight * 4);
  for (var y = 0; y < toHeight; y++) {
    final from = mirror(y, height);
    for (var x = 0; x < toWidth; x++) {
      final source = 4 * (from * width + mirror(x, width));
      final at = 4 * (y * toWidth + x);
      out[at] = rgba[source];
      out[at + 1] = rgba[source + 1];
      out[at + 2] = rgba[source + 2];
      out[at + 3] = 255;
    }
  }
  return out;
}

/// The top left [toWidth] x [toHeight] of [rgba], which is [width] wide
Uint8List cropRgba(Uint8List rgba, int width, int height, int toWidth, int toHeight) =>
    cropRgbaAt(rgba, width, 0, 0, toWidth, toHeight);

/// The [toWidth] x [toHeight] of [rgba] (which is [width] wide) whose top left corner is at [x], [y]
Uint8List cropRgbaAt(Uint8List rgba, int width, int x, int y, int toWidth, int toHeight) {
  final out = Uint8List(toWidth * toHeight * 4);
  for (var row = 0; row < toHeight; row++) {
    out.setRange(4 * row * toWidth, 4 * (row + 1) * toWidth, rgba, 4 * ((y + row) * width + x));
  }
  return out;
}

/// The radius of each of the three box blurs of the colour fix (sigma about 5.5, the 5 of VOSR's fix)
const colourFixRadius = 5;

/// Keeps the tones of [original] in [result] (both [width] x [height]), in place: each channel of the result less its
/// own blur plus the blur of the original (see the top of this file)
void colourFix(Uint8List result, Uint8List original, int width, int height, {int radius = colourFixRadius}) {
  final count = width * height;
  final mine = Float32List(count);
  final theirs = Float32List(count);
  final scratch = Float32List(count);
  for (var c = 0; c < 3; c++) {
    for (var i = 0; i < count; i++) {
      mine[i] = result[4 * i + c].toDouble();
      theirs[i] = original[4 * i + c].toDouble();
    }
    final blurredMine = Float32List.fromList(mine);
    _boxBlur3(blurredMine, scratch, width, height, radius);
    _boxBlur3(theirs, scratch, width, height, radius);
    for (var i = 0; i < count; i++) {
      result[4 * i + c] = _byte(mine[i] + theirs[i] - blurredMine[i]);
    }
  }
}

/// Three box blurs of [radius] across then down, in place in [data], the edges repeated
void _boxBlur3(Float32List data, Float32List scratch, int width, int height, int radius) {
  for (var pass = 0; pass < 3; pass++) {
    _boxAcross(data, scratch, width, height, radius);
    _boxDown(scratch, data, width, height, radius);
  }
}

void _boxAcross(Float32List from, Float32List to, int width, int height, int radius) {
  final size = 2 * radius + 1;
  for (var y = 0; y < height; y++) {
    final row = y * width;
    var sum = 0.0;
    for (var k = -radius; k <= radius; k++) {
      sum += from[row + k.clamp(0, width - 1)];
    }
    for (var x = 0; x < width; x++) {
      to[row + x] = sum / size;
      sum += from[row + math.min(x + radius + 1, width - 1)] - from[row + math.max(x - radius, 0)];
    }
  }
}

void _boxDown(Float32List from, Float32List to, int width, int height, int radius) {
  final size = 2 * radius + 1;
  for (var x = 0; x < width; x++) {
    var sum = 0.0;
    for (var k = -radius; k <= radius; k++) {
      sum += from[k.clamp(0, height - 1) * width + x];
    }
    for (var y = 0; y < height; y++) {
      to[y * width + x] = sum / size;
      sum += from[math.min(y + radius + 1, height - 1) * width + x] - from[math.max(y - radius, 0) * width + x];
    }
  }
}

/// [result] made [strength] (0 to 1) of itself and the rest of [original], in place
void blendStrength(Uint8List result, Uint8List original, double strength) {
  final share = strength.clamp(0.0, 1.0);
  for (var i = 0; i < result.length; i += 4) {
    for (var c = 0; c < 3; c++) {
      final photo = original[i + c];
      result[i + c] = _byte(photo + share * (result[i + c] - photo));
    }
    result[i + 3] = 255;
  }
}
