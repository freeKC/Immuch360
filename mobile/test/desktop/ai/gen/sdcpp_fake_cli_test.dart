// The runner of sd-cli (lot P2) against a real child process: the fake sd-cli compiled by `dart compile exe`
// (test/desktop/ai/fakes/fake_sd_cli.dart; the test and windows jobs of the desktop workflow compile it and give its path
// in IMMUCH360_FAKE_SD_CLI), started by the launcher of the app (managed_process.dart; on Linux through immuch360-run
// when IMMUCH360_RUN_LAUNCHER gives it). Progress, a stop within a second, the silence of 180 s on a clock that jumps,
// a grey image, green left, the memory texts M3 read, a graph cut into segments that runs to its image (with the
// shortfalls sd-cli recovers from too), the budget it plans with on Linux and on Windows, a failure, and an upscale.
// Since release 44, the list of the laptop of the owner (IMMUCH360_FAKE_SD_CLI_DEVICES, the Intel chip first): the run
// started again on the RTX 4060, both runs in the log of the job.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _fakeSdCli = Platform.environment['IMMUCH360_FAKE_SD_CLI'];
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];

/// The laptop of the owner as sd-cli.exe lists its cards (panorama-vulkan-2026-11-08, sd-cli-2.log): the Intel chip
/// first, the RTX 4060 second
const _laptop =
    'Intel(R) RaptorLake-S Mobile Graphics Controller (Intel Corporation)|1;'
    'NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA)|0';
const _rtx = SdCppCard(name: 'NVIDIA GeForce RTX 4060 Laptop GPU', integrated: false);

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('sdcpp-fake-cli-');
    cancel = NativeCancelFlag();
    SdCppDevice.forgetLearned();
    // A control frame of 2048 x 1024: the photo in the middle, pure green around it
    final control = img.Image(width: 256, height: 128)..clear(img.ColorRgb8(0, 255, 0));
    img.fillRect(control, x1: 96, y1: 40, x2: 159, y2: 87, color: img.ColorRgb8(120, 90, 70));
    File(p.join(folder.path, 'control.png')).writeAsBytesSync(img.encodePng(control));
  });

  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  SdCppSettings settings({
    String mode = 'ok',
    Duration stall = const Duration(seconds: 180),
    int? freeMib,
    String device = 'Vulkan0',
    String? devices,
    SdCppCard? card,
  }) => SdCppSettings(
    sdCli: _fakeSdCli!,
    models: SdCppModels(
      diffusionModel: p.join(folder.path, 'flux-2-klein-base-4b-Q4_0.gguf'),
      vae: p.join(folder.path, 'vae.safetensors'),
      textEncoder: p.join(folder.path, 'Qwen3-4B-Q4_K_M.gguf'),
      lora: p.join(folder.path, 'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors'),
      upscaler: p.join(folder.path, 'RealESRGAN_x4plus.pth'),
    ),
    device: device,
    card: card,
    stallTimeout: stall,
    environment: {
      'IMMUCH360_FAKE_SD_CLI_MODE': mode,
      'IMMUCH360_FAKE_SD_CLI_PID': p.join(folder.path, 'sd-cli.pid'),
      'IMMUCH360_FAKE_SD_CLI_DEVICES': ?devices,
      if (freeMib != null) 'IMMUCH360_FAKE_SD_CLI_FREE_MIB': '$freeMib',
    },
  );

  ManagedProcessRunner runner() => ManagedProcessRunner(
    linuxLauncher: _launcher,
    journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))),
  );

  GeneratorRequest request({int? graphicsBudget}) => GeneratorRequest(
    controlPath: p.join(folder.path, 'control.png'),
    outputPath: p.join(folder.path, 'generated.png'),
    workFolder: folder.path,
    prompt: 'Fill the green spaces according to the image.',
    seed: 7,
    width: 192,
    height: 96,
    graphicsBudget: graphicsBudget,
  );

  Future<BackendException?> generate(String mode, {void Function(GeneratorProgress)? onProgress}) =>
      SdCppGenerator(
            runner: runner(),
            settings: settings(mode: mode),
            generatorSha256: '',
            loraSha256: '',
          )
          .generate(request(), cancel: cancel, onProgress: onProgress)
          .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);

  int? childPid() {
    final file = File(p.join(folder.path, 'sd-cli.pid'));
    return file.existsSync() && file.readAsStringSync().isNotEmpty ? int.parse(file.readAsStringSync()) : null;
  }

  group('the fake sd-cli as a real program', () {
    test('a generation: its 20 steps, its image kept, the journal empty after it', () async {
      final heard = <GeneratorProgress>[];
      expect(await generate('ok', onProgress: heard.add), isNull);
      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(heard.last.secondsPerStep, closeTo(8.7, 1e-9));
      expect(img.decodePng(File(request().outputPath).readAsBytesSync())!.width, 192);
      expect(ProcessJournal(File(p.join(folder.path, 'processes.json'))).read(), isEmpty);
    });

    test('a grey image and green left are refused and deleted', () async {
      for (final mode in ['grey', 'green']) {
        final failure = await generate(mode);
        expect(failure?.code, ImmersiveErrorCode.outputRejected, reason: mode);
        expect(File(request().outputPath).existsSync(), isFalse, reason: mode);
      }
    });

    test(
      'the texts of a memory too short are gpuOutOfMemory; another error is generatorFailed with its text',
      () async {
        final memory = await generate('oom');
        expect(memory?.code, ImmersiveErrorCode.gpuOutOfMemory);
        expect(memory?.message, contains('[E] generate failed'));
        // What it read of its card first: its plan, and the 1 216.45 MiB its model manager lacked
        expect(
          GeneratorMemoryRead.of(memory?.message),
          const GeneratorMemoryRead(free: 7188 * 1024 * 1024, budget: 6676 * 1024 * 1024, short: 1217 * 1024 * 1024),
        );
        final failed = await generate('fail');
        expect(failed?.code, ImmersiveErrorCode.generatorFailed);
        expect(failed?.message, contains('[E] load the control image failed'));
      },
    );

    test('the budget the queue read reaches sd-cli: its plan says it, and the log keeps what it read', () async {
      final logged = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      final listening = Logger.root.onRecord.where((record) => record.loggerName == 'SdCpp').listen((record) {
        logged.add(record.message);
      });
      addTearDown(() async {
        Logger.root.level = level;
        await listening.cancel();
      });

      final failure = await SdCppGenerator(runner: runner(), settings: settings(), generatorSha256: '', loraSha256: '')
          .generate(request(graphicsBudget: 5018 * 1024 * 1024), cancel: cancel)
          .then<Object?>((_) => null, onError: (Object error) => error);

      expect(failure, isNull);
      expect(
        logged,
        contains(
          'sd-cli read 7188 MiB free on Vulkan0 (Fake graphics card), budget 5017 MiB given by the app (from the free '
          "memory Windows counts: Vulkan's figure leaves other programs out)",
        ),
      );
      // The placement sd-cli settled on
      const placed = 'sd-cli auto-fit: --backend "diffusion=Vulkan0,vae=Vulkan0,te=CPU" --params-backend "te=disk"';
      expect(logged, contains(placed));
    });

    test('the budget sd-cli plans with: its own reserve on Linux, the probe\'s figure on Windows, capped at what it '
        'reads', () async {
      // Review of lot 13c: the probe read 4 906 MiB free
      final logged = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      final listening = Logger.root.onRecord.where((record) => record.loggerName == 'SdCpp').listen((record) {
        logged.add(record.message);
      });
      addTearDown(() async {
        Logger.root.level = level;
        await listening.cancel();
      });
      const probed = 4906 * 1024 * 1024;
      Future<void> run({required bool windows, required int freeMib}) =>
          SdCppGenerator(
            runner: runner(),
            settings: settings(freeMib: freeMib),
            generatorSha256: '',
            loraSha256: '',
          ).generate(
            request(graphicsBudget: panoramaGeneratorBudget(probed, windows: windows)),
            cancel: cancel,
          );

      String lastRead() => logged.lastWhere((line) => line.startsWith('sd-cli read '));
      // Linux, sd-cli reading 400 MiB less than the probe a few seconds later: no --max-vram, its own reserve kept
      await run(windows: false, freeMib: 4506);
      expect(lastRead(), 'sd-cli read 4506 MiB free on Vulkan0 (Fake graphics card), budget 3994 MiB');
      // Windows, sd-cli reading 7 188 MiB as Vulkan does, other programs left out: the probe's figure less 512 MiB
      await run(windows: true, freeMib: 7188);
      expect(lastRead(), startsWith('sd-cli read 7188 MiB free on Vulkan0 (Fake graphics card), budget 4393 MiB '));
      expect(lastRead(), contains('MiB given by the app'));
      // A budget above what sd-cli reads is cut down to it, with no reserve left (backend_fit.cpp 152-157): what the
      // flag would do on Linux when sd-cli reads less than the probe
      await run(windows: true, freeMib: 4200);
      expect(lastRead(), startsWith('sd-cli read 4200 MiB free on Vulkan0 (Fake graphics card), budget 4200 MiB '));
      expect(lastRead(), contains('MiB given by the app'));
    });

    test('shortfalls sd-cli recovers from in segments: the run ends well, with its image', () async {
      final heard = <GeneratorProgress>[];
      expect(await generate('recover', onProgress: heard.add), isNull);
      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(heard.every((progress) => progress.segments == 27), isTrue);
      expect(img.decodePng(File(request().outputPath).readAsBytesSync())!.width, 192);
    });

    test('a graph cut into segments runs to its image, each of its steps saying the 27 segments', () async {
      final heard = <GeneratorProgress>[];
      expect(await generate('segments', onProgress: heard.add), isNull);
      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(heard.every((progress) => progress.segments == 27), isTrue);
      expect(img.decodePng(File(request().outputPath).readAsBytesSync())!.width, 192);
    });

    test('cancelled in the middle, it is gone within a second', () async {
      final heard = <GeneratorProgress>[];
      final cancelled = Completer<Stopwatch>();
      final generation =
          SdCppGenerator(
            runner: runner(),
            settings: settings(mode: 'slow'),
            generatorSha256: '',
            loraSha256: '',
          ).generate(
            request(),
            cancel: cancel,
            onProgress: (progress) {
              heard.add(progress);
              if (progress.step == 2 && !cancelled.isCompleted) {
                cancel.cancel();
                cancelled.complete(Stopwatch()..start());
              }
            },
          );
      await expectLater(
        generation,
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.cancelled)),
      );
      final watch = await cancelled.future;
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(heard.last.step, lessThan(4));
      expect(processImageOf(childPid()!), isNull);
    });

    test('silent for 180 s on a clock that jumps a minute every half second, it is stopped as stalled', () async {
      final watch = Stopwatch()..start();
      var jumped = Duration.zero;
      final clock = Timer.periodic(const Duration(milliseconds: 500), (_) => jumped += const Duration(minutes: 1));
      addTearDown(clock.cancel);
      final failure =
          await SdCppGenerator(
                runner: runner(),
                settings: settings(mode: 'silent'),
                generatorSha256: '',
                loraSha256: '',
                elapsed: () => watch.elapsed + jumped,
              )
              .generate(request(), cancel: cancel)
              .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException)
              .timeout(const Duration(seconds: 20));
      expect(failure?.code, ImmersiveErrorCode.generatorStalled);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(processImageOf(childPid()!), isNull);
    });

    test('the list of the laptop of the owner, the Intel chip first: started again on the RTX 4060, which makes the '
        'image; both runs in the log of the job', () async {
      final generator = SdCppGenerator(
        runner: runner(),
        settings: settings(devices: _laptop, card: _rtx),
        generatorSha256: '',
        loraSha256: '',
      );
      final heard = <GeneratorProgress>[];
      final failure = await generator
          .generate(request(), cancel: cancel, onProgress: heard.add)
          .then<Object?>((_) => null, onError: (Object error) => error);

      expect(failure, isNull);
      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(img.decodePng(File(request().outputPath).readAsBytesSync())!.width, 192);
      expect(generator.device.name, 'Vulkan1');
      final log = File(p.join(folder.path, 'logs', 'sd-cli.log')).readAsLinesSync();
      expect(log.where((line) => line.startsWith('===== ')), hasLength(2));
      expect(log.where((line) => line == 'ggml_vulkan: Found 2 Vulkan devices:'), hasLength(2));
      expect(log, contains(startsWith('[I] auto-fit: --backend "diffusion=Vulkan1,vae=Vulkan1,te=CPU"')));
      expect(ProcessJournal(File(p.join(folder.path, 'processes.json'))).read(), isEmpty);
    });

    test('given a device beyond its list, the fake ends as the pinned build does; the list puts it right', () async {
      final generator = SdCppGenerator(
        runner: runner(),
        settings: settings(device: 'Vulkan2', devices: _laptop, card: _rtx),
        generatorSha256: '',
        loraSha256: '',
      );
      final failure = await generator
          .generate(request(), cancel: cancel)
          .then<Object?>((_) => null, onError: (Object error) => error);

      expect(failure, isNull);
      expect(generator.device.name, 'Vulkan1');
      final log = File(p.join(folder.path, 'logs', 'sd-cli.log')).readAsStringSync();
      expect(log, contains("[E] backend 'Vulkan2' was not found"));
    });

    test('an upscale: four times its input, its tiles reported', () async {
      final input = p.join(folder.path, 'generated.png');
      File(input).writeAsBytesSync(img.encodePng(img.Image(width: 40, height: 20)..clear(img.ColorRgb8(9, 9, 9))));
      final heard = <GeneratorProgress>[];
      await SdCppUpscaler(runner: runner(), settings: settings(), modelSha256: '').upscale(
        UpscaleRequest(inputPath: input, outputPath: p.join(folder.path, 'x4.png'), workFolder: folder.path),
        cancel: cancel,
        onProgress: heard.add,
      );
      expect(heard.last.step, 128);
      expect(img.decodePng(File(p.join(folder.path, 'x4.png')).readAsBytesSync())!.width, 160);
    });
  }, skip: _fakeSdCli == null ? 'no compiled fake sd-cli (IMMUCH360_FAKE_SD_CLI)' : false);
}
