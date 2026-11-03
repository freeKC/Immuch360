// The runners of the splat scenes (lot SP4) on real child processes: the fake COLMAP and the fake Brush of lot SP0
// compiled by `dart compile exe` (IMMUCH360_FAKE_COLMAP, IMMUCH360_FAKE_BRUSH), started through the launcher of the
// app (ManagedProcessRunner: the job object on Windows, immuch360-run on Linux, IMMUCH360_RUN_LAUNCHER); and the probe
// of the runners compiled the same way (IMMUCH360_SPLAT_PROBE, test/desktop/ai/tools/splat_runner_probe.dart), killed
// while COLMAP or Brush runs under it: its child must go with it. Skipped without them; the test job on Linux and the
// windows job of the desktop workflow compile them.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

final _colmap = Platform.environment['IMMUCH360_FAKE_COLMAP'] ?? '';
final _brush = Platform.environment['IMMUCH360_FAKE_BRUSH'] ?? '';
final _probe = Platform.environment['IMMUCH360_SPLAT_PROBE'] ?? '';
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];

/// The launcher is needed on Linux, the job object does it on Windows
Object _skip(String program, String variable) => program.isEmpty
    ? '$variable names no program'
    : (!Platform.isWindows && (_launcher == null || _launcher!.isEmpty)
          ? 'IMMUCH360_RUN_LAUNCHER names no launcher'
          : false);

const _gib = 1024 * 1024 * 1024;

class _Memory implements MemoryProbe {
  const _Memory(this.available);

  final int available;

  @override
  MemoryFacts read() => MemoryFacts(physical: 16 * _gib, available: available);
}

/// The cards the fake Brush knows: the Intel UHD first, the RTX 4060 second, as on the PC of the measure
const _intel = GpuAdapter(
  name: 'Intel(R) RaptorLake-S Mobile Graphics Controller',
  kind: GpuKind.integrated,
  localMemory: 2 * _gib,
  vendorId: 0x8086,
  deviceId: 0xA788,
  driverVersion: '101.7088',
  vulkanIndex: 0,
);
const _rtx = GpuAdapter(
  name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
  kind: GpuKind.discrete,
  localMemory: 8 * _gib,
  vendorId: 0x10DE,
  deviceId: 0x28A0,
  driverVersion: '616.56',
  vulkanIndex: 1,
);
const _laptop = GpuReport(adapters: [_intel, _rtx]);

bool _alive(int pid) => processImageOf(pid) != null;

Future<void> _gone(int pid, {Duration within = const Duration(seconds: 5)}) async {
  final until = DateTime.now().add(within);
  while (_alive(pid) && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory folder;
  late SplatWorkFolder work;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('splat-runners-');
    work = SplatWorkFolder(Directory(p.join(folder.path, 'job')));
    cancel = NativeCancelFlag();
  });
  tearDown(() {
    cancel.free();
    // A program on Windows may hold its folder a moment after it is gone
    for (var k = 0; k < 20; k++) {
      try {
        folder.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });

  /// [count] photos of 64 x 48 in [cameras] folders of the images of the job
  void photos(int count, {int cameras = 2}) {
    final picture = img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(120, 90, 70)));
    for (var k = 1; k <= count; k++) {
      File(p.join(work.images.path, 'cam${k % cameras}', '${'$k'.padLeft(6, '0')}.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(picture);
    }
  }

  ManagedProcessRunner runner() => ManagedProcessRunner(linuxLauncher: _launcher);

  ColmapRunner colmap(String mode, {int available = 4 * _gib, Duration? stall, Map<String, String> more = const {}}) =>
      ColmapRunner(
        runner: runner(),
        colmap: _colmap,
        memory: _Memory(available),
        processors: 16,
        stallTimeout: stall ?? SplatV1.colmapSilence,
        environment: {'IMMUCH360_FAKE_COLMAP_MODE': mode, 'IMMUCH360_FAKE_COLMAP_STEP_MS': '0', ...more},
      );

  BrushRunner brush(String mode, {GpuAdapter card = _rtx, Duration? stall, Map<String, String> more = const {}}) =>
      BrushRunner(
        runner: runner(),
        brush: _brush,
        cardCheck: () async => BrushCardReady(card, _laptop),
        cacheRoot: Directory(p.join(folder.path, 'cache')),
        stallTimeout: stall ?? SplatV1.brushSilence,
        environment: {'IMMUCH360_FAKE_BRUSH_MODE': mode, 'IMMUCH360_FAKE_BRUSH_STEP_MS': '0', ...more},
      );

  const quick = SplatSettings(steps: 1000, maxGaussians: 3000);

  group('COLMAP', () {
    test('30 photos of two cameras placed, the model upright and read, every step told', () async {
      photos(30);
      final progress = <ColmapProgress>[];
      final poses = await colmap('ok').poses(work, images: 30, video: false, cancel: cancel, onProgress: progress.add);
      expect((poses.images, poses.placed, poses.partial), (30, 30, false));
      expect(poses.model.cameras, hasLength(2));
      expect(poses.model.images.map((image) => image.name), contains('cam1/000001.jpg'));
      expect(poses.model.meanReprojectionError, closeTo(0.66, 1e-9));
      expect(
        progress.where((x) => x.stage == ImmersiveStage.features).last,
        const ColmapProgress(ImmersiveStage.features, 30, 30),
      );
      // 30 images in blocks of 50: one block
      expect(progress.where((x) => x.stage == ImmersiveStage.matching).map((x) => (x.done, x.total)), [(1, 1)]);
      expect(progress.where((x) => x.stage == ImmersiveStage.mapping).last.done, 30);
      for (final name in ['colmap-features', 'colmap-matching', 'colmap-mapping', 'colmap-align']) {
        expect(work.logOf(name).readAsStringSync(), contains('Elapsed time:'), reason: name);
      }
      expect(File(p.join(work.aligned.path, 'images.bin')).existsSync(), isTrue);
    }, skip: _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'));

    test('a video: every pair of its frames matched, one camera', () async {
      photos(24, cameras: 1);
      final progress = <ColmapProgress>[];
      final poses = await colmap('ok').poses(work, images: 24, video: true, cancel: cancel, onProgress: progress.add);
      expect(poses.model.cameras, hasLength(1));
      expect(progress.where((x) => x.stage == ImmersiveStage.matching).map((x) => (x.done, x.total)), [(1, 1)]);
      expect(work.logOf('colmap-matching').readAsStringSync(), contains('Generating exhaustive image pairs...'));
    }, skip: _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'));

    test('a video of 210 frames: the list of its pairs, every name one COLMAP holds, matched by matches_importer; its '
        'work folder under a root with a space (lot SPF2: the path of the list is one argument)', () async {
      work = SplatWorkFolder(Directory(p.join(folder.path, 'work dir', 'job')));
      photos(210, cameras: 1);
      final progress = <ColmapProgress>[];
      final poses = await colmap('ok').poses(work, images: 210, video: true, cancel: cancel, onProgress: progress.add);
      expect(poses.placed, 210);
      final pairs = colmapVideoPairs(210).length;
      expect(work.pairs.readAsLinesSync(), hasLength(pairs));
      final blocks = (pairs + 1224) ~/ 1225;
      expect(progress.where((x) => x.stage == ImmersiveStage.matching).map((x) => (x.done, x.total)), [
        for (var b = 1; b <= blocks; b++) (b, blocks),
      ]);
      final log = work.logOf('colmap-matching').readAsStringSync();
      expect(log, contains('Importing image pairs...'));
      expect(log, isNot(contains('does not exist')));
      expect(work.pairs.path, contains('work dir'));
    }, skip: _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'));

    test('two models: the largest; 70 % placed: partial; a fifth, or two fifths under 20: refused; no pair: refused '
        'with none; two fifths of 60: incomplete', () async {
      photos(30);
      final split = await colmap('split').poses(work, images: 30, video: false, cancel: cancel);
      expect(split.placed, 26);
      final partial = await colmap('partial').poses(work, images: 30, video: false, cancel: cancel);
      expect((partial.placed, partial.incomplete, partial.partial), (21, false, true));
      for (final (mode, counts) in [('few', '6/30'), ('incomplete', '12/30'), ('nomodel', '0/30')]) {
        await expectLater(
          colmap(mode).poses(work, images: 30, video: false, cancel: cancel),
          throwsA(
            isA<BackendException>()
                .having((e) => e.code, 'code', ImmersiveErrorCode.notEnoughOverlap)
                .having((e) => e.message, 'message', counts),
          ),
          reason: mode,
        );
      }
      // 24 of 60: more than 20 and than 30 %, fewer than half: made, said maybe incomplete
      photos(60);
      final incomplete = await colmap('incomplete').poses(work, images: 60, video: false, cancel: cancel);
      expect((incomplete.placed, incomplete.incomplete, incomplete.partial), (24, true, true));
    }, skip: _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'));

    test('the extraction crashes at 10 and 5 threads, passes at 2: the real exit code of a crash read', () async {
      photos(30);
      final poses = await colmap(
        'memory',
        available: 4 * _gib + _gib ~/ 2,
        more: {'IMMUCH360_FAKE_COLMAP_THREADS': '2'},
      ).poses(work, images: 30, video: false, cancel: cancel);
      expect(poses.threads, 2);
      expect(poses.placed, 30);
      // The crashes are in the log of the extraction
      expect(
        RegExp('=== Feature extraction ===').allMatches(work.logOf('colmap-features').readAsStringSync()),
        hasLength(3),
      );
    }, skip: _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'));

    test(
      'a check of COLMAP that fails is posesFailed, never outOfMemory: once more on Windows, at once elsewhere',
      () async {
        photos(30);
        // 0xC0000409 and not a word on Windows, as our build was measured on 1 November; elsewhere SIGABRT after the
        // words of libstdc++
        final code = Platform.isWindows ? -1073740791 : -ProcessSignal.sigabrt.signalNumber;
        await expectLater(
          colmap('abort', available: 4 * _gib + _gib ~/ 2).poses(work, images: 30, video: false, cancel: cancel),
          throwsA(
            isA<BackendException>()
                .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
                .having((e) => e.message, 'message', startsWith('COLMAP (feature_extractor) aborted with $code: ')),
          ),
        );
        // Started again once with half the threads on Windows, where a std::bad_alloc says nothing either
        expect(
          RegExp('=== Feature extraction ===').allMatches(work.logOf('colmap-features').readAsStringSync()),
          hasLength(Platform.isWindows ? 2 : 1),
        );
      },
      skip: _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'),
    );

    test('a failure is posesFailed with the line of COLMAP; silent, it is stopped as posesStalled', () async {
      photos(30);
      await expectLater(
        colmap('fail').poses(work, images: 30, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.message, 'message', contains('database disk image is malformed')),
        ),
      );
      final watch = Stopwatch()..start();
      await expectLater(
        colmap('silent', stall: const Duration(seconds: 2)).poses(work, images: 30, video: false, cancel: cancel),
        throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.posesStalled)),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    }, skip: _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'));
  });

  group('Brush', () {
    Future<void> poses() async {
      photos(30);
      await colmap('ok').poses(work, images: 30, video: false, cancel: cancel);
    }

    test('trains the dataset COLMAP aligned on the card of the gate: its export, every 200 steps', () async {
      await poses();
      final progress = <BrushProgress>[];
      final result = await brush('ok').train(work, settings: quick, cancel: cancel, onProgress: progress.add);
      expect(result.ply.path, p.join(work.export.path, 'export_1000.ply'));
      expect(utf8.decode(result.ply.readAsBytesSync().sublist(0, 3)), 'ply');
      expect(result.adapter!.name, _rtx.name);
      expect(progress.map((x) => x.step), [201, 401, 601, 801, 1000]);
      expect(result.views, 30);
      // The autotune cache of the RTX in the folder of the RTX, never in the job
      expect(
        Directory(
          p.join(brushCacheFolderOf(Directory(p.join(folder.path, 'cache')), _rtx).path, 'target'),
        ).existsSync(),
        isTrue,
      );
      expect(Directory(p.join(work.root.path, 'target')).existsSync(), isFalse);
    }, skip: _skip(_brush, 'IMMUCH360_FAKE_BRUSH'));

    test('the Intel and the RTX each in their folder: both train, neither finds the cache of the other', () async {
      await poses();
      await brush('ok', card: _intel).train(work, settings: quick, cancel: cancel);
      final result = await brush('ok').train(work, settings: quick, cancel: cancel);
      expect(result.adapter!.type, 'DiscreteGpu');
      await brush('ok', card: _intel).train(work, settings: quick, cancel: cancel);
    }, skip: _skip(_brush, 'IMMUCH360_FAKE_BRUSH'));

    test(
      'the panic of the Intel UHD is stopped at once, not after the 30 s Windows Error Reporting holds it',
      () async {
        await poses();
        final watch = Stopwatch()..start();
        await expectLater(
          brush(
            'planes',
            more: {'IMMUCH360_FAKE_BRUSH_PANIC_HOLD_MS': '30000'},
          ).train(work, settings: quick, cancel: cancel),
          throwsA(
            isA<BackendException>()
                .having((e) => e.code, 'code', ImmersiveErrorCode.gpuUnavailable)
                .having((e) => e.message, 'message', contains('plane instructions')),
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      },
      skip: _skip(_brush, 'IMMUCH360_FAKE_BRUSH'),
    );

    test(
      'a memory of the card too short is gpuOutOfMemory; an error trainingFailed; silent, trainingStalled',
      () async {
        await poses();
        await expectLater(
          brush('oom').train(work, settings: quick, cancel: cancel),
          throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.gpuOutOfMemory)),
        );
        await expectLater(
          brush('fail').train(work, settings: quick, cancel: cancel),
          throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.trainingFailed)),
        );
        await expectLater(
          brush('silent', stall: const Duration(seconds: 2)).train(work, settings: quick, cancel: cancel),
          throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.trainingStalled)),
        );
      },
      skip: _skip(_brush, 'IMMUCH360_FAKE_BRUSH'),
    );

    test('cancelled while it trains, Brush is gone within a second', () async {
      await poses();
      int? pid;
      final training = brush(
        'slow',
        more: {'IMMUCH360_FAKE_BRUSH_STEP_MS': '2000'},
      ).train(work, settings: quick, cancel: cancel, onStarted: (started) => pid = started);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(pid, isNotNull);
      expect(_alive(pid!), isTrue);
      final watch = Stopwatch()..start();
      cancel.cancel();
      await expectLater(
        training,
        throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled)),
      );
      await _gone(pid!);
      expect(_alive(pid!), isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    }, skip: _skip(_brush, 'IMMUCH360_FAKE_BRUSH'));
  });

  group('the host killed', () {
    Future<void> killedTakes(List<String> arguments, Map<String, String> environment) async {
      final pidFile = File(p.join(folder.path, 'child.pid'));
      final host = await Process.start(_probe, [
        ...arguments,
        '--pid-file',
        pidFile.path,
        if (_launcher != null && !Platform.isWindows) ...['--launcher', _launcher!],
      ], environment: environment);
      final output = StringBuffer();
      unawaited(host.stdout.transform(utf8.decoder).forEach(output.write));
      unawaited(host.stderr.transform(utf8.decoder).forEach(output.write));
      final until = DateTime.now().add(const Duration(seconds: 30));
      while (!(pidFile.existsSync() && pidFile.readAsStringSync().isNotEmpty) && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(pidFile.existsSync(), isTrue, reason: '$output');
      final child = int.parse(pidFile.readAsStringSync());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(_alive(child), isTrue, reason: '$output');
      host.kill(ProcessSignal.sigkill);
      await host.exitCode;
      await _gone(child);
      expect(_alive(child), isFalse, reason: 'the child of the host killed is still there');
    }

    test('the host of COLMAP killed, COLMAP goes with it', () async {
      photos(30);
      await killedTakes(
        ['host-colmap', '--colmap', _colmap, '--work', work.root.path],
        {'IMMUCH360_FAKE_COLMAP_MODE': 'silent'},
      );
    }, skip: _probe.isEmpty ? 'IMMUCH360_SPLAT_PROBE names no probe' : _skip(_colmap, 'IMMUCH360_FAKE_COLMAP'));

    test('the host of Brush killed, Brush goes with it', () async {
      work.dataset.createSync(recursive: true);
      await killedTakes(
        [
          'brush',
          '--brush',
          _brush,
          '--work',
          work.root.path,
          '--cache',
          p.join(folder.path, 'cache'),
          '--card',
          'fake-rtx',
        ],
        {'IMMUCH360_FAKE_BRUSH_MODE': 'silent'},
      );
    }, skip: _probe.isEmpty ? 'IMMUCH360_SPLAT_PROBE names no probe' : _skip(_brush, 'IMMUCH360_FAKE_BRUSH'));
  });
}
