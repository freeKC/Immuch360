// relief-v1 against relief-v2 on a real photo, with the real Depth Anything V2 Small and MI-GAN, by hand only (lot I3 of
// release 46). The same depth map of the photo goes through relief-v1, relief-v2 without MI-GAN and relief-v2 with it;
// each right eye is measured and written beside the others for the eye:
//
//  - holes: the share of the right eye no pixel reached, their runs of 4 pixels or more, the longest run;
//  - breaks on edges: of the depth jumps of a row (two neighbours more than the link threshold apart, where the right
//    eye opens or overlaps), the share that falls within one pixel of an edge of the photo (two neighbours more than
//    40 apart in R + G + B): a jump off the edges drags background with an object (halo) or cuts an object;
//  - sharp share: the part of the depth variation along the rows made in jumps rather than in ramps;
//  - fill texture: the mean luma step between neighbours inside the filled pixels, against the same around them
//    (relief-v1 repeats one pixel, near 0; a fill that continues the background comes near 1);
//  - the time of each.
//
//   IMMUCH360_ORT_LIB=/path/libonnxruntime.so.1.31.0 IMMUCH360_RELIEF_PHOTO=photo.jpg \
//   IMMUCH360_RELIEF_DEPTH=depth_anything_v2_small.onnx IMMUCH360_RELIEF_MIGAN=migan_pipeline_v2.onnx \
//   IMMUCH360_RELIEF_OUT=/folder flutter test test/desktop/ai/relief/relief_v2_measure_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_v2.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immich_mobile/desktop/ai/scene/migan_inpaint.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

void main() {
  final environment = Platform.environment;
  const names = [
    'IMMUCH360_ORT_LIB',
    'IMMUCH360_RELIEF_PHOTO',
    'IMMUCH360_RELIEF_DEPTH',
    'IMMUCH360_RELIEF_MIGAN',
    'IMMUCH360_RELIEF_OUT',
  ];
  final missing = names.where((name) => (environment[name] ?? '').isEmpty).toList();

  test(
    'relief-v1 against relief-v2 on one photo',
    () {
      final library = environment['IMMUCH360_ORT_LIB']!;
      final photo = environment['IMMUCH360_RELIEF_PHOTO']!;
      final out = Directory(environment['IMMUCH360_RELIEF_OUT']!)..createSync(recursive: true);
      const codec = DartSbsCodec();
      final bytes = File(photo).readAsBytesSync();
      final header = JpegHeader.read(bytes);
      final eye = fitEye(
        orientDecoded(codec.decodeJpeg(bytes), orientation: exifOrientation(header.exif)),
        maxWidth: ReliefV1.maxEyeWidth,
        maxHeight: 2 * ReliefV1.maxEyeWidth,
      );
      final width = eye.width;
      final height = eye.height;
      final pair = pairWithLeftEye(eye);
      final stride = 8 * width;
      final watch = Stopwatch()..start();
      final backend = OrtDepthBackend(libraryPath: library, modelPath: environment['IMMUCH360_RELIEF_DEPTH']!)..open();
      final input = reliefInputOf(
        pair,
        width: width,
        height: height,
        stride: stride,
        inputWidth: backend.inputWidth,
        inputHeight: backend.inputHeight,
      );
      final depth = cropToPhoto(backend.estimate(input.nchw), input.frame);
      backend.close();
      final depthTime = watch.elapsedMilliseconds;
      final report = <String, Object>{
        'photo': p.basename(photo),
        'eye': '$width x $height',
        'map': '${depth.width} x ${depth.height}',
        'depthMs': depthTime,
        'processors': Platform.numberOfProcessors,
      };

      Uint8List copy() => Uint8List.fromList(pair);

      // relief-v1
      final v1 = copy();
      final v1Holes = Uint8List(width * height);
      watch.reset();
      reliefV1RightEye(
        left: v1,
        width: width,
        height: height,
        leftStride: stride,
        depth: depth,
        target: v1,
        targetOffset: 4 * width,
        targetStride: stride,
        holes: v1Holes,
      );
      final v1Time = watch.elapsedMilliseconds;
      final v1Map = reliefMapOf(depth).depth;

      // relief-v2 without MI-GAN
      final v2 = copy();
      final v2Holes = Uint8List(width * height);
      watch.reset();
      reliefV2RightEye(
        left: v2,
        width: width,
        height: height,
        leftStride: stride,
        depth: depth,
        target: v2,
        targetOffset: 4 * width,
        targetStride: stride,
        holes: v2Holes,
      );
      final v2Time = watch.elapsedMilliseconds;

      // relief-v2 with MI-GAN
      final runtime = OrtRuntime.load(library);
      watch.reset();
      final session = runtime.openSession(environment['IMMUCH360_RELIEF_MIGAN']!);
      expect(miganRefusalOf(session.inputs, session.outputs), isNull);
      final openTime = watch.elapsedMilliseconds;
      final inpaint = OrtMiganInpaint(session: () => session, modelSha256: '', paintHoles: false);
      final v2m = copy();
      final v2mHoles = Uint8List(width * height);
      watch.reset();
      final withMigan = reliefV2RightEye(
        left: v2m,
        width: width,
        height: height,
        leftStride: stride,
        depth: depth,
        target: v2m,
        targetOffset: 4 * width,
        targetStride: stride,
        holes: v2mHoles,
        inpaint: inpaint,
      );
      final v2mTime = watch.elapsedMilliseconds;
      session.close();

      final normalised = normaliseDepth(depth).depth;
      report['v1'] = {
        'ms': v1Time,
        ..._holes(v1Holes, width, height),
        ..._edges(pair, EyeDepthSampler(v1Map, width, height), width, height, stride),
        'fillTexture': _fillTexture(v1, v1Holes, width, height, stride),
      };
      report['v2'] = {
        'ms': v2Time,
        ..._holes(v2Holes, width, height),
        ..._edges(
          pair,
          GuidedEyeDepth(normalised, eye: pair, eyeWidth: width, eyeHeight: height, stride: stride),
          width,
          height,
          stride,
        ),
        'fillTexture': _fillTexture(v2, v2Holes, width, height, stride),
      };
      report['v2Migan'] = {
        'ms': v2mTime,
        'sessionOpenMs': openTime,
        'cells': withMigan.inpaint.cells,
        'inpaintedPixels': withMigan.inpaint.pixels,
        ..._holes(v2mHoles, width, height),
        'fillTexture': _fillTexture(v2m, v2mHoles, width, height, stride),
      };
      final text = const JsonEncoder.withIndent('  ').convert(report);
      // ignore: avoid_print
      print(text);
      final stem = p.basenameWithoutExtension(photo);
      File(p.join(out.path, '$stem-measure.json')).writeAsStringSync(text);

      const options = SbsEncodeOptions(quality: 92);
      for (final (name, rgba) in [('v1', v1), ('v2', v2), ('v2-migan', v2m)]) {
        File(
          p.join(out.path, '${stem}_$name.jpg'),
        ).writeAsBytesSync(codec.encodeSbs(SbsPicture(width: 2 * width, height: height, rgba: rgba), options));
      }
      // The right eyes side by side, v1 | v2 | v2 with MI-GAN, around the cell with the most holes of relief-v1
      final side = math.min(512, math.min(width, height));
      final (cx, cy) = _busiest(v1Holes, width, height, side);
      final crop = Uint8List(3 * side * side * 4);
      for (final (index, rgba) in [v1, v2, v2m].indexed) {
        for (var y = 0; y < side; y++) {
          final from = (cy + y) * stride + 4 * width + 4 * cx;
          crop.setRange((y * 3 * side + index * side) * 4, (y * 3 * side + index * side + side) * 4, rgba, from);
        }
      }
      File(
        p.join(out.path, '${stem}_crop_v1_v2_v2migan.jpg'),
      ).writeAsBytesSync(codec.encodeSbs(SbsPicture(width: 3 * side, height: side, rgba: crop), options));

      // The same away from the borders of the frame (an edge of an object), with the depth of v1 and of v2 under it
      final (ix, iy) = _busiest(v1Holes, width, height, side, margin: 96);
      final inner = Uint8List(3 * side * 2 * side * 4);
      for (final (index, rgba) in [v1, v2, v2m].indexed) {
        for (var y = 0; y < side; y++) {
          final from = (iy + y) * stride + 4 * width + 4 * ix;
          inner.setRange((y * 3 * side + index * side) * 4, (y * 3 * side + index * side + side) * 4, rgba, from);
        }
      }
      final row = Float64List(width);
      for (final (index, rows) in [
        (0, EyeDepthSampler(v1Map, width, height) as EyeDepthRows),
        (1, GuidedEyeDepth(normalised, eye: pair, eyeWidth: width, eyeHeight: height, stride: stride)),
      ]) {
        for (var y = 0; y < side; y++) {
          rows.sampleRow(iy + y, row);
          for (var x = 0; x < side; x++) {
            final grey = (255 * row[ix + x]).round().clamp(0, 255);
            final at = ((side + y) * 3 * side + index * side + x) * 4;
            inner.setAll(at, [grey, grey, grey, 255]);
          }
        }
      }
      for (var y = 0; y < side; y++) {
        final from = (iy + y) * stride + 4 * ix;
        final at = ((side + y) * 3 * side + 2 * side) * 4;
        inner.setRange(at, at + side * 4, pair, from);
      }
      File(
        p.join(out.path, '${stem}_edge_v1_v2_v2migan_depth.jpg'),
      ).writeAsBytesSync(codec.encodeSbs(SbsPicture(width: 3 * side, height: 2 * side, rgba: inner), options));
    },
    skip: missing.isEmpty ? null : 'by hand: set ${missing.join(', ')}',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

Map<String, Object> _holes(Uint8List holes, int width, int height) {
  var count = 0;
  var runs = 0;
  var longest = 0;
  for (var y = 0; y < height; y++) {
    var run = 0;
    for (var x = 0; x <= width; x++) {
      if (x < width && holes[y * width + x] == 1) {
        run++;
        count++;
        continue;
      }
      if (run >= ReliefV2.inpaintMinRun) {
        runs++;
      }
      longest = math.max(longest, run);
      run = 0;
    }
  }
  return {'holeShare': count / (width * height), 'runsOf4': runs, 'longestRun': longest};
}

/// See the top of this file: breaks on edges and sharp share, on the left eye of [pair] and its depth [rows]
Map<String, Object> _edges(Uint8List pair, EyeDepthRows rows, int width, int height, int stride) {
  final d = Float64List(width);
  var breaks = 0;
  var onEdges = 0;
  var total = 0.0;
  var sharp = 0.0;
  for (var y = 0; y < height; y++) {
    rows.sampleRow(y, d);
    final row = y * stride;
    bool edgeAt(int x) {
      if (x < 0 || x + 1 >= width) {
        return false;
      }
      final a = row + 4 * x;
      final step =
          (pair[a] - pair[a + 4]).abs() + (pair[a + 1] - pair[a + 5]).abs() + (pair[a + 2] - pair[a + 6]).abs();
      return step > 40;
    }

    for (var x = 0; x + 1 < width; x++) {
      final step = (d[x + 1] - d[x]).abs();
      total += step;
      if (step > ReliefV1.linkThreshold) {
        sharp += step;
        breaks++;
        if (edgeAt(x - 1) || edgeAt(x) || edgeAt(x + 1)) {
          onEdges++;
        }
      }
    }
  }
  return {
    'breaks': breaks,
    'breaksOnEdges': breaks == 0 ? 0 : onEdges / breaks,
    'sharpShare': total == 0 ? 0 : sharp / total,
  };
}

/// The mean luma step between horizontal neighbours inside the filled pixels, over the same in the known pixels within
/// 8 pixels of them
double _fillTexture(Uint8List pair, Uint8List holes, int width, int height, int stride) {
  double luma(int x, int y) {
    final at = y * stride + 4 * width + 4 * x;
    return 0.2126 * pair[at] + 0.7152 * pair[at + 1] + 0.0722 * pair[at + 2];
  }

  var inside = 0.0;
  var insideCount = 0;
  var around = 0.0;
  var aroundCount = 0;
  for (var y = 0; y < height; y++) {
    var lastHole = -1000;
    for (var x = 0; x + 1 < width; x++) {
      final hole = holes[y * width + x] == 1 && holes[y * width + x + 1] == 1;
      if (holes[y * width + x] == 1) {
        lastHole = x;
      }
      final step = (luma(x + 1, y) - luma(x, y)).abs();
      if (hole) {
        inside += step;
        insideCount++;
      } else if (holes[y * width + x] == 0 && holes[y * width + x + 1] == 0 && x - lastHole <= 8) {
        around += step;
        aroundCount++;
      }
    }
  }
  if (insideCount == 0 || aroundCount == 0 || around == 0) {
    return 0;
  }
  return (inside / insideCount) / (around / aroundCount);
}

/// The top left corner of the [side] x [side] square with the most holes, on a grid of quarter squares, the holes within
/// [margin] of the left and right borders not counted
(int, int) _busiest(Uint8List holes, int width, int height, int side, {int margin = 0}) {
  var best = -1;
  var at = (0, 0);
  final step = math.max(1, side ~/ 4);
  for (var top = 0; top + side <= height; top += step) {
    for (var left = 0; left + side <= width; left += step) {
      var count = 0;
      for (var y = top; y < top + side; y++) {
        for (var x = math.max(left, margin); x < math.min(left + side, width - margin); x++) {
          count += holes[y * width + x];
        }
      }
      if (count > best) {
        best = count;
        at = (left, top);
      }
    }
  }
  return at;
}
