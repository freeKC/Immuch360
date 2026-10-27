// DartImmersiveEngine on the real ONNX Runtime with the tiny model (lot A4b): a photo made 3D through the worker
// isolate, the session opened there with its threads lowered and kept for the next job, and the hardware gate's
// load of the library in a short isolate. Needs IMMUCH360_ORT_LIB (ort_for_tests.dart); the CI runs it on ONNX
// Runtime 1.31.0 and 1.23.2 under Linux and 1.31.0 under Windows.

import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

import '../engine/engine_test_support.dart';
import 'ort_for_tests.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ort = ortForTests();

  group('ONNX Runtime from IMMUCH360_ORT_LIB, the tiny model', () {
    late Directory folder;
    late NativeCancelFlag cancel;
    setUp(() {
      folder = Directory.systemTemp.createTempSync('ort_engine_test_');
      cancel = NativeCancelFlag();
    });
    tearDown(() {
      cancel.free();
      folder.deleteSync(recursive: true);
    });

    test('a photo made 3D in the worker; the session opened there, its threads lowered, kept for the next', () async {
      final model = File(tinyDepthModelPath());
      final modelSha256 = sha256.convert(model.readAsBytesSync()).toString();
      final engine = DartImmersiveEngine.onnx(
        libraryPath: ort.library!,
        modelPath: model.path,
        librarySize: File(ort.library!).lengthSync(),
        modelSize: model.lengthSync(),
        modelSha256: modelSha256,
      );
      addTearDown(engine.dispose);

      final part = partIn(folder, 'exif_camera.jpg');
      final result = await engine.run(jobFor(codecFixturePath('exif_camera.jpg'), partPath: part), cancel: cancel);
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expect((result.eyeWidth, result.eyeHeight), (32, 64));
      final xmp = StereoPhotoXmp.findIn(File(part).readAsBytesSync())!;
      expect(xmp.depthModelSha256, modelSha256);

      // The session's own threads: intra-op is the logical processors minus two, the calling thread one of them;
      // ONNX Runtime 1.31.0 starts one more at the first session of the process; Windows may start threads of its own
      // meanwhile, which it does not name
      final born = math.max(1, Platform.numberOfProcessors - 2) - 1;
      final lowered = engine.lastOutcome!.threadsLowered;
      expect(
        lowered,
        Platform.isLinux
            ? inInclusiveRange(born, born + 1)
            : Platform.isWindows
            ? greaterThanOrEqualTo(born)
            : 0,
      );

      final second = await engine.run(
        jobFor(codecFixturePath('orientation_6.jpg'), partPath: partIn(folder, 'orientation_6.jpg'), quarterTurns: 3),
        cancel: cancel,
      );
      expect(second.isDone, isTrue, reason: '${second.error}: ${second.message}');
      expect(engine.lastOutcome!.threadsLowered, 0, reason: 'the session was kept: no thread born');
      expect((await engine.worker!.status()).sessionOpen, isTrue);
    });

    test('a model that is not there: componentsMissing before the worker starts', () async {
      final engine = DartImmersiveEngine.onnx(libraryPath: ort.library!, modelPath: '${folder.path}/none.onnx');
      addTearDown(engine.dispose);
      final result = await engine.run(
        jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')),
        cancel: cancel,
      );
      expect(result.error, ImmersiveErrorCode.componentsMissing);
      expect(engine.worker, isNull);
    });

    test('the gate loads the library in a short isolate and gives its version', () async {
      final load = await loadRuntimeInIsolate(ort.library!);
      expect(load.error, isNull);
      expect(load.version, matches(RegExp(r'^1\.\d+\.\d+')));
    });
  }, skip: ort.skip);
}
