// The ONNX Runtime side of the engine of the 360° panoramas (lot P3) on the tiny models of lot C1, which have the names,
// types and ranks of MoGe-2 and MI-GAN (make_tiny_models.py): the models of a panorama opened in the isolate of the
// step that needs them, MI-GAN given the seam with the pixels of its holes, refused when they are not the models asked
// for, and a whole panorama made with its steps sent to isolates of their own as the app runs them, the generator and
// the upscaler fakes. Skipped without IMMUCH360_ORT_LIB (see ort_for_tests.dart); the desktop workflow runs it on ONNX
// Runtime 1.31.0 and 1.23.2 under Linux and 1.31.0 under Windows.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_backends.dart';
import '../ort/ort_for_tests.dart';
import '../scene/scene_test_support.dart';

List<SbsCodec> _dartCodecs() => const [DartSbsCodec()];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ort = ortForTests();
  final skip = ort.skip;

  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('panorama_engine_ort_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  OrtPanoramaModelsSpec spec({String moge = 'tiny_moge.onnx', String migan = 'tiny_migan.onnx'}) =>
      OrtPanoramaModelsSpec(
        libraryPath: ort.library!,
        miganPath: tinyModelPath(migan),
        inpaintSha256: '4' * 64,
        mogePath: tinyModelPath(moge),
        mogeSha256: '3' * 64,
      );

  test('MoGe-2 and MI-GAN opened as the steps open them, and given back', () {
    final geometry = spec().openGeometry()!;
    final maps = geometry.estimate(Float32List(3 * 24 * 16), width: 24, height: 16);
    expect((maps.width, maps.height), (24, 16));
    geometry.close();
    final inpaint = spec().openInpaint();
    final filled = inpaint.fill(
      InpaintRegion(width: 8, height: 4, rgb: Uint8List(96), mask: Uint8List.fromList(List.filled(32, 255))..[5] = 0),
    );
    expect(filled, hasLength(96));
    inpaint.close();
  }, skip: skip);

  test('the MI-GAN of the seam keeps the pixels of its holes: no line of the mean colour along the band', () {
    // The first run on the RTX 4060 saw bright lines along both edges of the band while its holes were painted with the
    // mean colour of the known pixels: MI-GAN blends the first pixels of its fill with what lies under a hole
    final inpaint = spec().openInpaint();
    addTearDown(inpaint.close);
    // Two pixels across, one known (10, 20, 30), one a hole holding the panorama's own (200, 100, 50)
    final region = InpaintRegion(
      width: 2,
      height: 1,
      rgb: Uint8List.fromList([10, 20, 30, 200, 100, 50]),
      mask: Uint8List.fromList([255, 0]),
    );
    final (image, mask) = panoramaMiganInputsOf(inpaint, region);
    expect(image, [10, 200, 20, 100, 30, 50], reason: 'planes of one colour, the hole as the panorama has it');
    expect(mask, [255, 0]);
    expect(inpaint.fill(region), hasLength(6));
  }, skip: skip);

  test('a model that is not the one asked for is refused: modelFailed', () {
    expect(
      () => spec(migan: 'tiny_moge.onnx').openInpaint(),
      throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.modelFailed)),
    );
    expect(
      () => spec(moge: 'tiny_migan.onnx').openGeometry(),
      throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.modelFailed)),
    );
  }, skip: skip);

  test('a panorama made with its steps in isolates of their own, on MoGe-2 and MI-GAN', () async {
    final path = scenePhoto(folder, 'salon.jpg', width: 48, height: 32);
    final bytes = File(path).readAsBytesSync();
    final job = PanoramaJob(
      id: 'ort',
      source: ImmersiveSource(name: 'salon.jpg', size: bytes.length, sha1: '', path: path),
      partPath: p.join(folder.path, '.salon_360.jpg.1-1.immuch360.part'),
      derivativeId: 'derivative',
      creatorTool: 'test',
      created: '2026-10-28T18:00:00+01:00',
      generator: 'flux2-klein-base-4b-q4_0',
      steps: 3,
      seed: 7,
    );
    final cancel = NativeCancelFlag();
    addTearDown(cancel.free);
    final result = await PanoramaEngine(
      generator: FakeGeneratorBackend(),
      upscaler: FakeUpscaleBackend(),
      models: spec(),
      folders: AiWorkFolders(Directory(p.join(folder.path, 'work'))),
      codecs: _dartCodecs,
      sizes: const PanoramaSizes(
        controlWidth: 64,
        controlHeight: 32,
        generationWidth: 48,
        generationHeight: 24,
        scale: 4,
        padding: 4,
      ),
    ).run(job, cancel: cancel);
    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    final xmp = ImmersiveXmp.findIn(File(job.partPath).readAsBytesSync())! as PanoramaXmp;
    expect((xmp.width, xmp.height), (192, 96));
    expect(xmp.qualityFlags, contains(ReliefQualityFlag.fovGuessed));
  }, skip: skip);
}
