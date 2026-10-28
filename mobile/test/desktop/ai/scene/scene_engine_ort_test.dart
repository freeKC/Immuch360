// The ONNX Runtime side of the scene engine (lot S1) on the tiny models of lot C1, which have the names, types and
// ranks of the real ones (make_tiny_models.py): the checks of MoGe-2, LaMa and MI-GAN, their runs, the padding of a
// small region, and a whole scene made by SceneEngine.onnx in its worker, its sessions kept and its run options given
// back. Skipped without IMMUCH360_ORT_LIB (see ort_for_tests.dart); the desktop workflow runs them on ONNX Runtime
// 1.31.0 and 1.23.2 under Linux and 1.31.0 under Windows. With IMMUCH360_SCENE_OUT, the scene written is copied there
// for the glTF-Validator of the next step of the workflow.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/scene/lama_inpaint.dart';
import 'package:immich_mobile/desktop/ai/scene/migan_inpaint.dart';
import 'package:immich_mobile/desktop/ai/scene/moge_geometry.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_thread_priority.dart';
import '../ort/ort_for_tests.dart';
import 'scene_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ort = ortForTests();
  final skip = ort.skip;

  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('scene_engine_ort_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  OrtSession open(String model) {
    final session = OrtRuntime.load(ort.library!).openSession(tinyModelPath(model));
    addTearDown(session.close);
    return session;
  }

  test('MoGe-2, LaMa and MI-GAN are told apart by their names, types and ranks', () {
    final moge = open('tiny_moge.onnx');
    final lama = open('tiny_lama.onnx');
    final migan = open('tiny_migan.onnx');

    expect(mogeRefusalOf(moge.inputs, moge.outputs), isNull);
    expect(lamaRefusalOf(lama.inputs, lama.outputs), isNull);
    expect(miganRefusalOf(migan.inputs, migan.outputs), isNull);
    expect(mogeRefusalOf(lama.inputs, lama.outputs), isNotNull);
    expect(lamaRefusalOf(migan.inputs, migan.outputs), isNotNull);
    expect(miganRefusalOf(moge.inputs, moge.outputs), isNotNull);
  }, skip: skip);

  test('MoGe-2 runs on an image of any size with its tokens: points, mask and the metric scale', () {
    final moge = open('tiny_moge.onnx');
    const width = 7;
    const height = 5;
    final input = exactValues(3 * width * height);
    final maps = OrtMogeGeometry(session: () => moge, modelSha256: 'sum').estimate(input, width: width, height: height);

    expect(maps.metricScale, mogeTokens / TinyModels.load().mogeScaleDivisor);
    expect((maps.width, maps.height), (width, height));
    for (var i = 0; i < width * height; i++) {
      // tiny_moge: points = 2 t - 1 of the image turned channels last, mask = its first channel
      for (var c = 0; c < 3; c++) {
        expect(maps.points[3 * i + c], 2 * input[c * width * height + i] - 1);
      }
      expect(maps.mask[i], input[i]);
    }
    expect(
      () => OrtMogeGeometry(session: () => moge, modelSha256: 'sum').estimate(input, width: width + 1, height: height),
      throwsArgumentError,
    );
  }, skip: skip);

  test('LaMa fills the holes of a region padded to 512, the known pixels as they were', () {
    final lama = open('tiny_lama.onnx');
    final backend = OrtLamaInpaint(session: () => lama, modelSha256: 'sum');
    for (final (width, height) in [(512, 512), (300, 200), (512, 341)]) {
      final rgb = Uint8List.fromList([for (var i = 0; i < 3 * width * height; i++) (i * 7) % 251]);
      final mask = Uint8List(width * height)..fillRange(0, width * height, 255);
      for (var y = height ~/ 3; y < height ~/ 2; y++) {
        mask.fillRange(y * width + 10, y * width + width ~/ 2, 0);
      }
      final out = backend.fill(InpaintRegion(width: width, height: height, rgb: rgb, mask: mask));

      for (var i = 0; i < width * height; i++) {
        for (var c = 0; c < 3; c++) {
          // tiny_lama paints the holes 0.5 times 255: 127.5, rounded to the nearest level
          expect(out[3 * i + c], mask[i] == 0 ? 128 : rgb[3 * i + c], reason: '$width x $height, pixel $i');
        }
      }
    }
    expect(reflectIndex(-1, 5), 1);
    expect(reflectIndex(5, 5), 3);
    expect(reflectIndex(9, 5), 1);
    expect(reflectIndex(3, 1), 0);
  }, skip: skip);

  test('MI-GAN fills the holes painted with the mean colour first, the known pixels as they were', () {
    final migan = open('tiny_migan.onnx');
    const width = 40;
    const height = 30;
    final rgb = Uint8List.fromList([for (var i = 0; i < 3 * width * height; i++) (i * 13) % 256]);
    final mask = Uint8List(width * height)..fillRange(0, width * height, 255);
    mask.fillRange(5 * width, 9 * width, 0);
    final out = OrtMiganInpaint(
      session: () => migan,
      modelSha256: 'sum',
    ).fill(InpaintRegion(width: width, height: height, rgb: rgb, mask: mask));

    for (var i = 0; i < width * height; i++) {
      for (var c = 0; c < 3; c++) {
        expect(out[3 * i + c], mask[i] == 0 ? TinyModels.load().miganHole : rgb[3 * i + c]);
      }
    }
  }, skip: skip);

  test('a whole scene on the tiny models: written, read back, the sessions kept, the run options given back', () async {
    // tiny_moge reads its points in the colours: red over 0.5 for a valid mask and x growing to the right, green for
    // y growing downwards, blue for the depth (a near left half, a far right half)
    final image = img.Image(width: 64, height: 48);
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < 64; x++) {
        image.setPixelRgb(x, y, 140 + x, 40 + 3 * y, x < 32 ? 90 : 240);
      }
    }
    final path = p.join(folder.path, 'tiny.jpg');
    File(path).writeAsBytesSync(img.encodeJpg(image, quality: 95));
    final engine = SceneEngine(
      models: OrtSceneModelsSpec(
        libraryPath: ort.library!,
        mogePath: tinyModelPath('tiny_moge.onnx'),
        mogeSha256: 'a' * 64,
        lamaPath: tinyModelPath('tiny_lama.onnx'),
        lamaSha256: 'b' * 64,
        geometryModel: mogeGeometryComponent.id,
        inpaintModel: lamaInpaintComponent.id,
      ),
      codec: SbsCodecChoice.auto,
      priority: FakeThreadPriority(threads: {1: 'main'}),
    );
    addTearDown(engine.dispose);
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    final part = scenePartIn(folder, 'tiny.jpg');
    final result = await engine.run(
      sceneJobFor(path, partPath: part, sha1: sha1OfFile(path)),
      cancel: cancel,
    );

    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    final bytes = File(part).readAsBytesSync();
    final xmp = ImmersiveXmp.findIn(bytes)! as SceneXmp;
    final glb = GlbView.read(sceneBytesOf(bytes, xmp)!);
    expect(xmp.geometryModelSha256, 'a' * 64);
    expect(xmp.inpaintModelSha256, 'b' * 64);
    expect(xmp.request, isNotNull);
    expect(glb.list('meshes'), hasLength(xmp.sceneMeshes));
    final status = await engine.worker!.status();
    expect(status.openSessions, contains(mogeSession));
    expect(status.openSessions.toSet().difference({mogeSession, lamaSession}), isEmpty);
    expect(status.runOptionsAlive, 0, reason: 'given back once the root isolate let them go');
    expect(engine.lastOutcome!.regions > 0, status.openSessions.contains(lamaSession));

    final out = Platform.environment['IMMUCH360_SCENE_OUT'];
    if (out != null && out.isNotEmpty) {
      Directory(out).createSync(recursive: true);
      File(part).copySync(p.join(out, 'tiny_models_scene3D.jpg'));
    }
  }, skip: skip);

  test('a model that is not MoGe-2: modelFailed with the reason, its session not kept', () async {
    final path = scenePhoto(folder, 'salon.jpg');
    final engine = SceneEngine(
      models: OrtSceneModelsSpec(
        libraryPath: ort.library!,
        mogePath: tinyModelPath('tiny_lama.onnx'),
        mogeSha256: 'a' * 64,
        lamaPath: tinyModelPath('tiny_lama.onnx'),
        lamaSha256: 'b' * 64,
        geometryModel: mogeGeometryComponent.id,
        inpaintModel: lamaInpaintComponent.id,
      ),
      codec: SbsCodecChoice.dart,
      priority: FakeThreadPriority(threads: {1: 'main'}),
    );
    addTearDown(engine.dispose);
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    final result = await engine.run(
      sceneJobFor(path, partPath: scenePartIn(folder, 'salon.jpg'), sha1: sha1OfFile(path)),
      cancel: cancel,
    );

    expect(result.error, ImmersiveErrorCode.modelFailed);
    expect(result.message, startsWith('Not MoGe-2'));
    expect((await engine.worker!.status()).openSessions, isEmpty);
    expect(File(scenePartIn(folder, 'salon.jpg')).existsSync(), isFalse);
  }, skip: skip);

  test('the scene engine keeps the order of its constants', () {
    expect(SceneProgress.inpaint, lessThan(SceneProgress.mesh));
    expect(SceneV1.inpaintRegionMax, 512);
  });
}
