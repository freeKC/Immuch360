// Builds the stabilisation table of real videos of the development machine and prints what it gives, to set against
// the numpy reference of the study (b_reference.py): IMMUCH_STABILIZATION_SAMPLES=/path/a.insv:/path/b.lrv. A GoPro
// .360 goes through its GPMF track, and its levelled down is checked against GRAV at every frame; a DJI .osv through
// its attitude. The files are only read, in place.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/gopro_motion.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';

final _samples = Platform.environment['IMMUCH_STABILIZATION_SAMPLES'];

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

/// The largest angle in degrees between the display's down and where the table shows the GRAV of each frame: a check
/// that the table levels with GRAV, not of the axes of the view, which cancel out (K B^T g = T^T G^T R(q) g whatever
/// the view to GPMF rotation B); stabilization_cameras_test checks the axes against the turns of the picture
double _largestGoProLevel(StabilizationTable table, Float32List gravity) {
  var largest = 0.0;
  for (var i = 0; i < table.length && 3 * i + 2 < gravity.length; i++) {
    final down = goProViewToGpmf.transposed.apply((x: gravity[3 * i], y: gravity[3 * i + 1], z: gravity[3 * i + 2]));
    final (w, x, y, z) = (
      table.corrections[4 * i],
      table.corrections[4 * i + 1],
      table.corrections[4 * i + 2],
      table.corrections[4 * i + 3],
    );
    // The y row of the rotation of the correction, applied to the down of the camera's view
    final shownY = 2 * (x * y + w * z) * down.x + (1 - 2 * (x * x + z * z)) * down.y + 2 * (y * z - w * x) * down.z;
    final length = math.sqrt(down.x * down.x + down.y * down.y + down.z * down.z);
    if (length > 0) {
      largest = math.max(largest, math.acos((shownY / length).clamp(-1.0, 1.0)) * 180 / math.pi);
    }
  }
  return largest;
}

void main() {
  for (final path in (_samples ?? '').split(':').where((path) => path.isNotEmpty)) {
    test('builds the stabilisation table of $path', () async {
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
      final details = StabilizationDetails();
      final lower = path.toLowerCase();
      final size = await file.length();
      final table = lower.endsWith('.360')
          ? await readGoProStabilization(read, size, details: details)
          : lower.endsWith('.osv')
          ? await readDjiStabilization(read, size, details: details)
          : await readInsta360Stabilization(read, size, details: details);
      _print('$path: $reads reads, $bytesRead bytes, ${watch.elapsedMilliseconds} ms');
      expect(table, isNotNull);
      _print('${table!.summary}');
      final count = table.length;
      for (final i in [0, 1, count ~/ 2, count - 1]) {
        final q = [for (var j = 0; j < 4; j++) table.corrections[4 * i + j].toStringAsFixed(6)];
        _print('correction $i: $q');
      }
      _print('view to body: ${details.viewToBody.values.map((v) => v.toStringAsFixed(6)).toList()}');
      if (lower.endsWith('.360')) {
        final track = (await readGoProMotion(read, size))!;
        final largest = _largestGoProLevel(table, track.frameGravity!);
        _print('largest angle of GRAV from the display down: ${largest.toStringAsFixed(3)} degrees');
        expect(largest, lessThan(3));
      }
    });
  }

  test(
    'needs real files',
    () {},
    skip: _samples == null ? 'Set IMMUCH_STABILIZATION_SAMPLES to Insta360, GoPro or DJI videos' : false,
  );
}
