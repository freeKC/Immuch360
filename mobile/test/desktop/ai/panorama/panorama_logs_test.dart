// The logs a 360° panorama that failed leaves in the logs folder of the app (panorama_logs.dart, release 44): the name
// of the file, without the colons Windows refuses; the header and the last 256 KiB of a long log; nothing when the job
// wrote no log; the five newest kept by the date in their names, the logs of the splat scenes and the other files left
// alone.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_logs.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  late Directory work;
  late Directory logs;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('panorama_logs_test_');
    work = Directory(p.join(folder.path, 'work', 'conversion-1'))..createSync(recursive: true);
    logs = Directory(p.join(folder.path, 'logs'));
  });
  tearDown(() => folder.deleteSync(recursive: true));

  /// A log a program of the job wrote into its work folder
  File programLog(String name, String text) {
    final programs = Directory(p.join(work.path, 'logs'))..createSync(recursive: true);
    return File(p.join(programs.path, name))..writeAsStringSync(text);
  }

  List<String> namesIn(Directory directory) {
    final names = [for (final entry in directory.listSync()) p.basename(entry.path)];
    return names..sort();
  }

  test('the name: the job, then the date and the time without colons', () {
    final at = DateTime(2026, 11, 8, 7, 5, 9);
    expect(panoramaFailureLogName('conversion-12', at), 'panorama-conversion-12-2026-11-08T07-05-09.log');
    expect(panoramaFailureLogName('a:b/c d', at), 'panorama-a_b_c_d-2026-11-08T07-05-09.log');
    expect(panoramaFailureLogName('conversion-12', at), isNot(contains(':')));
  });

  test('the header, then the last 256 KiB of a long log; nothing when the job wrote no log', () async {
    expect(await keepPanoramaFailureLogs(work, logs, jobId: 'conversion-1', header: 'Nothing'), isNull);
    expect(logs.existsSync(), isFalse);

    final lines = [for (var line = 0; line < 40000; line++) 'line ${'$line'.padLeft(5, '0')} of sd-cli'];
    final log = programLog('sd-cli.log', '${lines.join('\n')}\n');
    final kept = await keepPanoramaFailureLogs(
      work,
      logs,
      jobId: 'conversion-1',
      header: 'Panorama conversion-1 (salon.jpg) failed: generatorStalled',
      now: DateTime(2026, 11, 8, 17, 7, 12),
    );

    expect(p.basename(kept!.path), 'panorama-conversion-1-2026-11-08T17-07-12.log');
    final text = kept.readAsStringSync();
    expect(text, startsWith('Panorama conversion-1 (salon.jpg) failed: generatorStalled\nWork folder: ${work.path}\n'));
    expect(text, contains('===== sd-cli.log, ${log.lengthSync()} bytes, the last $panoramaFailureLogTail ====='));
    expect(text, endsWith('line 39999 of sd-cli\n'));
    expect(text, isNot(contains('line 00000 of sd-cli')));
    expect(text.length, lessThan(panoramaFailureLogTail + 1024));
    expect(panoramaFailureLogTail, 256 * 1024);
  });

  test('the five newest kept by the date in their names; the logs of the splat scenes and other files left', () async {
    programLog('sd-cli.log', 'one run\n');
    logs.createSync(recursive: true);
    final splat = File(p.join(logs.path, 'splat-0123456789abcdef-2026-11-01T10-00-00.log'));
    splat.writeAsStringSync('COLMAP');
    File(p.join(logs.path, 'notes.txt')).writeAsStringSync('mine');

    for (var day = 1; day <= 7; day++) {
      final kept = await keepPanoramaFailureLogs(
        work,
        logs,
        jobId: 'conversion-$day',
        header: 'Panorama conversion-$day failed',
        now: DateTime(2026, 11, day, 12),
      );
      expect(kept, isNotNull);
    }

    expect(namesIn(logs), [
      'notes.txt',
      'panorama-conversion-3-2026-11-03T12-00-00.log',
      'panorama-conversion-4-2026-11-04T12-00-00.log',
      'panorama-conversion-5-2026-11-05T12-00-00.log',
      'panorama-conversion-6-2026-11-06T12-00-00.log',
      'panorama-conversion-7-2026-11-07T12-00-00.log',
      'splat-0123456789abcdef-2026-11-01T10-00-00.log',
    ]);
    expect(splat.readAsStringSync(), 'COLMAP');
    expect(panoramaFailureLogsKept, 5);
  });
}
