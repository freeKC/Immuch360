// Builds the stabilisation table of real Insta360 videos of the development machine and prints what it gives, to set
// against the numpy reference of the study (b_reference.py): IMMUCH_STABILIZATION_SAMPLES=/path/a.insv:/path/b.lrv.
// The files are only read, in place.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';

final _samples = Platform.environment['IMMUCH_STABILIZATION_SAMPLES'];

void _print(String line) {
  // ignore: avoid_print
  print(line);
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
      final table = await readInsta360Stabilization(read, await file.length(), details: details);
      _print('$path: $reads reads, $bytesRead bytes, ${watch.elapsedMilliseconds} ms');
      expect(table, isNotNull);
      _print('${table!.summary}');
      final count = table.length;
      for (final i in [0, 1, count ~/ 2, count - 1]) {
        final q = [for (var j = 0; j < 4; j++) table.corrections[4 * i + j].toStringAsFixed(6)];
        _print('correction $i: $q');
      }
      _print('view to body: ${details.viewToBody.values.map((v) => v.toStringAsFixed(6)).toList()}');
    });
  }

  test(
    'needs real files',
    () {},
    skip: _samples == null ? 'Set IMMUCH_STABILIZATION_SAMPLES to Insta360 videos' : false,
  );
}
