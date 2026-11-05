// Reads the motion track of real Insta360 videos of the development machine and prints what it gives:
// IMMUCH_INSTA_MOTION_SAMPLES=/path/a.insv:/path/b.lrv. The files are only read, in place.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/raw/insta360_motion.dart';

final _samples = Platform.environment['IMMUCH_INSTA_MOTION_SAMPLES'];

void _print(String line) {
  // ignore: avoid_print
  print(line);
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
      final track = await readInsta360Motion(read, await file.length());
      _print('$path: $reads reads, $bytesRead bytes, ${watch.elapsedMilliseconds} ms');
      _print('$track');
      expect(track, isNotNull);

      final times = track!.samples.times;
      for (var i = 1; i < times.length; i++) {
        expect(times[i], greaterThan(times[i - 1]));
      }
      expect(track.sampleRate, closeTo(1000, 10));
      expect(track.frameTimes, isNotEmpty);
      expect(track.frameTimes.first.abs(), lessThan(1e-4));
      // The rotation the gyroscope turned through, summed over the whole recording, per body axis
      final rates = track.samples.rotationRates;
      final turned = [0.0, 0.0, 0.0];
      for (var i = 1; i < times.length; i++) {
        final dt = times[i] - times[i - 1];
        for (var axis = 0; axis < 3; axis++) {
          turned[axis] += rates[3 * i + axis] * dt;
        }
      }
      _print(
        'first sample ${times.first} s, last ${times.last} s, frames ${track.frameTimes.length} '
        '(last at ${track.frameTimes.last} s), integral of the rates ${turned.map((v) => v.toStringAsFixed(6))}',
      );
    });
  }

  test(
    'needs real files',
    () {},
    skip: _samples == null ? 'Set IMMUCH_INSTA_MOTION_SAMPLES to Insta360 videos' : false,
  );
}
