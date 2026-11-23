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
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_tensor.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart' show decodePngPicture, encodePngPicture;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_process_runner.dart';

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

/// sd-cli in script mode as far as the backend sees it: its device list, the items of each phase, and each tile
/// written as the crop of the input it was given (or not written)
class _ScriptRunner implements ProcessRunner {
  _ScriptRunner({this.intDot = 1, this.refuseMemory = false, this.writeTiles = true});

  final int intDot;
  final bool refuseMemory;
  final bool writeTiles;
  final launches = <ProcessLaunch>[];

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    launches.add(launch);
    final script = File(launch.arguments[launch.arguments.indexOf('--script') + 1]).readAsStringSync();
    final input = RegExp(r'input_path = "([^"]+)"').firstMatch(script)!.group(1)!;
    final picture = decodePngPicture(File(input).readAsBytesSync());
    final tiles = RegExp(r'\{x = (\d+), y = (\d+), path = "([^"]+)"\}').allMatches(script).toList();
    final width = int.parse(RegExp(r'tile_w = (\d+)').firstMatch(script)!.group(1)!);
    final height = int.parse(RegExp(r'tile_h = (\d+)').firstMatch(script)!.group(1)!);
    if (writeTiles && !refuseMemory) {
      for (final tile in tiles) {
        final x = int.parse(tile.group(1)!);
        final y = int.parse(tile.group(2)!);
        final crop = cropRgbaAt(picture.rgba, picture.width, x, y, width, height);
        File(tile.group(3)!).writeAsBytesSync(encodePngPicture(SbsDecoded(width: width, height: height, rgba: crop)));
      }
    }
    final count = tiles.length;
    final lines = <(String, {bool isError})>[
      ('ggml_vulkan: Found 2 Vulkan devices:', isError: false),
      (
        'ggml_vulkan: 0 = Intel(R) UHD Graphics (Intel Corporation) | uma: 1 | fp16: 1 | int dot: 1 | matrix cores: none',
        isError: false,
      ),
      (
        'ggml_vulkan: 1 = NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA) | uma: 0 | fp16: 1 | int dot: $intDot | '
            'matrix cores: NV_coopmat2',
        isError: false,
      ),
      if (refuseMemory)
        ('[E] RAM graph capacity exceeded. Requested 3892568608 bytes, 708513792 bytes available', isError: true),
      if (!refuseMemory)
        for (final phase in ['encode', 'sample', 'decode'])
          for (var item = 1; item <= count; item++)
            ('[V] map ${phase}_tile: item $item/$count --- executor.cpp:168', isError: false),
    ];
    return FakeRunningProcess(
      4000 + launches.length,
      launch,
      FakeProcessScript(lines: lines, exitCode: refuseMemory ? 1 : 0),
    );
  }
}

/// x4plus as far as the backend sees it: each pixel made four by four, or a picture of the wrong size
class _FourTimes implements UpscaleBackend {
  _FourTimes({this.wrongSize = false});

  final bool wrongSize;
  final requests = <UpscaleRequest>[];

  @override
  String get modelSha256 => '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1';

  @override
  Future<void> upscale(
    UpscaleRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    requests.add(request);
    final picture = decodePngPicture(File(request.inputPath).readAsBytesSync());
    final scale = wrongSize ? 3 : request.scale;
    final width = picture.width * scale;
    final height = picture.height * scale;
    final out = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final from = 4 * ((y ~/ scale) * picture.width + x ~/ scale);
        out.setRange(4 * (y * width + x), 4 * (y * width + x) + 4, picture.rgba, from);
      }
    }
    File(request.outputPath).writeAsBytesSync(encodePngPicture(SbsDecoded(width: width, height: height, rgba: out)));
  }
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

    SdCppRebuildBackend backendWith(_ScriptRunner runner) => SdCppRebuildBackend(
      runner: runner,
      settings: settings(),
      files: const RebuildFiles(sdCli: 'sd-cli', dit: '/m/dit.safetensors', vae: '/m/vae.safetensors'),
      modelSha256: 'c3dec8bcc5916843a8a858572970597462e1f2dc598d6dfd818f6cd40f53a157',
      graphicsFree: 7 << 30,
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
