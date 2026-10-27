// The time relief-v1 takes on a photo of 12 Mpx, run by hand (not a test: the suite never runs it). The plan aims at
// under 0.5 s for the right eye; the numbers go in the note of the lot, never in an assertion of the CI.
//
//   dart run test/desktop/ai/relief/relief_bench.dart [width height [runs]]          (JIT)
//   dart compile exe test/desktop/ai/relief/relief_bench.dart -o /tmp/relief_bench   (AOT, as the app runs it)
//
// The photo is made up (a textured gradient) and the map too (a ground coming nearer, near boxes with hard edges that
// open holes): the cost of relief-v1 depends on the size of the photo, not on what it shows.

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_flags.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main(List<String> arguments) {
  final width = arguments.isNotEmpty ? int.parse(arguments[0]) : 4000;
  final height = arguments.length > 1 ? int.parse(arguments[1]) : 3000;
  final runs = arguments.length > 2 ? int.parse(arguments[2]) : 5;

  // The pair as the engine holds it: the photo on the left half, the right eye written on the right half
  final pair = Uint8List(2 * width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final at = (y * 2 * width + x) * 4;
      pair[at] = (x * 255 ~/ width + (x ^ y) % 17) & 255;
      pair[at + 1] = (y * 255 ~/ height + (x * 3 + y) % 23) & 255;
      pair[at + 2] = ((x + y) % 256 + (x * y) % 11) & 255;
      pair[at + 3] = 255;
    }
  }
  final model = Float32List(depthModelInputWidth * depthModelInputHeight);
  for (var y = 0; y < depthModelInputHeight; y++) {
    for (var x = 0; x < depthModelInputWidth; x++) {
      var value = 1.0 + 4.0 * y / depthModelInputHeight + 0.2 * (x % 40) / 40;
      if ((x ~/ 90).isOdd && (y ~/ 120).isOdd) {
        value = 9.0;
      }
      model[y * depthModelInputWidth + x] = value;
    }
  }
  final depthMap = DepthMap(depthModelInputWidth, depthModelInputHeight, model);

  final times = <String, List<int>>{};
  void time(String name, void Function() step) {
    final watch = Stopwatch()..start();
    step();
    (times[name] ??= []).add(watch.elapsedMicroseconds);
  }

  late ReliefInput input;
  late ReliefDepth raw;
  late ReliefMap map;
  var filled = 0;
  var luma = 0.0;
  for (var run = 0; run < runs; run++) {
    time('model input (area average, NCHW)', () {
      input = reliefInputOf(pair, width: width, height: height, stride: 2 * width * 4);
    });
    time('map (cut, percentiles, dilation)', () {
      raw = cropToPhoto(depthMap, input.frame);
      map = reliefMapOf(raw);
    });
    time('right eye (projection, filling, blur)', () {
      filled = writeRightEye(
        left: pair,
        width: width,
        height: height,
        leftStride: 2 * width * 4,
        map: map.depth,
        parallax: ReliefV1.parallax,
        convergence: ReliefV1.convergence,
        target: pair,
        targetOffset: width * 4,
        targetStride: 2 * width * 4,
      ).filledPixels;
    });
    time('mean luma and flags', () {
      luma = meanLuma(pair, width: width, height: height, stride: 2 * width * 4);
      reliefFlags(lowRelief: map.lowRelief, filledPixels: filled, width: width, height: height, meanLuma: luma);
    });
  }

  String ms(int micros) => (micros / 1000).toStringAsFixed(1);
  stdout.writeln(
    'relief-v1 on $width x $height (${(width * height / 1e6).toStringAsFixed(1)} Mpx), $runs runs, '
    '${input.frame}, $filled pixels filled, mean luma ${luma.toStringAsFixed(1)}',
  );
  for (final entry in times.entries) {
    final sorted = [...entry.value]..sort();
    stdout.writeln(
      '  ${entry.key}: median ${ms(sorted[sorted.length ~/ 2])} ms, first ${ms(entry.value.first)} ms, '
      'best ${ms(sorted.first)} ms',
    );
  }
}
