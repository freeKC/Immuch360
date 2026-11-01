// The runner of Brush (lib/desktop/ai/splat/brush_runner.dart, lot SP4) with the fake runner: its frozen arguments
// against the help of brush_app 0.3.0 (brush_help.txt of lot SP2), the card named to cubecl, the folder of each card for
// the autotune cache, the "Using adapter" line checked, the progress of the room of M1 every 200 steps, the wait for the
// memory of the card, the panics of the Intel UHD (fixtures of lot SP2) and of a memory too short stopped at once, the
// other failures, a work folder that refuses its files, the silence of 300 s, the cancel flag, and the images
// lengthened for Brush 0.3.0. The answer of the budget of the app for Brush is in gpu_budget_test.dart; the same runner
// against the compiled fake Brush is splat_runners_real_test.dart.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_process_runner.dart';

const _gib = 1024 * 1024 * 1024;

/// The cards of the laptop of FreeKC as the probe reads them: the Intel first, the RTX second
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
  budget: 7 * _gib,
  usage: _gib,
);
const _laptop = GpuReport(adapters: [_intel, _rtx], instanceVersion: '1.4.309');

String _fixture(String name) => File(p.join('test', 'fixtures', name)).readAsStringSync();

List<(String, {bool isError})> _out(String text) => [
  for (final line in text.split(RegExp(r'\r?\n')))
    if (line.isNotEmpty) (line, isError: false),
];

List<(String, {bool isError})> _err(String text) => [
  for (final line in text.split(RegExp(r'\r?\n'))) (line, isError: true),
];

/// The lines of the training of the room by M1 (20 000 steps, 99 lines of refinement), the card it took first
List<(String, {bool isError})> _training() => [
  ..._out(_fixture('splat/logs/b4-2k-adapter.out')),
  ..._out(_fixture('splat/logs/m1-room1024.out')),
];

/// The fake runner, writing the export of Brush when the script ends well
class _BrushRunner implements ProcessRunner {
  _BrushRunner(this.scripts);

  final List<FakeProcessScript> scripts;
  final launches = <ProcessLaunch>[];
  final processes = <FakeRunningProcess>[];
  var _pid = 9000;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    launches.add(launch);
    final script = scripts.length > 1 ? scripts.removeAt(0) : scripts.single;
    final arguments = launch.arguments;
    if (script.exitCode == 0 && !script.hangs) {
      final steps = arguments[arguments.indexOf('--total-steps') + 1];
      File(p.join(arguments[arguments.indexOf('--export-path') + 1], 'export_$steps.ply')).writeAsStringSync('ply\n');
    }
    final process = FakeRunningProcess(++_pid, launch, script);
    processes.add(process);
    return process;
  }
}

/// The options of brush_app 0.3.0, with "--"
Set<String> _brushOptions() => {
  for (final line in _fixture('ai_immersive/brush_help.txt').split(RegExp(r'\r?\n')))
    for (final match in RegExp(r'^\s+(?:-\w, )?(--[a-z-]+)').allMatches(line)) match.group(1)!,
};

void main() {
  late Directory folder;
  late SplatWorkFolder work;
  late Directory cache;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('brush-runner-');
    work = SplatWorkFolder(Directory(p.join(folder.path, 'job')));
    work.images.createSync(recursive: true);
    work.aligned.createSync(recursive: true);
    cache = Directory(p.join(folder.path, 'autotune'));
    cancel = NativeCancelFlag();
  });
  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  BrushRunner brush(ProcessRunner runner, {BrushCardCheck? check, Duration Function()? elapsed}) => BrushRunner(
    runner: runner,
    brush: '/engines/brush-vulkan-linux-x64/brush_app',
    cardCheck: check ?? () async => const BrushCardReady(_rtx, _laptop),
    cacheRoot: cache,
    elapsed: elapsed,
  );

  Future<BrushResult> train(
    BrushRunner runner, {
    void Function(BrushProgress)? onProgress,
    void Function(int)? onWaiting,
  }) =>
      runner.train(work, settings: const SplatSettings(), cancel: cancel, onProgress: onProgress, onWaiting: onWaiting);

  group('the launch', () {
    test('the arguments are frozen: every option one brush_app 0.3.0 lists, with the values of splat-v1', () {
      final arguments = brushArguments(
        dataset: '/job/dataset',
        export: '/job/brush',
        steps: 20000,
        maxGaussians: 150000,
        shDegree: 3,
        resolution: 1024,
      );
      expect(arguments, [
        '/job/dataset',
        '--total-steps',
        '20000',
        '--max-splats',
        '150000',
        '--sh-degree',
        '3',
        '--max-resolution',
        '1024',
        '--export-every',
        '20000',
        '--export-path',
        '/job/brush',
        '--export-name',
        'export_{iter}.ply',
      ]);
      final listed = _brushOptions();
      expect(listed, containsAll(['--total-steps', '--max-splats', '--with-viewer', '--rerun-enabled']));
      for (final option in arguments.where((a) => a.startsWith('--'))) {
        expect(listed, contains(option));
      }
      // No view held out, no viewer, no rerun, no LPIPS
      for (final absent in ['--eval-split-every', '--with-viewer', '--rerun-enabled', '--lpips-loss-weight']) {
        expect(arguments, isNot(contains(absent)));
      }
      expect(brushIn('/e', windows: true), p.join('/e', 'brush_app.exe'));
      expect(brushExportOf(Directory('/job/brush'), 20000).path, p.join('/job/brush', 'export_20000.ply'));
    });

    test('the card is named to cubecl by its rank among the cards of its kind Vulkan lists', () {
      expect(cubeclDeviceOf(_laptop, _rtx), 'DiscreteGpu(0)');
      expect(cubeclDeviceOf(_laptop, _intel), 'IntegratedGpu(0)');
      const second = GpuAdapter(name: 'RTX 5090', kind: GpuKind.discrete, localMemory: 32 * _gib, vulkanIndex: 3);
      const desktop = GpuReport(adapters: [second, _intel, _rtx]);
      expect(cubeclDeviceOf(desktop, second), 'DiscreteGpu(1)');
      expect(cubeclDeviceOf(desktop, _rtx), 'DiscreteGpu(0)');
      // An adapter of DXGI only, and lavapipe, are no card of cubecl
      const dxgi = GpuAdapter(name: 'Basic Render', kind: GpuKind.discrete, localMemory: 0, source: 'dxgi');
      const lavapipe = GpuAdapter(name: 'llvmpipe', kind: GpuKind.cpu, localMemory: _gib, vulkanIndex: 2);
      expect(cubeclDeviceOf(const GpuReport(adapters: [dxgi, _rtx]), dxgi), isNull);
      expect(cubeclDeviceOf(const GpuReport(adapters: [lavapipe]), lavapipe), isNull);
    });

    test('each card, and each driver, has its own working folder for the autotune cache of cubecl', () {
      final root = Directory('/cache');
      expect(p.basename(brushCacheFolderOf(root, _rtx).path), 'nvidia-geforce-rtx-4060-laptop-gpu-10de-28a0-616.56');
      expect(
        p.basename(brushCacheFolderOf(root, _intel).path),
        'intel-r-raptorlake-s-mobile-graphics-controller-8086-a788-101.7088',
      );
      const updated = GpuAdapter(
        name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
        kind: GpuKind.discrete,
        localMemory: 8 * _gib,
        vendorId: 0x10DE,
        deviceId: 0x28A0,
        driverVersion: '620.02',
      );
      expect(brushCacheFolderOf(root, updated).path, isNot(brushCacheFolderOf(root, _rtx).path));
      expect(p.dirname(brushCacheFolderOf(root, _rtx).path), root.path);
    });

    test('the "Using adapter" line of the measure names the RTX, which is the card of the gate and not the Intel', () {
      final adapter = brushAdapterOf(_fixture('splat/logs/b4-2k-adapter.out').trim())!;
      expect(
        (adapter.name, adapter.vendor, adapter.device, adapter.type),
        ('NVIDIA GeForce RTX 4060 Laptop GPU', 4318, 10400, 'DiscreteGpu'),
      );
      expect(brushTook(adapter, _rtx), isTrue);
      expect(brushTook(adapter, _intel), isFalse);
      final intel = brushAdapterOf(_fixture('ai_immersive/brush_igpu_plane_failure_stdout.txt').split('\n').first)!;
      expect((intel.vendor, intel.device, intel.type), (32902, 42888, 'IntegratedGpu'));
      expect(brushTook(intel, _rtx), isFalse);
      expect(brushTook(intel, _intel), isTrue);
      // Without the ids of the probe, the name says it
      const named = GpuAdapter(name: 'nvidia geforce rtx 4060 laptop gpu ', kind: GpuKind.discrete, localMemory: 0);
      expect(brushTook(adapter, named), isTrue);
      // The line of the compute server repeats the card after "=>": not the line of the choice
      expect(
        brushAdapterOf('Created wgpu compute server on device Device { ... } => AdapterInfo { name: "X" }'),
        isNull,
      );
    });
  });

  group('a training', () {
    test('the room of M1: the card named, its own folder, every 200 steps to 20 000, its export', () async {
      final runner = _BrushRunner([FakeProcessScript(lines: _training())]);
      final progress = <BrushProgress>[];
      int? pid;
      final result = await brush(runner).train(
        work,
        settings: const SplatSettings(),
        cancel: cancel,
        onProgress: progress.add,
        onStarted: (started) => pid = started,
      );
      final launch = runner.launches.single;
      expect(launch.executable, '/engines/brush-vulkan-linux-x64/brush_app');
      expect(launch.arguments.first, work.dataset.path);
      expect(launch.arguments, containsAllInOrder(['--export-path', work.export.path]));
      expect(launch.environment, {
        'RUST_LOG': 'brush_cli=info,brush_process=info,cubecl_wgpu=info',
        'RUST_BACKTRACE': '0',
        'CUBECL_WGPU_DEFAULT_DEVICE': 'DiscreteGpu(0)',
      });
      expect(launch.workingDirectory, brushCacheFolderOf(cache, _rtx).path);
      expect(Directory(launch.workingDirectory!).existsSync(), isTrue);
      expect(launch.lowPriority, isTrue);
      expect(pid, runner.processes.single.pid);
      expect(progress.map((x) => x.step), [for (var k = 201; k < 20000; k += 200) k, 20000]);
      expect(progress.map((x) => x.steps).toSet(), {20000});
      expect(progress.first.splats, 31583);
      expect(progress.last.splats, 150000);
      expect(result.ply.path, p.join(work.export.path, 'export_20000.ply'));
      expect((result.splats, result.views, result.psnr), (150000, 131, 30.678303));
      expect(result.adapter!.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
      expect(work.logOf('brush').readAsStringSync(), contains('Done training! Took FormattedDuration(366s).'));
    });

    test('waits while other programs hold the memory of the card, says what is free, asks again every 30 s', () {
      fakeAsync((async) {
        final answers = <BrushCard>[
          const BrushCardWait(_gib),
          const BrushCardWait(2 * _gib),
          const BrushCardReady(_rtx, _laptop),
        ];
        var asked = 0;
        final runner = _BrushRunner([FakeProcessScript(lines: _training())]);
        final waits = <int>[];
        BrushResult? result;
        unawaited(
          brush(runner, check: () async => answers[asked++])
              .train(work, settings: const SplatSettings(), cancel: cancel, onWaiting: waits.add)
              .then((value) => result = value),
        );
        async.flushMicrotasks();
        expect(asked, 1);
        expect(waits, [_gib]);
        expect(runner.launches, isEmpty);
        async.elapse(const Duration(seconds: 29));
        expect(asked, 1);
        async.elapse(const Duration(seconds: 2));
        expect(asked, 2);
        expect(waits, [_gib, 2 * _gib]);
        expect(runner.launches, isEmpty);
        async.elapse(const Duration(seconds: 30));
        expect(asked, 3);
        async.elapse(const Duration(seconds: 1));
        expect(runner.launches, hasLength(1));
        expect(result, isNotNull);
      });
    });

    test(
      'cancelled while it waits, nothing starts; a card refused or that does not answer is gpuUnavailable',
      () async {
        fakeAsync((async) {
          final runner = _BrushRunner([const FakeProcessScript()]);
          Object? failure;
          unawaited(
            brush(runner, check: () async => const BrushCardWait(_gib))
                .train(work, settings: const SplatSettings(), cancel: cancel)
                .then<void>((_) {}, onError: (Object error) => failure = error),
          );
          async.elapse(const Duration(seconds: 10));
          cancel.cancel();
          async.elapse(const Duration(seconds: 1));
          expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled));
          expect(runner.launches, isEmpty);
        });
        final runner = _BrushRunner([const FakeProcessScript()]);
        final refusing = NativeCancelFlag();
        addTearDown(refusing.free);
        await expectLater(
          brush(
            runner,
            check: () async => const BrushCardRefused('gpuNone'),
          ).train(work, settings: const SplatSettings(), cancel: refusing),
          throwsA(
            isA<BackendException>()
                .having((e) => e.code, 'code', ImmersiveErrorCode.gpuUnavailable)
                .having((e) => e.message, 'message', 'gpuNone'),
          ),
        );
        await expectLater(
          brush(
            runner,
            check: () async => throw StateError('probe'),
          ).train(work, settings: const SplatSettings(), cancel: refusing),
          throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.gpuUnavailable)),
        );
        expect(runner.launches, isEmpty);
      },
    );

    test('Brush on another card than the card of the gate is stopped at once: gpuUnavailable', () async {
      final runner = _BrushRunner([
        FakeProcessScript(lines: _out(_fixture('ai_immersive/brush_igpu_plane_failure_stdout.txt')), hangs: true),
      ]);
      await expectLater(
        train(brush(runner)),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.gpuUnavailable)
              .having((e) => e.message, 'message', contains('Intel(R) RaptorLake-S Mobile Graphics Controller')),
        ),
      );
      expect(runner.processes.single.killed, isTrue);
    });

    test(
      'the panic of the Intel UHD on another card\'s cache is stopped at once, gpuUnavailable, its message kept',
      () async {
        // The card of the gate is the Intel here, so that the adapter line passes and the panic is what stops it
        final runner = _BrushRunner([
          FakeProcessScript(
            lines: [
              ..._out(_fixture('ai_immersive/brush_igpu_plane_failure_stdout.txt')),
              ..._err(_fixture('ai_immersive/brush_igpu_plane_failure_stderr.txt')),
            ],
            // Windows Error Reporting held the real one 80 s
            hangs: true,
          ),
        ]);
        final intelGate = brush(runner, check: () async => const BrushCardReady(_intel, _laptop));
        await expectLater(
          train(intelGate),
          throwsA(
            isA<BackendException>()
                .having((e) => e.code, 'code', ImmersiveErrorCode.gpuUnavailable)
                .having((e) => e.message, 'message', contains('plane instructions')),
          ),
        );
        expect(runner.processes.single.killed, isTrue);
        expect(runner.launches.single.environment['CUBECL_WGPU_DEFAULT_DEVICE'], 'IntegratedGpu(0)');
      },
    );

    test('a panic for want of graphics memory is gpuOutOfMemory; another panic trainingFailed', () async {
      List<(String, {bool isError})> panic(String message) => [
        ..._training().take(30),
        ("thread 'main' panicked at crates\\cubecl-wgpu\\src\\compute\\server.rs:412:18:", isError: true),
        (message, isError: true),
        ('note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace', isError: true),
      ];
      final oom = _BrushRunner([
        FakeProcessScript(lines: panic('failed to reserve 3595479680 bytes of device memory'), hangs: true),
      ]);
      await expectLater(
        train(brush(oom)),
        throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.gpuOutOfMemory)),
      );
      expect(oom.processes.single.killed, isTrue);
      final other = _BrushRunner([FakeProcessScript(lines: panic('index out of bounds'), exitCode: 101)]);
      await expectLater(
        train(brush(other)),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.trainingFailed)
              .having((e) => e.message, 'message', 'Brush panicked: index out of bounds'),
        ),
      );
    });

    test('a panic whose message never comes stops Brush a second later all the same', () {
      fakeAsync((async) {
        final runner = _BrushRunner([
          FakeProcessScript(
            lines: [..._training().take(20), ("thread 'main' panicked at src/main.rs:1:1:", isError: true)],
            hangs: true,
          ),
        ]);
        Object? failure;
        unawaited(
          train(brush(runner, elapsed: () => async.elapsed)).then<void>((_) {}, onError: (Object e) => failure = e),
        );
        async.elapse(const Duration(milliseconds: 500));
        expect(runner.processes.single.killed, isFalse);
        async.elapse(const Duration(milliseconds: 800));
        expect(runner.processes.single.killed, isTrue);
        expect(
          failure,
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.trainingFailed)
              .having((e) => e.message, 'message', 'Brush panicked: no message'),
        );
      });
    });

    test('a work folder that refuses its files is trainingFailed, before Brush starts', () async {
      // A file where the export of Brush goes
      File(work.export.path).writeAsStringSync('in the way');
      final runner = _BrushRunner([FakeProcessScript(lines: _training())]);
      await expectLater(
        train(brush(runner)),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.trainingFailed)
              .having((e) => e.message, 'message', startsWith('The work folder of Brush refused a file: ')),
        ),
      );
      expect(runner.launches, isEmpty);
    });

    test('an error before the training is trainingFailed with its end; ended well without its export too', () async {
      final runner = _BrushRunner([
        const FakeProcessScript(
          lines: [('Error: Failed to load dataset: no COLMAP model in /job/dataset', isError: true)],
          exitCode: 1,
        ),
      ]);
      await expectLater(
        train(brush(runner)),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.trainingFailed)
              .having(
                (e) => e.message,
                'message',
                'Brush ended with 1: Error: Failed to load dataset: no COLMAP model in /job/dataset',
              ),
        ),
      );
      final noExport = FakeProcessRunner([FakeProcessScript(lines: _training())]);
      await expectLater(
        train(brush(noExport)),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.trainingFailed)
              .having((e) => e.message, 'message', startsWith('Brush ended without writing export_20000.ply')),
        ),
      );
    });

    test('an export left by an earlier run is not taken for this one', () async {
      work.export.createSync(recursive: true);
      File(p.join(work.export.path, 'export_20000.ply')).writeAsStringSync('old');
      final runner = FakeProcessRunner([FakeProcessScript(lines: _training())]);
      await expectLater(train(brush(runner)), throwsA(isA<BackendException>()));
    });

    test('silent for 300 s, Brush is stopped as trainingStalled; cancelled, as cancelled', () {
      fakeAsync((async) {
        final runner = _BrushRunner([FakeProcessScript(lines: _training().take(40).toList(), hangs: true)]);
        Object? failure;
        unawaited(
          train(brush(runner, elapsed: () => async.elapsed)).then<void>((_) {}, onError: (Object e) => failure = e),
        );
        async.elapse(const Duration(seconds: 299));
        expect(failure, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(runner.processes.single.killed, isTrue);
        expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.trainingStalled));
      });
      fakeAsync((async) {
        final runner = _BrushRunner([FakeProcessScript(lines: _training().take(40).toList(), hangs: true)]);
        Object? failure;
        unawaited(
          train(brush(runner, elapsed: () => async.elapsed)).then<void>((_) {}, onError: (Object e) => failure = e),
        );
        async.elapse(const Duration(seconds: 3));
        cancel.cancel();
        async.elapse(const Duration(milliseconds: 250));
        expect(runner.processes.single.killed, isTrue);
        expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled));
      });
    });
  });

  group('the images', () {
    test('a JPEG or a PNG shorter than 16 387 bytes is made longer by a comment, its pixels the same', () {
      final picture = img.Image(width: 64, height: 48);
      for (final pixel in picture) {
        pixel
          ..r = pixel.x * 4
          ..g = pixel.y * 5
          ..b = 90;
      }
      final jpeg = img.encodeJpg(picture, quality: 90);
      final png = img.encodePng(picture);
      final big = Uint8List(20000)..setAll(0, jpeg);
      final files = {
        'cam0/000001.jpg': jpeg,
        'cam0/000002.png': png,
        'cam1/000003.jpg': big,
        'cam1/notes.txt': Uint8List.fromList('short'.codeUnits),
      };
      for (final MapEntry(:key, :value) in files.entries) {
        File(p.join(work.images.path, key))
          ..createSync(recursive: true)
          ..writeAsBytesSync(value);
      }
      expect(jpeg.length, lessThan(brushMinImageBytes));
      expect(lengthenShortImages(work.images), 2);
      Uint8List read(String name) => File(p.join(work.images.path, name)).readAsBytesSync();
      expect(read('cam0/000001.jpg').length, greaterThanOrEqualTo(brushMinImageBytes));
      expect(read('cam0/000002.png').length, greaterThanOrEqualTo(brushMinImageBytes));
      expect(read('cam1/000003.jpg'), big);
      expect(read('cam1/notes.txt'), 'short'.codeUnits);
      final fromJpeg = img.decodeJpg(read('cam0/000001.jpg'))!;
      final original = img.decodeJpg(jpeg)!;
      expect(fromJpeg.getBytes(), original.getBytes());
      expect(img.decodePng(read('cam0/000002.png'))!.getBytes(), picture.getBytes());
      // Once is enough
      expect(lengthenShortImages(work.images), 0);
    });

    test('the training lengthens the short images of its dataset before Brush reads them', () async {
      final jpeg = img.encodeJpg(img.Image(width: 32, height: 32));
      final file = File(p.join(work.images.path, 'cam0', '000001.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(jpeg);
      await train(brush(_BrushRunner([FakeProcessScript(lines: _training())])));
      expect(file.lengthSync(), greaterThanOrEqualTo(brushMinImageBytes));
    });
  });
}
