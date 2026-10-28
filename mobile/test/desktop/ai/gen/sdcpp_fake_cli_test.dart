// The runner of sd-cli (lot P2) against a real child process: the fake sd-cli compiled by `dart compile exe`
// (test/desktop/ai/fakes/fake_sd_cli.dart; the test and windows jobs of the desktop workflow compile it and give its path
// in IMMUCH360_FAKE_SD_CLI), started by the launcher of the app (managed_process.dart; on Linux through immuch360-run
// when IMMUCH360_RUN_LAUNCHER gives it). Progress, a stop within a second, the silence of 180 s on a clock that jumps,
// a grey image, green left, the memory texts M3 read, a graph cut into segments, a failure, and an upscale.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

final _fakeSdCli = Platform.environment['IMMUCH360_FAKE_SD_CLI'];
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('sdcpp-fake-cli-');
    cancel = NativeCancelFlag();
    // A control frame of 2048 x 1024: the photo in the middle, pure green around it
    final control = img.Image(width: 256, height: 128)..clear(img.ColorRgb8(0, 255, 0));
    img.fillRect(control, x1: 96, y1: 40, x2: 159, y2: 87, color: img.ColorRgb8(120, 90, 70));
    File(p.join(folder.path, 'control.png')).writeAsBytesSync(img.encodePng(control));
  });

  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  SdCppSettings settings({String mode = 'ok', Duration stall = const Duration(seconds: 180)}) => SdCppSettings(
    sdCli: _fakeSdCli!,
    models: SdCppModels(
      diffusionModel: p.join(folder.path, 'flux-2-klein-base-4b-Q4_0.gguf'),
      vae: p.join(folder.path, 'vae.safetensors'),
      textEncoder: p.join(folder.path, 'Qwen3-4B-Q4_K_M.gguf'),
      lora: p.join(folder.path, 'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors'),
      upscaler: p.join(folder.path, 'RealESRGAN_x4plus.pth'),
    ),
    device: 'Vulkan0',
    stallTimeout: stall,
    environment: {'IMMUCH360_FAKE_SD_CLI_MODE': mode, 'IMMUCH360_FAKE_SD_CLI_PID': p.join(folder.path, 'sd-cli.pid')},
  );

  ManagedProcessRunner runner() => ManagedProcessRunner(
    linuxLauncher: _launcher,
    journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))),
  );

  GeneratorRequest request() => GeneratorRequest(
    controlPath: p.join(folder.path, 'control.png'),
    outputPath: p.join(folder.path, 'generated.png'),
    workFolder: folder.path,
    prompt: 'Fill the green spaces according to the image.',
    seed: 7,
    width: 192,
    height: 96,
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
        final failed = await generate('fail');
        expect(failed?.code, ImmersiveErrorCode.generatorFailed);
        expect(failed?.message, contains('[E] load the control image failed'));
      },
    );

    test('a graph cut into segments is stopped before its first step and refused', () async {
      final heard = <GeneratorProgress>[];
      final failure = await generate('segments', onProgress: heard.add);
      expect(failure?.code, ImmersiveErrorCode.outputRejected);
      expect(heard, isEmpty);
      expect(processImageOf(childPid()!), isNull);
      expect(File(request().outputPath).existsSync(), isFalse);
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
