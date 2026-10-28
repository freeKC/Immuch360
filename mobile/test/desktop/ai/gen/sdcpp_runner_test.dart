// The runner of sd-cli (lot P2) with the fake runner of C0: its frozen arguments, what it reads of the lines M3 saw, the
// named failures, the stop, the silence of 180 s on a fake clock, and the checks of the image it wrote. The same runner
// against a real child process, the compiled fake sd-cli, is sdcpp_fake_cli_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_process_runner.dart';

/// The lines of a generation as the real sd-cli wrote them in M3 (base_q4_1536_s20, p02_landscape), cut short: the
/// version, the bars of the loading (MB/s) and of the tiles of the VAE (it/s), the sampling of 20 steps, the decoding
const _version = '[V] version: stable-diffusion.cpp version unknown, commit be48649 --- main.cpp:694';
const _generating = '[I] generating image: 1/1 - seed 1002 --- image.cpp:920';
const _oneSegment =
    '[V] flux compute buffer size: 2607.97 MB(VRAM) on Vulkan1 (peak across 1 segment) --- ggml_runner.cpp:1022';

List<(String, {bool isError})> _generation({int steps = 20, List<String> beforeSteps = const [_oneSegment]}) => [
  (_version, isError: false),
  ('  |##################################################| 108/108 - 325.06MB/s', isError: false),
  ('  |=>                                                |  1/40 -   3.40it/s', isError: false),
  ('  |==================================================| 40/40 -  32.26it/s', isError: false),
  (_generating, isError: false),
  ('  |################                                  |  47/149 -  25.21MB/s', isError: false),
  for (final line in beforeSteps) (line, isError: false),
  for (var step = 1; step <= steps; step++)
    (
      '  |=====>                                            | ${'$step'.padLeft(2)}/$steps -   8.${30 + step}s/it'
          ' - ETA 01:13',
      isError: false,
    ),
  ('  |=>                                                |  1/55 -  16.95it/s - ETA 00:02', isError: false),
  ('  |==================================================| 55/55 -  17.54it/s', isError: false),
  ('[I] generate_image completed in 198.39s --- image.cpp:1140', isError: false),
];

/// The texts M3 read when the memory ran short (section 5), on the outputs sd-cli writes them to
const _outOfMemory = [
  (
    '[W] model manager cannot make enough memory available on Vulkan1: need 4109.22 MB device / 3597.22 MB budget, '
        'available 2892.77 MB device / unlimited budget --- model_manager.cpp:2018',
    isError: false,
  ),
  ('flux segment 1/1 (graph) failed during weight preparation --- ggml_runner.cpp:899', isError: false),
  ('[E] diffusion model compute failed --- diffusion_engine.cpp:2655', isError: true),
  ('[E] generate failed --- main.cpp:926', isError: true),
];

/// The fake runner, writing [image] at the output of each launch as sd-cli would before it ends
class _WritingRunner implements ProcessRunner {
  _WritingRunner(this.inner, {this.image});

  final FakeProcessRunner inner;
  final img.Image? image;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final out = launch.arguments[launch.arguments.indexOf('-o') + 1];
    if (image != null) {
      File(out).writeAsBytesSync(img.encodePng(image!));
    }
    return inner.start(launch);
  }
}

/// [image] with its first row the pure green of the control frame: 32 of the 480 pixels outside the photo
img.Image _greenRow(img.Image image) {
  for (var x = 0; x < image.width; x++) {
    image.setPixelRgb(x, 0, 0, 255, 0);
  }
  return image;
}

img.Image _varied(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 255) ~/ width, (y * 255) ~/ height, 120);
    }
  }
  return image;
}

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('sdcpp-runner-');
    cancel = NativeCancelFlag();
  });

  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  SdCppSettings settings({Duration stall = const Duration(seconds: 180)}) => SdCppSettings(
    sdCli: '/engines/sd-cpp-vulkan-linux-x64/sd-cli',
    models: const SdCppModels(
      diffusionModel: '/ai/models/flux-2-klein-base-4b-Q4_0.gguf',
      vae: '/ai/models/flux2-vae.safetensors',
      textEncoder: '/ai/models/Qwen3-4B-Q4_K_M.gguf',
      lora: '/ai/models/lora/flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors',
      upscaler: '/ai/models/RealESRGAN_x4plus.pth',
    ),
    device: 'Vulkan1',
    threads: 30,
    stallTimeout: stall,
  );

  GeneratorRequest request({int width = 1536, int height = 768}) => GeneratorRequest(
    controlPath: p.join(folder.path, 'control.png'),
    outputPath: p.join(folder.path, 'generated.png'),
    workFolder: folder.path,
    prompt: 'Fill the green spaces according to the image.',
    seed: 1002,
    width: width,
    height: height,
  );

  SdCppGenerator generator(ProcessRunner runner, {bool checkImages = false, Duration Function()? elapsed}) =>
      SdCppGenerator(
        runner: runner,
        settings: settings(),
        generatorSha256: 'c3a28545',
        loraSha256: '567cc22d',
        checkImages: checkImages,
        elapsed: elapsed,
      );

  group('the arguments', () {
    test('are those M3 ran: the card named, flash attention, the encoder on the processor, 1536 x 768, 20 steps', () {
      expect(generator(FakeProcessRunner([const FakeProcessScript()])).argumentsOf(request()), [
        '--diffusion-model',
        '/ai/models/flux-2-klein-base-4b-Q4_0.gguf',
        '--vae',
        '/ai/models/flux2-vae.safetensors',
        '--llm',
        '/ai/models/Qwen3-4B-Q4_K_M.gguf',
        '--lora-model-dir',
        '/ai/models/lora',
        '--backend',
        'diffusion=Vulkan1,vae=Vulkan1,te=CPU',
        '--flash-attn',
        'on',
        '--vae-tiling',
        '-r',
        p.join(folder.path, 'control.png'),
        '-W',
        '1536',
        '-H',
        '768',
        '--steps',
        '20',
        '--cfg-scale',
        '5.0',
        '--sampling-method',
        'euler',
        '-s',
        '1002',
        '-p',
        'Fill the green spaces according to the image.<lora:flux-2-klein-4B-360-erp-outpaint-lora_V1:0.9>',
        '-n',
        'text, worst quality, blurry, ugly',
        '-t',
        '30',
        '-v',
        '-o',
        p.join(folder.path, 'generated.png'),
      ]);
      final upscale = SdCppUpscaler(runner: FakeProcessRunner([]), settings: settings(), modelSha256: '4fa0d389');
      expect(
        upscale.argumentsOf(UpscaleRequest(inputPath: 'wrapped.png', outputPath: 'x4.png', workFolder: folder.path)),
        [
          '-M',
          'upscale',
          '-i',
          'wrapped.png',
          '--upscale-model',
          '/ai/models/RealESRGAN_x4plus.pth',
          '--backend',
          'Vulkan1',
          '-t',
          '30',
          '-v',
          '-o',
          'x4.png',
        ],
      );
    });

    test('every option is one the pinned sd-cli lists in its --help, and none is deprecated there', () {
      final help = File('test/fixtures/ai_immersive/sd_cli_help.txt').readAsLinesSync();
      final options = <String>{
        for (final argument in [
          ...generator(FakeProcessRunner([])).argumentsOf(request()),
          ...SdCppUpscaler(
            runner: FakeProcessRunner([]),
            settings: settings(),
            modelSha256: '',
          ).argumentsOf(const UpscaleRequest(inputPath: 'a', outputPath: 'b', workFolder: 'c')),
        ])
          if (argument.startsWith('-') && !argument.contains(' ')) argument,
      };
      // "  -o, --output <string>   path..." or "  --vae <string>   path...": each option with its line
      final listed = <String, String>{};
      for (final line in help) {
        final match = RegExp(r'^  (?:(-\w), )?(--[\w-]+)').firstMatch(line);
        if (match != null) {
          listed[match.group(2)!] = line;
          if (match.group(1) != null) {
            listed[match.group(1)!] = line;
          }
        }
      }
      expect(listed.length, greaterThan(150));
      for (final option in options) {
        expect(listed.keys, contains(option), reason: '$option is not in sd_cli_help.txt');
        expect(listed[option], isNot(contains('deprecated')), reason: option);
      }
      expect(help.first, 'stable-diffusion.cpp version unknown, commit be48649');
      // The options of the design that the build no longer wants
      expect(options, isNot(contains('--clip-on-cpu')));
      expect(options, isNot(contains('--diffusion-fa')));
    });

    test('the threads are the logical processors less two, the card a Vulkan device of ggml', () {
      final defaults = SdCppSettings(sdCli: 'sd-cli', models: settings().models, device: 'Vulkan0');
      expect(defaults.threads, Platform.numberOfProcessors > 2 ? Platform.numberOfProcessors - 2 : 1);
      expect(defaults.stallTimeout, const Duration(seconds: 180));
      expect(() => SdCppSettings(sdCli: 'sd-cli', models: settings().models, device: 'cuda0'), throwsAssertionError);
      expect(sdCliIn('/e', windows: true), p.join('/e', 'sd-cli.exe'));
      expect(sdCliIn('/e', windows: false), p.join('/e', 'sd-cli'));
    });
  });

  group('the lines', () {
    test('a bar gives its step, its total and the seconds of a step; the loading bars give none', () {
      expect(
        sdCppBarOf('  |============>                                     |  12/20 -   8.65s/it - ETA 01:13'),
        const GeneratorProgress(12, 20, secondsPerStep: 8.65),
      );
      expect(
        sdCppBarOf('  |==>                                               |  2/40 -  30.30it/s')!.secondsPerStep,
        closeTo(1 / 30.3, 1e-9),
      );
      expect(sdCppBarOf('  |####                                              |   7/108 -   8.91MB/s'), isNull);
      expect(sdCppBarOf('[I] generating image: 1/1 - seed 1002 --- image.cpp:920'), isNull);
    });

    test('the segments of the graph of the generator, read from either line sd-cli writes', () {
      expect(sdCppSegmentsOf('[V] flux using 27 segments --- ggml_runner.cpp:879'), 27);
      expect(
        sdCppSegmentsOf(
          '[V] flux compute buffer size: 2687.96 MB(VRAM) on Vulkan1 (peak across 27 segments) --- ggml_runner.cpp:1022',
        ),
        27,
      );
      expect(sdCppSegmentsOf(_oneSegment), isNull);
      expect(sdCppSegmentsOf('[V] vae compute buffer size: 97.00 MB(VRAM) on Vulkan1 (peak across 1 segment)'), isNull);
    });
  });

  group('a generation', () {
    test('reports the 20 steps of the sampling only, with the pace, and checks nothing when told not to', () async {
      final runner = FakeProcessRunner([FakeProcessScript(lines: _generation())]);
      final heard = <GeneratorProgress>[];
      File(request().outputPath).writeAsStringSync('an earlier image');

      final writing = _WritingRunner(runner, image: _varied(16, 8));
      await generator(writing).generate(request(), cancel: cancel, onProgress: heard.add);

      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(heard.every((progress) => progress.steps == 20), isTrue);
      expect(heard.last.secondsPerStep, 8.5);
      expect(heard[11].remaining, Duration(milliseconds: (8 * 8.42 * 1000).round()));
      final launch = runner.launches.single;
      expect(launch.executable, '/engines/sd-cpp-vulkan-linux-x64/sd-cli');
      expect(launch.workingDirectory, folder.path);
      expect(launch.lowPriority, isTrue);
      expect(runner.processes.single.killed, isFalse);
    });

    test('cut into segments, it is stopped at once and refused, never a file', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: _generation(
            beforeSteps: [
              '[V] flux compute buffer size: 3928.82 MB(VRAM) on Vulkan1 (peak across 1 segment) --- ggml_runner.cpp:1022',
              '[V] flux using 27 segments --- ggml_runner.cpp:879',
            ],
          ),
        ),
      ]);
      final heard = <GeneratorProgress>[];
      await expectLater(
        generator(runner).generate(request(), cancel: cancel, onProgress: heard.add),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.outputRejected)
              .having((error) => error.message, 'message', contains('27 segments')),
        ),
      );
      expect(runner.processes.single.killed, isTrue);
      expect(heard, isEmpty);
      expect(File(request().outputPath).existsSync(), isFalse);
    });

    test('short of memory, it fails as gpuOutOfMemory with the end of its error output', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(lines: [..._generation(steps: 0), ..._outOfMemory], exitCode: 1),
      ]);
      await expectLater(
        generator(runner).generate(request(), cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.gpuOutOfMemory)
              .having((error) => error.message, 'message', contains('[E] generate failed')),
        ),
      );
    });

    test('another failure is generatorFailed with the last 20 lines of its error output, the bars left out', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: [
            (_version, isError: false),
            for (var line = 1; line <= 25; line++) ('[E] trouble $line', isError: true),
          ],
          exitCode: 3,
        ),
      ]);
      final failure = await generator(runner)
          .generate(request(), cancel: cancel)
          .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);
      expect(failure!.code, ImmersiveErrorCode.generatorFailed);
      expect(failure.message, startsWith('sd-cli ended with 3: [E] trouble 6\n'));
      expect(failure.message, endsWith('[E] trouble 25'));
      expect('\n'.allMatches(failure.message).length, 19);

      // Nothing on the error output: the end of the output instead
      final quiet = FakeProcessRunner([
        const FakeProcessScript(
          lines: [(_version, isError: false), ('[I] no control image', isError: false)],
          exitCode: 1,
        ),
      ]);
      await expectLater(
        generator(quiet).generate(request(), cancel: cancel),
        throwsA(isA<BackendException>().having((error) => error.message, 'message', endsWith('[I] no control image'))),
      );
    });

    test('ended well without its image, it failed', () async {
      final runner = FakeProcessRunner([FakeProcessScript(lines: _generation())]);
      await expectLater(
        generator(runner).generate(request(), cancel: cancel),
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.generatorFailed)),
      );
    });

    test('a program that cannot start is generatorFailed', () async {
      await expectLater(
        generator(_FailingRunner()).generate(request(), cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.generatorFailed)
              .having((error) => error.message, 'message', contains('could not start')),
        ),
      );
    });

    test('silent for 180 s on the clock, it is stopped as generatorStalled; 179 s are not enough', () {
      fakeAsync((async) {
        final runner = FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 3), hangs: true)]);
        Object? failure;
        unawaited(
          generator(runner, elapsed: () => async.elapsed)
              .generate(request(), cancel: cancel)
              .then<void>((_) {}, onError: (Object error) => failure = error),
        );
        async.elapse(const Duration(seconds: 179));
        expect(failure, isNull);
        expect(runner.processes.single.killed, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(runner.processes.single.killed, isTrue);
        expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.generatorStalled));
      });
    });

    test('a line now and then keeps it alive, however long it takes', () {
      fakeAsync((async) {
        final runner = FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 0), hangs: true)]);
        var finished = false;
        unawaited(
          generator(
            runner,
            elapsed: () => async.elapsed,
          ).generate(request(), cancel: cancel).whenComplete(() => finished = true).catchError((Object _) {}),
        );
        async.elapse(const Duration(seconds: 170));
        // A step every 170 s: never silent for 180
        for (var i = 0; i < 3; i++) {
          runner.processes.single.emit('  | ${i + 1}/20 - 170.00s/it');
          async.elapse(const Duration(seconds: 170));
        }
        expect(finished, isFalse);
        expect(runner.processes.single.killed, isFalse);
        cancel.cancel();
        async.elapse(const Duration(seconds: 1));
        expect(finished, isTrue);
      });
    });

    test('cancelled, it is stopped within the interval of the watch and fails as cancelled', () async {
      fakeAsync((async) {
        final runner = FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 2), hangs: true)]);
        Object? failure;
        unawaited(
          generator(runner).generate(request(), cancel: cancel).then<void>((_) {}, onError: (Object e) => failure = e),
        );
        async.elapse(const Duration(seconds: 5));
        cancel.cancel();
        async.elapse(const Duration(milliseconds: 250));
        expect(runner.processes.single.killed, isTrue);
        expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled));
      });
      // Cancelled before it started: nothing starts
      final runner = FakeProcessRunner([const FakeProcessScript()]);
      await expectLater(
        generator(runner).generate(request(), cancel: cancel),
        throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled)),
      );
      expect(runner.launches, isEmpty);
    });
  });

  group('the image', () {
    void writeControl() {
      // The photo in the middle, pure green around it
      final control = img.Image(width: 64, height: 32)..clear(img.ColorRgb8(0, 255, 0));
      img.fillRect(control, x1: 24, y1: 12, x2: 39, y2: 19, color: img.ColorRgb8(90, 120, 30));
      File(request().controlPath).writeAsBytesSync(img.encodePng(control));
    }

    Future<BackendException?> run(img.Image image, {int width = 32, int height = 16}) async {
      writeControl();
      final runner = _WritingRunner(FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 1))]), image: image);
      return generator(runner, checkImages: true)
          .generate(
            request(width: width, height: height),
            cancel: cancel,
          )
          .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);
    }

    test('a varied image of the size asked is kept', () async {
      expect(await run(_varied(32, 16)), isNull);
      expect(File(request().outputPath).existsSync(), isTrue);
    });

    test('a grey image, an image of another size, or green left outside the photo is refused and deleted', () async {
      for (final (image, reason) in [
        (img.Image(width: 32, height: 16)..clear(img.ColorRgb8(128, 128, 128)), 'a grey image'),
        (_varied(48, 16), 'an image of 48 x 16, not 32 x 16'),
        (_greenRow(_varied(32, 16)), 'of pure green left outside the photo'),
      ]) {
        final failure = await run(image);
        expect(failure?.code, ImmersiveErrorCode.outputRejected, reason: reason);
        expect(failure?.message, contains(reason));
        expect(File(request().outputPath).existsSync(), isFalse, reason: reason);
      }
    });

    test('pure green inside the photo is the photo: kept', () async {
      // The photo of the control frame covers x 12 to 19, y 6 to 9 of a 32 x 16 image
      final image = _varied(32, 16);
      for (var x = 13; x < 19; x++) {
        image.setPixelRgb(x, 7, 0, 255, 0);
      }
      expect(await run(image), isNull);
    });
  });

  group('an upscale', () {
    test('reports its tiles and checks the size of what it wrote: four times its input', () async {
      final input = p.join(folder.path, 'wrapped.png');
      File(input).writeAsBytesSync(img.encodePng(_varied(20, 10)));
      final upscaleLines = [
        (_version, isError: false),
        ('[I] upscaling from (20 x 10) to (80 x 40) --- upscaler.cpp:214', isError: false),
        for (var tile = 1; tile <= 4; tile++) ('  |=====>      |  $tile/4 -   3.75it/s', isError: false),
      ];
      UpscaleRequest request(String out) => UpscaleRequest(inputPath: input, outputPath: out, workFolder: folder.path);
      final good = _WritingRunner(FakeProcessRunner([FakeProcessScript(lines: upscaleLines)]), image: _varied(80, 40));
      final heard = <GeneratorProgress>[];
      await SdCppUpscaler(
        runner: good,
        settings: settings(),
        modelSha256: '4fa0d389',
      ).upscale(request(p.join(folder.path, 'x4.png')), cancel: cancel, onProgress: heard.add);
      expect(heard.map((progress) => (progress.step, progress.steps)), [(1, 4), (2, 4), (3, 4), (4, 4)]);

      final small = _WritingRunner(FakeProcessRunner([FakeProcessScript(lines: upscaleLines)]), image: _varied(40, 20));
      await expectLater(
        SdCppUpscaler(
          runner: small,
          settings: settings(),
          modelSha256: '',
        ).upscale(request(p.join(folder.path, 'x2.png')), cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.outputRejected)
              .having((error) => error.message, 'message', contains('40 x 20, not 80 x 40')),
        ),
      );
      expect(File(p.join(folder.path, 'x2.png')).existsSync(), isFalse);
      await expectLater(
        SdCppUpscaler(runner: good, settings: settings(), modelSha256: '').upscale(
          UpscaleRequest(inputPath: p.join(folder.path, 'none.png'), outputPath: 'x.png', workFolder: folder.path),
          cancel: cancel,
        ),
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.generatorFailed)),
      );
    });
  });

  test('PanoV1 gives the generation its default size and steps', () {
    const defaults = GeneratorRequest(controlPath: 'c', outputPath: 'o', workFolder: 'w', prompt: 'p', seed: 1);
    expect((defaults.width, defaults.height, defaults.steps), (1536, 768, 20));
    expect((defaults.guidance, defaults.loraStrength), (PanoV1.guidance, PanoV1.loraStrength));
  });
}

class _FailingRunner implements ProcessRunner {
  @override
  Future<RunningProcess> start(ProcessLaunch launch) async => throw const ProcessException('sd-cli', [], 'not found');
}
