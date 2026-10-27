// The real thing, by hand only (lot A4b): Depth Anything V2 Small on the real ONNX Runtime, through
// DartImmersiveEngine, on a folder of photos. Never in the CI, which downloads no model. Each photo gives its 3D photo
// in IMMUCH360_AI_OUT, and a line with the time of each step, the codecs and the threads lowered; the left eye is
// compared with the original decoded alone.
//
//   IMMUCH360_ORT_LIB=~/ai-a4a-ort/onnxruntime-linux-x64-1.31.0/lib/libonnxruntime.so.1.31.0 \
//   IMMUCH360_AI_MODEL=~/ai-a4a-ort/model.onnx IMMUCH360_AI_PHOTOS=~/ai-a4b/photos IMMUCH360_AI_OUT=~/ai-a4b/out \
//   [IMMUCH360_AI_CODEC=auto|dart|native] flutter test test/desktop/ai/engine/engine_real_model_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final library = environment['IMMUCH360_ORT_LIB'];
  final model = environment['IMMUCH360_AI_MODEL'];
  final photos = environment['IMMUCH360_AI_PHOTOS'];
  final out = environment['IMMUCH360_AI_OUT'];
  final missing = [
    if (library == null) 'IMMUCH360_ORT_LIB',
    if (model == null) 'IMMUCH360_AI_MODEL',
    if (photos == null) 'IMMUCH360_AI_PHOTOS',
    if (out == null) 'IMMUCH360_AI_OUT',
  ];

  test(
    'the real model on real photos',
    () async {
      final codec = SbsCodecChoice.values.byName(environment['IMMUCH360_AI_CODEC'] ?? 'auto');
      final engine = DartImmersiveEngine.onnx(
        libraryPath: library!,
        modelPath: model!,
        modelSize: File(model).lengthSync(),
        codec: codec,
      );
      addTearDown(engine.dispose);
      Directory(out!).createSync(recursive: true);
      final files = Directory(photos!).listSync().whereType<File>().where((file) {
        final name = file.path.toLowerCase();
        return name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png');
      }).toList()..sort((a, b) => a.path.compareTo(b.path));
      expect(files, isNotEmpty);

      for (final file in files) {
        final name = p.basename(file.path);
        final target = p.join(out, sbsFileNameFor(name));
        final cancel = NativeCancelFlag();
        final watch = Stopwatch()..start();
        final result = await engine.run(
          ImmersiveJob(
            id: name,
            source: ImmersiveSource(name: name, size: file.lengthSync(), sha1: sha1OfFile(file.path), path: file.path),
            partPath: target,
            derivativeId: StereoPhotoXmp.newDerivativeId(),
            creatorTool: 'Immuch360 Desktop (real model test)',
            created: StereoPhotoXmp.xmpDateTime(DateTime.now()),
            exif: const ImmersiveExif(software: 'Immuch360 Desktop'),
          ),
          cancel: cancel,
        );
        cancel.free();
        final total = watch.elapsedMilliseconds;
        expect(result.isDone, isTrue, reason: '$name: ${result.error} ${result.message}');
        final steps = [
          for (final stage in ImmersiveStage.sbs) '${stage.name} ${result.stageTimes[stage]?.inMilliseconds} ms',
        ].join(', ');
        final outcome = engine.lastOutcome!;

        // The left eye against the original decoded alone (both by package:image, upright): the mean difference of the
        // compression only
        final pair = img.decodeJpg(File(target).readAsBytesSync())!;
        final original = img.decodeJpg(file.readAsBytesSync())!;
        var difference = 0;
        var samples = 0;
        for (var y = 0; y < original.height; y += 7) {
          for (var x = 0; x < original.width; x += 7) {
            final a = pair.getPixel(x, y);
            final b = original.getPixel(x, y);
            difference += (a.r - b.r).abs().toInt() + (a.g - b.g).abs().toInt() + (a.b - b.b).abs().toInt();
            samples += 3;
          }
        }
        // ignore: avoid_print
        print(
          '$name: ${result.eyeWidth} x ${result.eyeHeight} per eye, ${File(target).lengthSync()} bytes, '
          'total $total ms ($steps); decoder ${outcome.decoder}, encoder ${outcome.encoder}, '
          '${outcome.threadsLowered} threads lowered; flags ${result.qualityFlags.map((flag) => flag.xmp).join(',')}; '
          'left eye against the original: mean difference ${(difference / samples).toStringAsFixed(2)} of 255',
        );
        expect(difference / samples, lessThan(4));
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: missing.isEmpty ? null : 'by hand: set ${missing.join(', ')}',
  );
}
