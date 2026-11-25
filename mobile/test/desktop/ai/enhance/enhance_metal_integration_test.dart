// Sharpen and Rebuild details through the Metal build of sd-cli on the macOS runner of the CI (release 53, job
// sdcpp-seedvr2-macos): the backends of the app, with their arguments (no --backend on a Mac), their reading of the
// lines of sd-cli (a GPU not used stops Rebuild details) and their blend, on the program the job built and the real
// models. The runner is a virtual Mac whose GPU is "Apple Paravirtual device": what passes here proves that the program
// starts, loads the models and runs a tile there, or stops and says why; not the speed nor the memory of a real Mac.
//
// IMMUCH360_ENHANCE_METAL is a JSON object: sdCli (the program), upscaler (Real-ESRGAN x4plus), and optionally dit and
// vae (SeedVR2 3B int8 and its VAE) and out (a folder where the logs of sd-cli and the outcome are kept).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/rebuild_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_probe.dart' show SystemProcessRunner;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

SbsDecoded _picture(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = 4 * (y * width + x);
      rgba[i] = x * 255 ~/ width;
      rgba[i + 1] = y * 255 ~/ height;
      rgba[i + 2] = ((x ~/ 16 + y ~/ 16).isEven ? 60 : 190);
      rgba[i + 3] = 255;
    }
  }
  return SbsDecoded(width: width, height: height, rgba: rgba);
}

void main() {
  final given = Platform.environment['IMMUCH360_ENHANCE_METAL'];
  final args = given == null ? const <String, dynamic>{} : jsonDecode(given) as Map<String, dynamic>;
  final skip = given == null ? 'IMMUCH360_ENHANCE_METAL not set' : null;
  final out = args['out'] as String?;
  final outcome = <String, Object?>{};
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('enhance-metal-'));
  tearDown(() {
    final log = File(p.join(work.path, 'logs', 'sd-cli.log'));
    if (out != null && log.existsSync()) {
      Directory(out).createSync(recursive: true);
      File(p.join(out, 'sd-cli.log')).writeAsStringSync(log.readAsStringSync(), mode: FileMode.append);
    }
    if (log.existsSync()) {
      // ignore: avoid_print
      print(log.readAsStringSync());
    }
    work.deleteSync(recursive: true);
  });
  tearDownAll(() {
    if (out != null) {
      Directory(out).createSync(recursive: true);
      File(p.join(out, 'outcome.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(outcome));
    }
  });

  SdCppSettings settings({String upscaler = ''}) => SdCppSettings(
    sdCli: args['sdCli'] as String,
    models: SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: upscaler),
    device: sdCppMetalDevice,
    stallTimeout: const Duration(minutes: 15),
  );

  test('Sharpen: x4plus on the GPU of the Mac through the backend of the app', skip: skip, () async {
    final picture = _picture(320, 240);
    final watch = Stopwatch()..start();
    final backend = SdCppSharpenBackend(
      upscaler: SdCppUpscaler(
        runner: const SystemProcessRunner(),
        settings: settings(upscaler: args['upscaler'] as String),
        modelSha256: 'x4plus',
      ),
    );
    final result = await backend.enhance(
      picture,
      workFolder: work.path,
      seed: 42,
      cancel: NativeCancelFlag(),
      onStep: (_, _) {},
    );
    outcome['sharpen'] = {'ms': watch.elapsedMilliseconds, 'width': 320, 'height': 240, 'bytes': result.length};
    expect(result.length, picture.rgba.length);
  });

  test(
    'Rebuild details: one tile of SeedVR2 on the GPU of the Mac, or a stop that says the GPU was not used',
    skip: skip ?? (args['dit'] == null ? 'no SeedVR2 given' : null),
    () async {
      final picture = _picture(512, 512);
      final watch = Stopwatch()..start();
      final backend = SdCppRebuildBackend(
        runner: const SystemProcessRunner(),
        settings: settings(),
        files: RebuildFiles(sdCli: args['sdCli'] as String, dit: args['dit'] as String, vae: args['vae'] as String),
        modelSha256: 'seedvr2',
      );
      final steps = <int>[];
      try {
        final result = await backend.enhance(
          picture,
          workFolder: work.path,
          seed: 42,
          cancel: NativeCancelFlag(),
          onStep: (done, _) => steps.add(done),
        );
        outcome['rebuild'] = {
          'ms': watch.elapsedMilliseconds,
          'steps': steps.length,
          'fellBack': backend.fellBack,
          'bytes': result.length,
        };
        expect(result.length, picture.rgba.length);
      } on BackendException catch (error) {
        outcome['rebuild'] = {'ms': watch.elapsedMilliseconds, 'code': error.code.name, 'message': error.message};
        // ignore: avoid_print
        print('Rebuild details stopped: ${error.code.name}: ${error.message}');
        // A stop the app says in words is an honest outcome on a virtual GPU; anything else is a failure
        expect(
          error.message.startsWith(enhanceNoMetalMessage) || error.code == ImmersiveErrorCode.outOfMemory,
          isTrue,
          reason: error.message,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
