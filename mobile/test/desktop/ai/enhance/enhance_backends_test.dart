import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/rebuild_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/seedvr2_dgl.dart';
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_enhance_tools.dart';

/// A picture with a gradient and a checker, so that a misplaced tile shows
SbsDecoded _picture(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = 4 * (y * width + x);
      rgba[i] = x * 255 ~/ width;
      rgba[i + 1] = y * 255 ~/ height;
      rgba[i + 2] = ((x ~/ 8 + y ~/ 8).isEven ? 40 : 200);
      rgba[i + 3] = 255;
    }
  }
  return SbsDecoded(width: width, height: height, rgba: rgba);
}

void _expectClose(Uint8List a, Uint8List b, {int tolerance = 2}) {
  expect(a.length, b.length);
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final difference = (a[i] - b[i]).abs();
    if (difference > worst) {
      worst = difference;
    }
  }
  expect(worst, lessThanOrEqualTo(tolerance));
}

typedef _ScriptRunner = FakeSeedVr2Runner;
typedef _FourTimes = FakeX4Upscaler;

/// A graph whose run fails as Core ML could, or is stopped
class _FailingGraph implements VosrGraph {
  _FailingGraph({this.stop = false});

  final bool stop;

  @override
  String get firstInput => 'latent';

  @override
  OrtTensor run(Map<String, OrtTensor> given) =>
      throw stop ? const OrtRunStopped('Run: stopped') : const OrtException('Run: Core ML failed');
}

/// A graph of VOSR that keeps what its encoder saw and gives it back from its decoder
class _Graph implements VosrGraph {
  _Graph(this.name, this.memory);

  final String name;
  final Map<String, OrtTensor> memory;
  final seen = <Map<String, OrtTensor>>[];

  @override
  String get firstInput => name == 'vae_decoder' ? 'latent' : 'lq';

  @override
  OrtTensor run(Map<String, OrtTensor> given) {
    seen.add(given);
    switch (name) {
      case 'image_encoder':
        return OrtTensor(const [1, 4, 8], Float32List(32));
      case 'vae_encoder':
        memory['lq'] = given['lq']!;
        return OrtTensor(const [1, 16, 64, 64], Float32List(16 * 64 * 64));
      case 'transformer':
        return given['lq_latent']!;
      default:
        return memory['lq']!;
    }
  }
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('enhance-backends-'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('Rebuild details', () {
    SdCppSettings settings() => SdCppSettings(
      sdCli: p.join(temp.path, 'sd-cli'),
      models: const SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: ''),
      device: 'Vulkan1',
      card: const SdCppCard(name: 'NVIDIA GeForce RTX 4060 Laptop GPU', integrated: false),
      threads: 22,
    );

    SdCppRebuildBackend backendWith(
      _ScriptRunner runner, {
      RebuildFiles files = const RebuildFiles(sdCli: 'sd-cli', dit: '/m/dit.safetensors', vae: '/m/vae.safetensors'),
      String Function(String path)? asciiPath,
    }) => SdCppRebuildBackend(
      runner: runner,
      settings: settings(),
      files: files,
      modelSha256: 'c3dec8bcc5916843a8a858572970597462e1f2dc598d6dfd818f6cd40f53a157',
      graphicsFree: 7 << 30,
      asciiPath: asciiPath,
    );

    setUp(SdCppDevice.forgetLearned);

    test('runs the program on the card of the job and blends its tiles back into the picture', () async {
      final runner = _ScriptRunner();
      final picture = _picture(1100, 700);
      final steps = <(int, int)>[];
      final out = await backendWith(runner).enhance(
        picture,
        workFolder: temp.path,
        seed: 42,
        cancel: NativeCancelFlag(),
        onStep: (done, all) => steps.add((done, all)),
      );
      _expectClose(out, picture.rgba);
      final tiles = planTiles(1100, 700).length;
      expect(steps.last, (3 * tiles, 3 * tiles));
      expect(runner.launches.single.arguments, [
        '-M',
        'dgl',
        '--script',
        p.join(temp.path, 'rebuild.dgl'),
        '--backend',
        'Vulkan1',
        '--max-vram',
        '6.0000',
        '-t',
        '22',
        '-v',
      ]);
      expect(File(p.join(temp.path, 'rebuild.dgl')).readAsStringSync(), contains('conv_direct_mode = "on"'));
    });

    test('a card without the integer dot product is stopped before its work runs on the processor', () async {
      await expectLater(
        backendWith(
          _ScriptRunner(intDot: 0),
        ).enhance(_picture(600, 600), workFolder: temp.path, seed: 42, cancel: NativeCancelFlag(), onStep: (_, _) {}),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.gpuUnavailable)
              .having((error) => error.message, 'message', startsWith(enhanceNoIntDotMessage)),
        ),
      );
    });

    test('a refusal of its memory checks says to close other programs', () async {
      await expectLater(
        backendWith(
          _ScriptRunner(refuseMemory: true),
        ).enhance(_picture(600, 600), workFolder: temp.path, seed: 42, cancel: NativeCancelFlag(), onStep: (_, _) {}),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.outOfMemory)
              .having((error) => error.message, 'message', startsWith(enhanceMemoryMessage)),
        ),
      );
    });

    test('a tile missing is a refused output, never a hole', () async {
      await expectLater(
        backendWith(
          _ScriptRunner(writeTiles: false),
        ).enhance(_picture(600, 600), workFolder: temp.path, seed: 42, cancel: NativeCancelFlag(), onStep: (_, _) {}),
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.outputRejected)),
      );
    });

    test('sd-cli reads the program, the photo, the tiles and the models through ASCII paths', () async {
      // A Windows account named with an accent: its temporary folder and its components, and their short names
      final accented = Directory(p.join(temp.path, 'Frédéric'))..createSync();
      final short = Directory(p.join(temp.path, 'FREDER~1'))..createSync();
      String ascii(String path) => path.replaceAll(accented.path, short.path);
      final runner = _ScriptRunner();
      final picture = _picture(700, 600);
      final out = await backendWith(
        runner,
        files: RebuildFiles(
          sdCli: 'sd-cli',
          dit: p.join(accented.path, 'dit.safetensors'),
          vae: p.join(accented.path, 'vae.safetensors'),
        ),
        asciiPath: ascii,
      ).enhance(picture, workFolder: accented.path, seed: 42, cancel: NativeCancelFlag(), onStep: (_, _) {});
      _expectClose(out, picture.rgba);
      final script = runner.launches.single.arguments[3];
      expect(script, p.join(short.path, 'rebuild.dgl'));
      final program = File(script).readAsStringSync();
      expect(program.codeUnits.every((unit) => unit < 0x80), isTrue);
      expect(
        program,
        contains('dit_path = ${jsonEncode(p.join(short.path, 'dit.safetensors').replaceAll(r'\', '/'))}'),
      );
    });

    test('an ASCII path: its own, else its short name on Windows, else as it is', () {
      expect(rebuildAsciiPath('/tmp/plain', isWindows: true, shortPathOf: (_) => 'X'), '/tmp/plain');
      expect(
        rebuildAsciiPath(r'C:\Users\Frédéric\a', isWindows: true, shortPathOf: (_) => r'C:\Users\FREDER~1\a'),
        r'C:\Users\FREDER~1\a',
      );
      // No short name (8.3 names off on that drive), or one that is not ASCII: as it is
      expect(
        rebuildAsciiPath(r'C:\Users\Frédéric\a', isWindows: true, shortPathOf: (_) => null),
        r'C:\Users\Frédéric\a',
      );
      expect(rebuildAsciiPath('/home/frédéric', isWindows: false, shortPathOf: (_) => 'X'), '/home/frédéric');
    });

    group('on a Mac (the Metal build, not tried on a Mac yet)', () {
      SdCppRebuildBackend onMetal(_ScriptRunner runner) => SdCppRebuildBackend(
        runner: runner,
        settings: SdCppSettings(
          sdCli: p.join(temp.path, 'sd-cli'),
          models: const SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: ''),
          device: sdCppMetalDevice,
          threads: 8,
        ),
        files: const RebuildFiles(sdCli: 'sd-cli', dit: '/m/dit.safetensors', vae: '/m/vae.safetensors'),
        modelSha256: 'c3dec8bcc5916843a8a858572970597462e1f2dc598d6dfd818f6cd40f53a157',
        asciiPath: (path) => path,
      );

      test('no --backend: sd-cli takes the GPU itself; the tiles blend back', () async {
        final runner = _ScriptRunner(metal: true);
        final picture = _picture(700, 600);
        final out = await onMetal(
          runner,
        ).enhance(picture, workFolder: temp.path, seed: 42, cancel: NativeCancelFlag(), onStep: (_, _) {});
        _expectClose(out, picture.rgba);
        expect(runner.launches.single.arguments, [
          '-M',
          'dgl',
          '--script',
          p.join(temp.path, 'rebuild.dgl'),
          '--max-vram',
          '6.0000',
          '-t',
          '8',
          '-v',
        ]);
      });

      for (final line in [
        'ggml_metal_device_init: error: failed to create library',
        'ggml_metal_library_init: error compiling source',
        '[I] auto-fit: --backend "diffusion=CPU,vae=CPU" --- backend_fit.cpp:470',
      ]) {
        test('stopped when sd-cli says the GPU is not used: $line', () async {
          await expectLater(
            onMetal(_ScriptRunner(metal: true, metalLine: line)).enhance(
              _picture(600, 600),
              workFolder: temp.path,
              seed: 42,
              cancel: NativeCancelFlag(),
              onStep: (_, _) {},
            ),
            throwsA(
              isA<BackendException>()
                  .having((error) => error.code, 'code', ImmersiveErrorCode.gpuUnavailable)
                  .having((error) => error.message, 'message', startsWith(enhanceNoMetalMessage)),
            ),
          );
        });
      }

      test('the lines of a run on the GPU are no fall back', () {
        expect(seedVr2MetalUnavailable('ggml_metal_device_init: GPU name:   MTL0 (Apple M1)'), isFalse);
        expect(seedVr2MetalUnavailable('[I] auto-fit: --backend "diffusion=MTL0,vae=MTL0"'), isFalse);
        expect(seedVr2MetalUnavailable('ggml_metal_library_init: using embedded metal library'), isFalse);
      });

      test('Sharpen on a Mac: x4plus with no --backend either', () {
        final settings = SdCppSettings(
          sdCli: 'sd-cli',
          models: const SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: 'x4.pth'),
          device: sdCppMetalDevice,
          threads: 8,
        );
        const request = UpscaleRequest(inputPath: 'in.png', outputPath: 'out.png', workFolder: 'w', scale: 4);
        expect(sdCppUpscaleArguments(settings, request), [
          '-M',
          'upscale',
          '-i',
          'in.png',
          '--upscale-model',
          'x4.pth',
          '-t',
          '8',
          '-v',
          '-o',
          'out.png',
        ]);
        expect(SdCppDevice(settings).name, sdCppMetalDevice);
        // On Vulkan the device is named
        expect(
          sdCppUpscaleArguments(
            SdCppSettings(sdCli: 'sd-cli', models: settings.models, device: 'Vulkan1', threads: 8),
            request,
          ),
          containsAllInOrder(['--backend', 'Vulkan1']),
        );
      });
    });

    test('the budget of the card: 6 GiB, or what is free less 512 MiB', () {
      expect(rebuildVramBudget(null), '6.0000');
      expect(rebuildVramBudget(8 << 30), '6.0000');
      expect(rebuildVramBudget(5 << 30), '4.5000');
      expect(rebuildVramBudget(1 << 30), '1.0000');
    });
  });

  group('Sharpen', () {
    test('half size, x4 in pieces, back to the size of the photo', () async {
      final upscaler = _FourTimes();
      final picture = _picture(2601, 1203);
      final steps = <(int, int)>[];
      final out = await SdCppSharpenBackend(upscaler: upscaler).enhance(
        picture,
        workFolder: temp.path,
        seed: 42,
        cancel: NativeCancelFlag(),
        onStep: (done, all) => steps.add((done, all)),
      );
      expect(out.length, picture.rgba.length);
      // The half picture is 1300 x 601: two pieces across, one down
      expect(upscaler.requests, hasLength(2));
      expect(steps.last, (2, 2));
      expect(upscaler.requests.every((request) => request.scale == 4), isTrue);
      // The same picture, as soft as half its size makes it
      var difference = 0;
      for (var i = 0; i < out.length; i += 4) {
        difference += (out[i] - picture.rgba[i]).abs() + (out[i + 1] - picture.rgba[i + 1]).abs();
      }
      expect(difference / (out.length / 4), lessThan(4));
      expect(sharpenHalfSize(4000, 3000), (2000, 1500));
    });

    test('an output of the wrong size is refused', () async {
      await expectLater(
        SdCppSharpenBackend(
          upscaler: _FourTimes(wrongSize: true),
        ).enhance(_picture(64, 48), workFolder: temp.path, seed: 42, cancel: NativeCancelFlag(), onStep: (_, _) {}),
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.outputRejected)),
      );
    });
  });

  group('Natural', () {
    const files = VosrFiles(
      library: 'ort',
      imageEncoder: 'image_encoder',
      vaeEncoder: 'vae_encoder',
      transformer: 'transformer',
      vaeDecoder: 'vae_decoder',
    );

    test('runs the four graphs on each tile with their names, and gives the photo back when the model does', () {
      final memory = <String, OrtTensor>{};
      final graphs = <String, _Graph>{};
      for (final picture in [_picture(1100, 700), _picture(300, 200)]) {
        final tiles = <(int, int)>[];
        final out = runVosr(
          picture.rgba,
          picture.width,
          picture.height,
          seed: 42,
          isCancelled: () => false,
          onTile: (tile, all) => tiles.add((tile, all)),
          open: (path) => graphs[path] = _Graph(path, memory),
          files: files,
        );
        _expectClose(out, picture.rgba);
        final all = planTiles(
          picture.width < 512 ? 512 : picture.width,
          picture.height < 512 ? 512 : picture.height,
        ).length;
        expect(tiles.last, (all, all));
      }
      final transformer = graphs['transformer']!.seen.first;
      expect(transformer.keys.toSet(), {'lq_latent', 'noise', 'tokens'});
      expect(transformer['noise']!.shape, transformer['lq_latent']!.shape);
      expect(graphs['image_encoder']!.seen.first['lq']!.shape, [1, 3, 512, 512]);
    });

    test('Core ML on Apple silicon, the processor elsewhere', () {
      expect(naturalProviderOf(appleSilicon: true), OrtProvider.coreMl);
      expect(naturalProviderOf(appleSilicon: false), OrtProvider.cpu);
    });

    test('a graph Core ML refuses opens on the processor; a run that fails there goes on on the processor', () {
      final notes = <String>[];
      final opened = <OrtProvider>[];
      final memory = <String, OrtTensor>{};
      // Refused at its opening
      final refused = openVosrGraph(
        '/m/transformer/model.onnx',
        OrtProvider.coreMl,
        open: (provider) {
          opened.add(provider);
          if (provider == OrtProvider.coreMl) {
            throw const OrtException('CreateSession: Core ML could not compile the model');
          }
          return _Graph('transformer', memory);
        },
        note: notes.add,
      );
      expect(opened, [OrtProvider.coreMl, OrtProvider.cpu]);
      expect(refused.firstInput, 'lq');
      expect(notes.single, contains('Core ML refused model.onnx'));

      // Opened, then a run fails: the processor from then on, the run made again there
      notes.clear();
      opened.clear();
      var failing = true;
      final graph = openVosrGraph(
        '/m/vae_decoder/model.onnx',
        OrtProvider.coreMl,
        open: (provider) {
          opened.add(provider);
          return provider == OrtProvider.coreMl && failing ? _FailingGraph() : _Graph('vae_decoder', memory);
        },
        note: notes.add,
      );
      memory['lq'] = OrtTensor(const [1], Float32List(1));
      expect(graph.run({'latent': memory['lq']!}).shape, [1]);
      failing = false;
      expect(opened, [OrtProvider.coreMl, OrtProvider.cpu]);
      expect(notes, [contains('opened with Core ML'), contains('on the processor from now on')]);

      // A stop is never a failure of Core ML
      final stopping = openVosrGraph(
        'x.onnx',
        OrtProvider.coreMl,
        open: (_) => _FailingGraph(stop: true),
        note: (_) {},
      );
      expect(() => stopping.run(const {}), throwsA(isA<OrtRunStopped>()));
      // The processor alone: no note
      notes.clear();
      openVosrGraph('y.onnx', OrtProvider.cpu, open: (_) => _Graph('x', memory), note: notes.add);
      expect(notes, isEmpty);
    });

    test('stops between two graphs when asked', () {
      final memory = <String, OrtTensor>{};
      var calls = 0;
      expect(
        () => runVosr(
          _picture(600, 600).rgba,
          600,
          600,
          seed: 42,
          isCancelled: () => ++calls > 3,
          onTile: (_, _) {},
          open: (path) => _Graph(path, memory),
          files: files,
        ),
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.cancelled)),
      );
    });
  });
}
