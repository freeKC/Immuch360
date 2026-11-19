// The work on each frame of a 3D video (store/m2/release-49/lots/video3d-plan.md, sections 2.2 and 4.6), as
// .github/desktop/ai/make_relief_video_golden.py describes it: the input of Video Depth Anything, the histogram of the
// cut detector, the right eye of relief-v1 with the percentiles of the job, the soft floating window, and half side by
// side. Two implementations give the same bytes: the Rust of immuch_sbs_codec (NativeVideoFrames, about 20 ms for the
// right eye of a 1080p frame), and the pure Dart reference below, which the tests hold to the golden fixture and to the
// Rust, and which a job falls back to when the library is missing (slow: the right eye of the photos' Dart). The right
// eye of the reference is relief-v1 of the photos itself (writeRightEye, right_eye.dart), so that a frame of a 3D video
// and a 3D photo of the same picture match pixel for pixel.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immuch_sbs_codec/immuch_sbs_codec.dart' as native;

/// The ImageNet mean and std of the input of Video Depth Anything
const vdaMean = [0.485, 0.456, 0.406];
const vdaStd = [0.229, 0.224, 0.225];

/// The size the cut detector reduces a frame to, and its bins
const cutHistogramWidth = 320;
const cutHistogramHeight = 180;
const cutHistogramBins = 64;

/// The frame work of a 3D video; frames are RGB bytes, rows after rows
abstract interface class VideoFrameOps {
  /// Which implementation it is, for the logs and the job file
  String get name;

  /// [rgb] ([width] x [height]) as the model's input of [outWidth] x [outHeight], channels first, into [out]
  void vdaInput(Uint8List rgb, int width, int height, Float32List out, int outWidth, int outHeight);

  /// The 64 bins of the luma of [rgb] reduced to 320 x 180, each a share of its pixels
  Float64List lumaHistogram(Uint8List rgb, int width, int height);

  /// Writes the right eye into the right half of [sbs] (2 [width] x [height], the frame in its left half) from
  /// [depth] ([depthWidth] x [depthHeight], larger is nearer) normalised between [p2] and [p98]; [holes] gets 1 for each
  /// filled pixel. Returns how many were filled.
  int reliefEye(
    Uint8List sbs,
    int width,
    int height,
    Float64List depth,
    int depthWidth,
    int depthHeight, {
    required double p2,
    required double p98,
    required double parallax,
    required double convergence,
    Uint8List? holes,
  });

  /// Fades [band] columns at both edges of each eye of [sbs] to black, linearly (the edge column black)
  void edgeFade(Uint8List sbs, int width, int height, int band);

  /// Both eyes of [sbs] squeezed to half their width into [out] ([width] x [height])
  void halfSbs(Uint8List sbs, int width, int height, Uint8List out);

  /// Gives back what it holds
  void dispose();
}

/// The band of the soft floating window for an eye [width] wide at [parallax] and [convergence]: ceil(parallax *
/// width * max(c, 1 - c)) + 2, at most width / 2 (17 px at Subtle, 22 at Normal, 31 at Strong for 1920)
int videoEdgeBand(double parallax, int width, double convergence) =>
    math.min(width ~/ 2, (parallax * width * math.max(convergence, 1 - convergence)).ceil() + 2);

/// The Rust of immuch_sbs_codec, null when the library is not in this build
VideoFrameOps? nativeVideoFrameOps({int threads = 2}) =>
    native.nativeCodecAvailable ? _NativeVideoFrameOps(native.NativeVideoFrames(), threads) : null;

class _NativeVideoFrameOps implements VideoFrameOps {
  _NativeVideoFrameOps(this._frames, this._threads);

  final native.NativeVideoFrames _frames;
  final int _threads;

  @override
  String get name => 'rust';

  @override
  void vdaInput(Uint8List rgb, int width, int height, Float32List out, int outWidth, int outHeight) =>
      _frames.vdaInput(rgb, width, height, out, outWidth, outHeight);

  @override
  Float64List lumaHistogram(Uint8List rgb, int width, int height) => _frames.lumaHistogram(rgb, width, height);

  @override
  int reliefEye(
    Uint8List sbs,
    int width,
    int height,
    Float64List depth,
    int depthWidth,
    int depthHeight, {
    required double p2,
    required double p98,
    required double parallax,
    required double convergence,
    Uint8List? holes,
  }) => _frames.reliefEye(
    sbs,
    width,
    height,
    depth,
    depthWidth,
    depthHeight,
    p2: p2,
    p98: p98,
    parallax: parallax,
    convergence: convergence,
    threads: _threads,
    holes: holes,
  );

  @override
  void edgeFade(Uint8List sbs, int width, int height, int band) => _frames.edgeFade(sbs, width, height, band);

  @override
  void halfSbs(Uint8List sbs, int width, int height, Uint8List out) => _frames.halfSbs(sbs, width, height, out);

  @override
  void dispose() => _frames.dispose();
}

/// The pure Dart reference, step by step as the golden script
class DartVideoFrameOps implements VideoFrameOps {
  const DartVideoFrameOps();

  @override
  String get name => 'dart';

  @override
  void vdaInput(Uint8List rgb, int width, int height, Float32List out, int outWidth, int outHeight) {
    _checkFrame(rgb, width, height, 3);
    if (out.length < 3 * outWidth * outHeight) {
      throw ArgumentError('${out.length} values do not hold an input of $outWidth x $outHeight');
    }
    final across = _cubicTaps(width, outWidth);
    final down = _cubicTaps(height, outHeight);
    final rows = Float64List(height * outWidth * 3);
    for (var y = 0; y < height; y++) {
      final source = y * width * 3;
      final row = y * outWidth * 3;
      for (var x = 0; x < outWidth; x++) {
        final (columns, weights) = across[x];
        for (var k = 0; k < 3; k++) {
          var value = 0.0;
          for (var i = 0; i < 4; i++) {
            value += rgb[source + columns[i] * 3 + k] * weights[i];
          }
          rows[row + x * 3 + k] = value;
        }
      }
    }
    final plane = outWidth * outHeight;
    for (var y = 0; y < outHeight; y++) {
      final (sources, weights) = down[y];
      for (var x = 0; x < outWidth; x++) {
        for (var k = 0; k < 3; k++) {
          var value = 0.0;
          for (var i = 0; i < 4; i++) {
            value += rows[(sources[i] * outWidth + x) * 3 + k] * weights[i];
          }
          final byte = (value + 0.5).floorToDouble().clamp(0.0, 255.0);
          out[k * plane + y * outWidth + x] = (byte / 255.0 - vdaMean[k]) / vdaStd[k];
        }
      }
    }
  }

  @override
  Float64List lumaHistogram(Uint8List rgb, int width, int height) {
    _checkFrame(rgb, width, height, 3);
    final across = _areaSpans(width, cutHistogramWidth);
    final down = _areaSpans(height, cutHistogramHeight);
    final rows = Float64List(height * cutHistogramWidth * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < cutHistogramWidth; x++) {
        for (var k = 0; k < 3; k++) {
          var value = 0.0;
          for (final (i, weight) in across[x]) {
            value += rgb[(y * width + i) * 3 + k] * weight;
          }
          rows[(y * cutHistogramWidth + x) * 3 + k] = value;
        }
      }
    }
    final area = (width / cutHistogramWidth) * (height / cutHistogramHeight);
    final counts = Int32List(cutHistogramBins);
    final channels = Int32List(3);
    for (final span in down) {
      for (var x = 0; x < cutHistogramWidth; x++) {
        for (var k = 0; k < 3; k++) {
          var value = 0.0;
          for (final (i, weight) in span) {
            value += rows[(i * cutHistogramWidth + x) * 3 + k] * weight;
          }
          channels[k] = (value / area + 0.5).floor().clamp(0, 255);
        }
        final luma = (channels[0] * 4899 + channels[1] * 9617 + channels[2] * 1868 + 8192) >> 14;
        counts[luma >> 2]++;
      }
    }
    const total = cutHistogramWidth * cutHistogramHeight;
    return Float64List.fromList([for (final count in counts) count / total]);
  }

  @override
  int reliefEye(
    Uint8List sbs,
    int width,
    int height,
    Float64List depth,
    int depthWidth,
    int depthHeight, {
    required double p2,
    required double p98,
    required double parallax,
    required double convergence,
    Uint8List? holes,
  }) {
    _checkFrame(sbs, width * 2, height, 3);
    // The left eye as RGBA for writeRightEye, the right eye written into RGBA, then both put back as RGB
    final left = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final from = (y * width * 2 + x) * 3;
        final to = (y * width + x) * 4;
        left[to] = sbs[from];
        left[to + 1] = sbs[from + 1];
        left[to + 2] = sbs[from + 2];
        left[to + 3] = 255;
      }
    }
    final map = dilateForeground(normaliseWith(ReliefDepth(depthWidth, depthHeight, depth), p2, p98));
    final right = Uint8List(width * height * 4);
    final eye = writeRightEye(
      left: left,
      width: width,
      height: height,
      map: map,
      parallax: parallax,
      convergence: convergence,
      target: right,
      holes: holes,
    );
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final from = (y * width + x) * 4;
        final to = (y * width * 2 + width + x) * 3;
        sbs[to] = right[from];
        sbs[to + 1] = right[from + 1];
        sbs[to + 2] = right[from + 2];
      }
    }
    return eye.filledPixels;
  }

  @override
  void edgeFade(Uint8List sbs, int width, int height, int band) {
    _checkFrame(sbs, width * 2, height, 3);
    if (band > width ~/ 2 || band < 0) {
      throw ArgumentError('A band of $band for an eye of $width');
    }
    if (band == 0) {
      return;
    }
    for (var y = 0; y < height; y++) {
      for (var eye = 0; eye < 2; eye++) {
        final start = (y * width * 2 + eye * width) * 3;
        for (var k = 0; k < band; k++) {
          for (final column in [k, width - 1 - k]) {
            for (var channel = 0; channel < 3; channel++) {
              final at = start + column * 3 + channel;
              sbs[at] = (sbs[at] * k * 2 + band) ~/ (2 * band);
            }
          }
        }
      }
    }
  }

  @override
  void halfSbs(Uint8List sbs, int width, int height, Uint8List out) {
    _checkFrame(sbs, width * 2, height, 3);
    if (width.isOdd || out.length < width * height * 3) {
      throw ArgumentError('A half frame of $width x $height in ${out.length} bytes');
    }
    for (var y = 0; y < height; y++) {
      final source = y * width * 6;
      final target = y * width * 3;
      for (var x = 0; x < width; x++) {
        for (var k = 0; k < 3; k++) {
          out[target + 3 * x + k] = (sbs[source + 6 * x + k] + sbs[source + 6 * x + 3 + k] + 1) >> 1;
        }
      }
    }
  }

  @override
  void dispose() {}
}

/// [raw] normalised between [p2] and [p98] given from outside (the job's, smoothed over time): (D - p2) / (p98 - p2)
/// clamped to [0, 1], 0.5 everywhere when p98 - p2 <= 0 and for a value that is not a number
ReliefDepth normaliseWith(ReliefDepth raw, double p2, double p98) {
  final spread = p98 - p2;
  final values = Float64List(raw.values.length);
  for (var index = 0; index < values.length; index++) {
    final value = raw.values[index];
    if (spread <= 0 || value.isNaN) {
      values[index] = 0.5;
    } else {
      final d = (value - p2) / spread;
      values[index] = d < 0 ? 0 : (d > 1 ? 1 : d);
    }
  }
  return ReliefDepth(raw.width, raw.height, values);
}

List<(List<int>, List<double>)> _cubicTaps(int sizeIn, int sizeOut) {
  const a = -0.75;
  return [
    for (var x = 0; x < sizeOut; x++)
      () {
        final u = (x + 0.5) * sizeIn / sizeOut - 0.5;
        final x0 = u.floor();
        final f = u - x0;
        final c0 = ((a * (f + 1) - 5 * a) * (f + 1) + 8 * a) * (f + 1) - 4 * a;
        final c1 = ((a + 2) * f - (a + 3)) * f * f + 1;
        final c2 = ((a + 2) * (1 - f) - (a + 3)) * (1 - f) * (1 - f) + 1;
        return ([for (var i = 0; i < 4; i++) (x0 - 1 + i).clamp(0, sizeIn - 1)], [c0, c1, c2, 1 - c0 - c1 - c2]);
      }(),
  ];
}

List<List<(int, double)>> _areaSpans(int sizeIn, int sizeOut) {
  final scale = sizeIn / sizeOut;
  return [
    for (var x = 0; x < sizeOut; x++)
      () {
        final start = x * scale;
        final end = (x + 1) * scale;
        final span = <(int, double)>[];
        for (var i = start.floor(); i < end && i < sizeIn; i++) {
          final weight = math.min(end, (i + 1).toDouble()) - math.max(start, i.toDouble());
          if (weight > 0) {
            span.add((i, weight));
          }
        }
        return span;
      }(),
  ];
}

void _checkFrame(Uint8List bytes, int width, int height, int channels) {
  if (width < 1 || height < 1 || bytes.length < width * height * channels) {
    throw ArgumentError('${bytes.length} bytes do not hold a frame of $width x $height');
  }
}
