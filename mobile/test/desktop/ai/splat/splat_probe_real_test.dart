// splat_probe (test/desktop/ai/tools/splat_probe.dart, lot SP6), the program that makes a splat scene through the
// engine of the app on a PC, compiled by `dart compile exe` (IMMUCH360_SPLAT_SCENE_PROBE) and run here on the fake
// COLMAP and the fake Brush (IMMUCH360_FAKE_COLMAP, IMMUCH360_FAKE_BRUSH, compiled the same way): the components
// installed once from a mirror, each archive checked against its SHA-256 and refused when it differs, its licences
// there; a scene made to the .spz the probe of the app accepts; and the probe killed during the training, as
// taskkill /F kills it on the PC: Brush goes with it (the job object on Windows, immuch360-run on Linux). Skipped
// without the programs; the test job on Linux and the windows job of the desktop workflow compile them.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:path/path.dart' as p;

final _probe = Platform.environment['IMMUCH360_SPLAT_SCENE_PROBE'] ?? '';
final _colmap = Platform.environment['IMMUCH360_FAKE_COLMAP'] ?? '';
final _brush = Platform.environment['IMMUCH360_FAKE_BRUSH'] ?? '';
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];

Object _skip() => _probe.isEmpty || _colmap.isEmpty || _brush.isEmpty
    ? 'IMMUCH360_SPLAT_SCENE_PROBE, IMMUCH360_FAKE_COLMAP and IMMUCH360_FAKE_BRUSH name no programs'
    : (!Platform.isWindows && (_launcher == null || _launcher!.isEmpty)
          ? 'IMMUCH360_RUN_LAUNCHER names no launcher'
          : false);

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('splat-probe-'));
  tearDown(() {
    for (var k = 0; k < 20; k++) {
      try {
        folder.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });

  final system = Platform.isWindows ? 'win' : 'linux';
  final exe = Platform.isWindows ? '.exe' : '';

  /// A mirror with the fakes as the archives of COLMAP and Brush, their licences in them, and its SHA256SUMS
  Directory mirror() {
    final mirror = Directory(p.join(folder.path, 'mirror'))..createSync();
    final sums = StringBuffer();
    for (final (asset, program, name) in [
      ('colmap-cpu-$system-x64.zip', _colmap, 'colmap$exe'),
      ('brush-vulkan-$system-x64.zip', _brush, 'brush_app$exe'),
    ]) {
      final archive = Archive()
        ..add(ArchiveFile.bytes(name, File(program).readAsBytesSync())..mode = 493)
        ..add(ArchiveFile.string('licenses/LICENSE.txt', 'The licence of $name'));
      final bytes = ZipEncoder().encodeBytes(archive);
      File(p.join(mirror.path, asset)).writeAsBytesSync(bytes);
      sums.writeln('${sha256.convert(bytes)}  $asset');
    }
    File(p.join(mirror.path, 'SHA256SUMS')).writeAsStringSync('$sums');
    return mirror;
  }

  /// 24 photos of 64 x 48, each its own tone
  Directory photos() {
    final photos = Directory(p.join(folder.path, 'photos'))..createSync();
    for (var k = 0; k < 24; k++) {
      File(
        p.join(photos.path, 'IMG_${1000 + k}.jpg'),
      ).writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(k * 7, 80, 60))));
    }
    return photos;
  }

  List<Map<String, Object?>> events(ProcessResult result) => [
    for (final line in LineSplitter.split('${result.stdout}'))
      if (line.startsWith('{')) jsonDecode(line) as Map<String, Object?>,
  ];

  test('the components installed once from the mirror, each checked against its sum, its licences there', () {
    final components = p.join(folder.path, 'components');
    final from = mirror();
    final first = Process.runSync(_probe, ['install', '--mirror', from.path, '--components', components]);
    expect(first.exitCode, 0, reason: '${first.stdout}${first.stderr}');
    expect(events(first).map((event) => (event['event'], event['already'])), [
      ('installed', false),
      ('installed', false),
    ]);
    expect(File(p.join(components, 'engines', 'colmap-cpu-$system-x64', 'colmap$exe')).existsSync(), isTrue);
    expect(
      File(p.join(components, 'engines', 'brush-vulkan-$system-x64', 'licenses', 'LICENSE.txt')).existsSync(),
      isTrue,
    );

    final again = Process.runSync(_probe, ['install', '--mirror', from.path, '--components', components]);
    expect(events(again).map((event) => event['already']), [true, true]);

    // An archive whose bytes are not those of its sum is never unpacked
    final brush = File(p.join(from.path, 'brush-vulkan-$system-x64.zip'));
    brush.writeAsBytesSync([...brush.readAsBytesSync(), 0]);
    final tampered = Process.runSync(_probe, ['install', '--mirror', from.path, '--components', components]);
    expect(tampered.exitCode, 1);
    expect(events(tampered).last['message'], contains('brush-vulkan-$system-x64.zip'));
  }, skip: _skip());

  test('a scene from the photos to the .spz the probe of the app accepts, and its .ply', () async {
    final components = p.join(folder.path, 'components');
    Process.runSync(_probe, ['install', '--mirror', mirror().path, '--components', components]);
    final out = p.join(folder.path, 'out');
    final result = await Process.run(_probe, [
      'run',
      '--components',
      components,
      '--photos',
      photos().path,
      '--out',
      out,
      '--name',
      'salon',
      '--work-root',
      p.join(folder.path, 'work'),
      '--steps',
      '1000',
      '--max-gaussians',
      '3000',
      '--card',
      'fake-rtx',
      '--ply',
      if (_launcher != null && _launcher!.isNotEmpty) ...['--launcher', _launcher!],
      '--env',
      'IMMUCH360_FAKE_COLMAP_STEP_MS=0',
      '--env',
      'IMMUCH360_FAKE_BRUSH_STEP_MS=0',
    ]);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final done = events(result).last;
    expect(done['event'], 'done');
    expect(done['spzHead'], contains('spz'));
    expect(done['spzHead'], contains('2000'));
    expect(done['gaussians'], 2000);
    expect(File(p.join(out, 'salon_splat.spz')).existsSync(), isTrue);
    expect(File(p.join(out, 'salon_splat.ply')).existsSync(), isTrue);
    expect(events(result).where((event) => event['event'] == 'stage').map((event) => event['stage']), [
      'reading',
      'photos',
      'features',
      'matching',
      'mapping',
      'training',
      'splatCopy',
    ]);
  }, skip: _skip());

  test('the probe killed during the training, as taskkill /F does: Brush goes with it', () async {
    final pid = File(p.join(folder.path, 'brush.pid'));
    final probe = await Process.start(_probe, [
      'run',
      '--colmap',
      _colmap,
      '--brush',
      _brush,
      '--photos',
      photos().path,
      '--out',
      p.join(folder.path, 'out'),
      '--work-root',
      p.join(folder.path, 'work'),
      '--steps',
      '20000',
      '--card',
      'fake-rtx',
      if (_launcher != null && _launcher!.isNotEmpty) ...['--launcher', _launcher!],
      '--env',
      'IMMUCH360_FAKE_COLMAP_STEP_MS=0',
      '--env',
      'IMMUCH360_FAKE_BRUSH_MODE=slow',
      '--env',
      'IMMUCH360_FAKE_BRUSH_PID=${pid.path}',
    ]);
    final training = Completer<void>();
    final lines = probe.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.contains('"stage":"training"') && line.contains('"step":201') && !training.isCompleted) {
        training.complete();
      }
    });
    unawaited(probe.stderr.drain<void>());
    await training.future.timeout(const Duration(seconds: 60));
    final brush = int.parse(pid.readAsStringSync());
    expect(processImageOf(brush), isNotNull);

    probe.kill(ProcessSignal.sigkill);
    await probe.exitCode;
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (processImageOf(brush) != null && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await lines.cancel();
    expect(processImageOf(brush), isNull, reason: 'Brush went with the probe');
  }, skip: _skip());
}
