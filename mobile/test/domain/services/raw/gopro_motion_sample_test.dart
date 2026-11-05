// Reads the motion track of real GoPro videos of the development machine and prints what it gives:
// IMMUCH_GOPRO_MOTION_SAMPLES=/path/a.360:/path/b.mp4. The files are only read, in place. For the public GoPro MAX
// sample GS010013.360 the values are checked against gpmf.py of the study of 5 November 2026 (an independent decoder).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/camera_motion.dart';
import 'package:immich_mobile/domain/services/raw/gopro_motion.dart';

final _samples = Platform.environment['IMMUCH_GOPRO_MOTION_SAMPLES'];

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

List<double> _sums(Float32List values, int width) {
  final sums = List.filled(width, 0.0);
  for (var i = 0; i < values.length; i++) {
    sums[i % width] += values[i];
  }
  return sums;
}

void main() {
  for (final path in (_samples ?? '').split(':').where((path) => path.isNotEmpty)) {
    test('reads the motion track of $path', () async {
      final file = await File(path).open();
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
      final track = await readGoProMotion(read, await file.length());
      _print('$path: $reads reads, $bytesRead bytes, ${watch.elapsedMilliseconds} ms');
      _print('$track');
      expect(track, isNotNull);
      track!;
      expect(track.source, CameraMotionSource.goProGpmf);
      final times = track.frameTimes;
      for (var i = 1; i < times.length; i++) {
        expect(times[i], greaterThan(times[i - 1]));
      }
      final orientationSums = _sums(track.frameOrientations!, 4);
      final gravitySums = track.frameGravity == null ? null : _sums(track.frameGravity!, 3);
      _print('frames ${times.length}, last at ${times.last} s, sums of CORI $orientationSums, of GRAV $gravitySums');

      if (path.endsWith('GS010013.360')) {
        // gpmf.py: 595 CORI and GRAV entries for 596 frames, their sums, and the last entries
        expect(track.cameraModel, 'GoPro Max');
        expect(track.firmware, 'H19.03.01.30.00');
        expect(track.timeOrigin, CameraMotionTimeOrigin.firstFrame);
        expect(track.truncated, isFalse);
        expect(times.length, 595);
        expect(times.last, closeTo(594 * 3003 / 90000, 1e-9));
        const expectedOrientationSums = [470.0521256141828, 37.556535538804205, 23.224585711233807, -8.011963255714617];
        const expectedGravitySums = [5.998962370677847, 90.19397564622892, 286.107852412488];
        for (var k = 0; k < 4; k++) {
          expect(orientationSums[k], closeTo(expectedOrientationSums[k], 1e-4));
        }
        for (var k = 0; k < 3; k++) {
          expect(gravitySums![k], closeTo(expectedGravitySums[k], 1e-4));
        }
        const last = [0.9943235572374646, 0.054414502395702995, -0.0838038270210883, -0.03668324839014862];
        const middle = [0.13428144169438766, 0.007263405255287332, 0.989165929136021, -0.05859553819391461];
        for (var k = 0; k < 4; k++) {
          expect(track.frameOrientations![4 * 594 + k], closeTo(last[k], 1e-7));
          expect(track.frameOrientations![4 * 300 + k], closeTo(middle[k], 1e-7));
        }
        const lastGravity = [-0.05191198461867123, 0.17877742851039155, 0.9825128940702537];
        for (var k = 0; k < 3; k++) {
          expect(track.frameGravity![3 * 594 + k], closeTo(lastGravity[k], 1e-7));
        }
        expect(track.frameExposures.length, 595);
        for (final exposure in track.frameExposures) {
          expect(exposure, inInclusiveRange(0.000265, 0.000307));
        }
        // The top level boxes, the moov box, then the 20 payloads
        expect(reads, lessThanOrEqualTo(24));
      }
    });
  }

  test('needs real files', () {}, skip: _samples == null ? 'Set IMMUCH_GOPRO_MOTION_SAMPLES to GoPro videos' : false);
}
