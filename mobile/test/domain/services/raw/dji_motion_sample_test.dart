// Reads the attitude of the real DJI Osmo 360 sample of the RAW 360 lots when given and checks it against the
// reference reader of the study: IMMUCH_DJI_MOTION_SAMPLE=/path/CAM_20250715191201_0003_D.OSV. The file is only read,
// in place.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/raw/dji_motion.dart';

import '../../../fixtures/raw/dji_motion_slices.dart';

final _sample = Platform.environment['IMMUCH_DJI_MOTION_SAMPLE'];

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

// The angle in degrees between two orientations, whatever their signs and the rounding of their norms: that of a* b
double _angle(List<double> a, List<double> b) {
  final w = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
  final x = a[0] * b[1] - a[1] * b[0] - a[2] * b[3] + a[3] * b[2];
  final y = a[0] * b[2] + a[1] * b[3] - a[2] * b[0] - a[3] * b[1];
  final z = a[0] * b[3] - a[1] * b[2] + a[2] * b[1] - a[3] * b[0];
  return 2 * math.atan2(math.sqrt(x * x + y * y + z * z), w.abs()) * 180 / math.pi;
}

void main() {
  test('reads the attitude of every frame of the Osmo 360 sample as the reference reader does', () async {
    final file = await File(_sample!).open();
    addTearDown(file.close);
    var reads = 0;
    var bytesRead = 0;
    Future<Uint8List> read(int offset, int length) async {
      reads++;
      await file.setPosition(offset);
      final bytes = await file.read(length);
      bytesRead += bytes.length;
      return bytes;
    }

    final watch = Stopwatch()..start();
    final track = await readDjiMotion(read, await file.length());
    _print('$_sample: $reads reads, $bytesRead bytes, ${watch.elapsedMilliseconds} ms');
    _print('$track');

    expect(track, isNotNull);
    expect(track!.frameTimes, hasLength(djiMotionSampleFrames));
    expect(track.frameTimes.last, closeTo(djiMotionSampleLastTime, 1e-9));
    for (final MapEntry(key: frame, value: expected) in djiMotionSampleOrientations.entries) {
      final q = [for (var k = 0; k < 4; k++) track.frameOrientations![4 * frame + k]];
      expect(_angle(q, expected), lessThan(1e-4), reason: 'frame $frame: $q');
    }
    // The frame to frame motion, as the study measured it: 0.78 degree a frame on average
    var sum = 0.0;
    for (var i = 1; i < track.frameTimes.length; i++) {
      sum += _angle(
        [for (var k = 0; k < 4; k++) track.frameOrientations![4 * (i - 1) + k]],
        [for (var k = 0; k < 4; k++) track.frameOrientations![4 * i + k]],
      );
    }
    _print('mean step ${(sum / (track.frameTimes.length - 1)).toStringAsFixed(3)} degrees a frame');
  }, skip: _sample == null ? 'Set IMMUCH_DJI_MOTION_SAMPLE to the Osmo 360 sample' : false);
}
