// The engine of the 3D scenes (lot S1, design-final 2026-10-27, section 10.1, point 6) with the fakes of each seam: the
// chain in this isolate (every step, its failures, the cancel at each step, the files it leaves), then the engine with
// its worker (the original read on the root isolate, the job run as a task). The same engine on the real ONNX Runtime
// with the tiny models: scene_engine_ort_test.dart; with the real models on real photos, by hand: real_scene_test.dart.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_engine.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart'
    show parseGPanoProjectionType;
import 'package:path/path.dart' as p;

import '../fakes/fake_backends.dart';
import '../fakes/fake_thread_priority.dart';
import 'scene_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('scene_engine_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  /// Runs the chain on the photo at [path] in this isolate
  SceneOutcome runChain(
    String path, {
    SceneModels? models,
    int quarterTurns = 0,
    bool Function()? isCancelled,
    void Function(ImmersiveProgress progress)? onProgress,
    PartWriter writePart = writePartFile,
    String? glbPartPath,
    String? sha1,
    String? partPath,
  }) {
    final job = sceneJobFor(
      path,
      partPath: partPath ?? scenePartIn(folder, p.basename(path)),
      sha1: sha1 ?? sha1OfFile(path),
      quarterTurns: quarterTurns,
      glbPartPath: glbPartPath,
    );
    return SceneChain(models: models ?? fakeSceneModels(), codecs: const [DartSbsCodec()], writePart: writePart).run(
      job,
      ChainOriginal(bytes: File(path).readAsBytesSync()),
      isCancelled: isCancelled ?? () => false,
      onProgress: onProgress,
    );
  }

  /// The scene file written for the photo [name], its packet and its glb read back
  ({Uint8List bytes, SceneXmp xmp, GlbView glb}) written(String name) {
    final bytes = File(scenePartIn(folder, name)).readAsBytesSync();
    final xmp = ImmersiveXmp.findIn(bytes)! as SceneXmp;
    final glb = sceneBytesOf(bytes, xmp);
    expect(glb, isNotNull, reason: 'the tail is where the packet says, with its sum');
    return (bytes: bytes, xmp: xmp, glb: GlbView.read(glb!));
  }

  group('the chain', () {
    test('a photo with a break: two layers, a packet that says what the glb holds, the original untouched', () {
      final path = scenePhoto(folder, 'salon.jpg');
      final before = File(path).readAsBytesSync();
      final inpaint = FakeInpaintBackend();
      final outcome = runChain(path, models: fakeSceneModels(inpaint: inpaint));

      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      expect(File(path).readAsBytesSync(), before, reason: 'the original is never written');
      final file = written('salon.jpg');
      final xmp = file.xmp;
      final glb = file.glb;
      final details = outcome.result.details! as SceneResultDetails;

      // The packet
      expect(xmp.kind, ImmersiveKind.volumetricScene);
      expect(xmp.origin, ImmersiveOrigin.reconstructedFromPhoto);
      expect(xmp.pipeline, SceneV1.pipeline);
      expect(xmp.sceneFormat, glbLayersV1);
      expect(xmp.digitalSourceType, iptcCompositeWithTrainedAlgorithmicMedia);
      expect(xmp.description, sceneDescription);
      expect(xmp.gridStep, SceneV1.gridStepFor(48, 32));
      expect(xmp.geometryModel, mogeGeometryComponent.id);
      expect(xmp.geometryModelSha256, FakeGeometryBackend().modelSha256);
      expect(xmp.inpaintModel, lamaInpaintComponent.id);
      expect(xmp.inpaintModelSha256, FakeInpaintBackend().modelSha256);
      expect(xmp.sourceName, 'salon.jpg');
      expect(xmp.sourceSize, before.length);
      expect(xmp.sourceSha1, sha1OfFile(path));
      expect(xmp.sourceQuarterTurns, 0);
      expect(xmp.creatorTool, 'Immuch360 Desktop 3.4.0 (linux)');
      expect(xmp.derivativeId, 'urn:uuid:7a2d3f1b-0000-4000-8000-000000000002');
      expect(xmp.created, '2026-10-28T10:12:00+01:00');
      expect(xmp.fieldOfViewSource, FieldOfViewSource.model);
      expect(xmp.qualityFlags, outcome.result.qualityFlags);
      expect(xmp.qualityFlags, contains(ReliefQualityFlag.fovGuessed), reason: 'no EXIF');
      expect(xmp.settingsKey, '${xmp.geometryModelSha256}|${xmp.inpaintModelSha256}|scene-v1|4|0');
      expect(xmp.request, isNotNull, reason: 'the headset gets its request from the packet');

      // The glb, as the readers take it
      expect(glb.list('meshes'), hasLength(xmp.sceneMeshes));
      expect(details.meshes, xmp.sceneMeshes);
      expect(xmp.sceneMeshes, 2, reason: 'the photo layer and the background');
      var vertices = 0;
      var triangles = 0;
      for (var mesh = 0; mesh < glb.list('meshes').length; mesh++) {
        final primitive = glb.primitive(mesh);
        final attributes = (primitive['attributes'] as Map).cast<String, int>();
        final positions = glb.floats(attributes['POSITION']!);
        final indices = glb.indices(primitive['indices'] as int);
        final accessor = glb.list('accessors')[attributes['POSITION']!];
        expect(glb.list('accessors')[primitive['indices'] as int]['componentType'], 5125, reason: 'uint32 only');
        expect(primitive['mode'], 4);
        vertices += positions.length ~/ 3;
        triangles += indices.length ~/ 3;
        expect(indices.every((index) => index < positions.length ~/ 3), isTrue);
        for (var c = 0; c < 3; c++) {
          final values = [for (var i = c; i < positions.length; i += 3) positions[i]];
          expect((accessor['min'] as List)[c], values.reduce(math.min));
          expect((accessor['max'] as List)[c], values.reduce(math.max));
        }
        // Every point in front of the camera (glTF looks towards -z)
        for (var i = 2; i < positions.length; i += 3) {
          expect(positions[i], lessThan(0));
        }
      }
      expect(vertices, xmp.sceneVertices);
      expect(triangles, xmp.sceneTriangles);
      expect(details.vertices, vertices);
      expect(details.triangles, triangles);
      expect(glb.imageOf(0), 0, reason: 'the photo layer shows images[0]');
      expect(glb.imageOf(1), 1, reason: 'the background shows the filled map');
      final photo = const DartSbsCodec().decodeJpeg(glb.image(0));
      final background = const DartSbsCodec().decodeJpeg(glb.image(1));
      expect((photo.width, photo.height), (48, 32));
      expect((background.width, background.height), (48, 32));
      expect(xmp.sceneTextureMax, 48);
      expect(glb.list('nodes').first['children'], [1, 2]);
      expect(glb.list('nodes').skip(1).every((node) => node.keys.toList().join() == 'mesh'), isTrue);
      expect(glb.extras['format'], glbLayersV1);
      expect(SceneSafeZone.fromJson(glb.extras['safe']), xmp.safe);
      expect(glb.extras['scale'], xmp.sceneScale);
      expect(glb.extras['fovDegrees'], xmp.fieldOfView);
      expect((glb.json['asset'] as Map)['generator'], 'Immuch360 Desktop 3.4.0 scene-v1');
      final packet = (((glb.json['extensions'] as Map)['KHR_xmp_json_ld'] as Map)['packets'] as List).single as Map;
      expect(packet['Immuch360:Kind'], 'VolumetricScene');
      expect(packet['Immuch360:SourceSha1'], xmp.sourceSha1);
      expect(packet['Iptc4xmpExt:DigitalSourceType'], iptcCompositeWithTrainedAlgorithmicMedia);
      expect(packet.containsKey('Immuch360:SceneLength'), isFalse, reason: 'the glb cannot hold its own length');
      expect(((packet['dc:description'] as Map)['rdf:_1'] as Map)['@value'], sceneDescription);

      // The zone and the details
      expect(details.safe, xmp.safe);
      expect(details.scale, xmp.sceneScale);
      expect(details.hiddenFraction, xmp.hiddenFraction);
      expect(details.fieldOfView, xmp.fieldOfView);
      expect(xmp.safe!.lateral, inInclusiveRange(SceneV1.lateralMin, SceneV1.lateralMax));
      expect(inpaint.regions, hasLength(outcome.regions));
      expect(outcome.regions, greaterThan(0));
      for (final region in inpaint.regions) {
        expect(region.width, lessThanOrEqualTo(SceneV1.inpaintRegionMax));
        expect(region.mask.where((value) => value == 0), isNotEmpty);
      }
    });

    test('the preview is the photo seen from the start: a JPEG of its size, the packet first, its EXIF', () {
      final path = scenePhoto(folder, 'salon.jpg');
      runChain(path);
      final file = written('salon.jpg');
      final tail = sceneTailOf(fileLength: file.bytes.length, xmp: file.xmp)!;
      final preview = Uint8List.sublistView(file.bytes, 0, tail.offset);
      final header = JpegHeader.read(preview);

      expect((header.width, header.height), (48, 32));
      expect(preview.sublist(preview.length - 2), [0xFF, 0xD9], reason: 'the JPEG ends before the scene');
      expect(header.exif, isNotNull);
      expect(xmpPacketsOf(preview), hasLength(1));
      expect(const DartSbsCodec().decodeJpeg(preview).width, 48);
    });

    test('the phase 1 reads it as a flat photo of its library, the scanner as a scene', () {
      final path = scenePhoto(folder, 'salon.jpg');
      runChain(path);
      final partPath = scenePartIn(folder, 'salon.jpg');
      final target = p.join(folder.path, 'salon_scene3D.jpg');
      File(partPath).copySync(target);
      final head = File(target).readAsBytesSync();

      expect(probeStereoPhotoHead(head, name: 'salon_scene3D.jpg'), isNull, reason: 'no side by side photo');
      expect(parseGPanoProjectionType(String.fromCharCodes(head)), isNull, reason: 'no 360° photo');
      final metadata = readMediaMetadataSync(target, LibraryMediaKind.image);
      expect(metadata.immersive, isA<SceneXmp>());
      expect(metadata.projection, isNull);
      expect((metadata.width, metadata.height), (48, 32));
    });

    test('a wall without a break: one layer, nothing filled, lowRelief', () {
      final path = scenePhoto(folder, 'wall.jpg');
      final inpaint = FakeInpaintBackend();
      final outcome = runChain(
        path,
        models: fakeSceneModels(shape: FakeGeometryShape.wall, inpaint: inpaint),
      );

      expect(outcome.result.isDone, isTrue);
      final file = written('wall.jpg');
      expect(file.xmp.sceneMeshes, 1);
      expect(file.glb.list('images'), hasLength(1));
      expect(inpaint.regions, isEmpty, reason: 'LaMa is not even run');
      expect(file.xmp.qualityFlags, contains(ReliefQualityFlag.lowRelief));
      expect(file.xmp.hiddenFraction, 0);
      expect(file.xmp.safe!.lateral, SceneV1.lateralMax);
    });

    test('a quarter of sky: sky, the far plane', () {
      final path = scenePhoto(folder, 'sky.jpg');
      final outcome = runChain(path, models: fakeSceneModels(shape: FakeGeometryShape.sky));

      expect(outcome.result.qualityFlags, contains(ReliefQualityFlag.sky));
    });

    test('a photo with the focal length of its EXIF: that field of view, the source Exif, no fovGuessed', () {
      final path = scenePhoto(folder, 'exif.jpg', exif: exifWithFocal35(26));
      final outcome = runChain(path);
      final xmp = written('exif.jpg').xmp;
      final spanX = 1.5 / math.sqrt(1 + 1.5 * 1.5);

      expect(outcome.result.isDone, isTrue);
      expect(xmp.fieldOfViewSource, FieldOfViewSource.exif);
      expect(xmp.fieldOfView, closeTo(2 * math.atan(spanX / (26 / 21.635)) * 180 / math.pi, 1e-9));
      expect(xmp.qualityFlags, isNot(contains(ReliefQualityFlag.fovGuessed)), reason: 'within 25 % of the model');
    });

    test('a photo turned a quarter: a portrait scene, its turns in the packet and the key', () {
      final path = scenePhoto(folder, 'turned.jpg');
      runChain(path, quarterTurns: 1);
      final file = written('turned.jpg');
      final photo = const DartSbsCodec().decodeJpeg(file.glb.image(0));

      expect((photo.width, photo.height), (32, 48));
      expect(file.xmp.sourceQuarterTurns, 1);
      expect(file.xmp.settingsKey, endsWith('|scene-v1|4|1'));
    });

    test('the .glb copy holds the same scene as the tail', () {
      final path = scenePhoto(folder, 'salon.jpg');
      final glbPath = p.join(folder.path, '.salon_scene3D.glb.4242-1.immuch360.part');
      runChain(path, glbPartPath: glbPath);
      final file = written('salon.jpg');

      expect(File(glbPath).readAsBytesSync(), sceneBytesOf(file.bytes, file.xmp));
    });

    test('the progress goes through the steps of a scene in their order, the regions counted', () {
      final path = scenePhoto(folder, 'salon.jpg');
      final seen = <ImmersiveProgress>[];
      final outcome = runChain(path, onProgress: seen.add);

      final stages = [for (final progress in seen) progress.stage];
      expect(stages.toSet().toList(), ImmersiveStage.scene);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].perMille, greaterThanOrEqualTo(seen[i - 1].perMille));
        expect(seen[i].stage.index, greaterThanOrEqualTo(seen[i - 1].stage.index));
      }
      final regions = seen.where((progress) => progress.stage == ImmersiveStage.inpaint && progress.steps != null);
      expect(regions.first.step, 0);
      expect(regions.last.step, outcome.regions);
      expect(regions.last.steps, outcome.regions);
      expect(seen.last, const ImmersiveProgress(ImmersiveStage.writing, 1000));
      expect(outcome.result.stageTimes.keys, containsAll(ImmersiveStage.scene));
    });

    test('cancelled at each step: cancelled, no .part left, an empty one left empty', () {
      for (final stage in ImmersiveStage.scene) {
        for (final existed in [false, true]) {
          final path = scenePhoto(folder, 'cancel.jpg');
          final part = scenePartIn(folder, 'cancel.jpg');
          final glbPart = p.join(folder.path, '.cancel_scene3D.glb.part');
          if (existed) {
            File(part).writeAsBytesSync(const []);
          }
          var cancelled = false;
          final outcome = runChain(
            path,
            glbPartPath: glbPart,
            isCancelled: () => cancelled,
            onProgress: (progress) {
              // At the last report of the writing, once the file is written
              if (progress.stage == stage && (stage != ImmersiveStage.writing || progress.perMille == 1000)) {
                cancelled = true;
              }
            },
          );
          final reason = '${stage.name}, a .part ${existed ? 'made by the probe' : 'absent'}';

          if (stage == ImmersiveStage.writing) {
            // Reported once the job is over: the file stays, the queue cancels it at its end
            expect(outcome.result.isDone, isTrue, reason: reason);
          } else {
            expect(outcome.result.error, ImmersiveErrorCode.cancelled, reason: reason);
            expect(File(part).existsSync(), existed, reason: reason);
            if (existed) {
              expect(File(part).lengthSync(), 0, reason: reason);
            }
            expect(File(glbPart).existsSync(), isFalse, reason: reason);
          }
          for (final file in [File(part), File(glbPart)]) {
            if (file.existsSync()) {
              file.deleteSync();
            }
          }
        }
      }
    });

    test('cancelled right after the write: the .part as it was, the .glb copy gone', () {
      final path = scenePhoto(folder, 'late.jpg');
      final part = scenePartIn(folder, 'late.jpg');
      final glbPart = p.join(folder.path, '.late_scene3D.glb.part');
      var writes = 0;
      final outcome = runChain(
        path,
        glbPartPath: glbPart,
        writePart: (path, bytes) {
          writePartFile(path, bytes);
          writes++;
        },
        isCancelled: () => writes == 2,
      );

      expect(outcome.result.error, ImmersiveErrorCode.cancelled);
      expect(File(part).existsSync(), isFalse);
      expect(File(glbPart).existsSync(), isFalse);
    });

    test('a run of the geometry or of the filling stopped by the cancel is a cancelled job', () {
      final path = scenePhoto(folder, 'stopped.jpg');

      expect(
        runChain(path, models: fakeSceneModels(geometryFailure: ImmersiveErrorCode.cancelled)).result.error,
        ImmersiveErrorCode.cancelled,
      );
      expect(
        runChain(path, models: fakeSceneModels(inpaintFailure: ImmersiveErrorCode.cancelled)).result.error,
        ImmersiveErrorCode.cancelled,
      );
      expect(File(scenePartIn(folder, 'stopped.jpg')).existsSync(), isFalse);
    });

    test('a model that fails: modelFailed with its message, nothing written', () {
      final path = scenePhoto(folder, 'failed.jpg');
      final geometry = runChain(path, models: fakeSceneModels(geometryFailure: ImmersiveErrorCode.modelFailed));
      final inpaint = runChain(path, models: fakeSceneModels(inpaintFailure: ImmersiveErrorCode.modelFailed));

      expect(geometry.result.error, ImmersiveErrorCode.modelFailed);
      expect(geometry.result.message, 'Scripted modelFailed');
      expect(geometry.result.stageTimes.keys, contains(ImmersiveStage.geometry));
      expect(inpaint.result.error, ImmersiveErrorCode.modelFailed);
      expect(File(scenePartIn(folder, 'failed.jpg')).existsSync(), isFalse);
    });

    test('the photo changed after it was chosen: sourceLost; a file that is not a JPEG: decodeFailed', () {
      final path = scenePhoto(folder, 'changed.jpg');
      final changed = runChain(path, sha1: 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      final broken = p.join(folder.path, 'broken.jpg');
      File(broken).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 1, 2]);

      expect(changed.result.error, ImmersiveErrorCode.sourceLost);
      expect(runChain(broken).result.error, ImmersiveErrorCode.decodeFailed);
    });

    test('a disk full at the write: diskFull, nothing left', () {
      final path = scenePhoto(folder, 'full.jpg');
      final outcome = runChain(
        path,
        writePart: (path, bytes) => throw const FileSystemException('write', 'x', OSError('No space left', 28)),
      );

      expect(outcome.result.error, Platform.isWindows ? ImmersiveErrorCode.writeFailed : ImmersiveErrorCode.diskFull);
      expect(File(scenePartIn(folder, 'full.jpg')).existsSync(), isFalse);
    });

    test('the regions go to the filling in windows of the map, and only the holes of each tile come back', () {
      final path = scenePhoto(folder, 'regions.jpg', width: 160, height: 96);
      final inpaint = FakeInpaintBackend();
      runChain(path, models: fakeSceneModels(inpaint: inpaint));
      final file = written('regions.jpg');
      final background = const DartSbsCodec().decodeJpeg(file.glb.image(1));

      expect(inpaint.regions, isNotEmpty);
      for (final region in inpaint.regions) {
        expect((region.width, region.height), (160, 96), reason: 'the whole map, smaller than a window');
      }
      expect((background.width, background.height), (160, 96));
    });
  });

  group('the engine', () {
    late NativeCancelFlag cancel;
    setUp(() => cancel = NativeCancelFlag());
    tearDown(() => cancel.free());

    SceneEngine engineWith({SceneModelsSpec models = const FakeSceneModelsSpec(), Map<String, int?> files = const {}}) {
      final engine = SceneEngine(
        models: models,
        requiredFiles: files,
        codec: SbsCodecChoice.dart,
        priority: FakeThreadPriority(threads: {1: 'main'}),
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test('reads the original by its path and makes its scene in the worker', () async {
      final path = scenePhoto(folder, 'salon.jpg');
      final engine = engineWith();
      final seen = <ImmersiveProgress>[];
      final result = await engine.run(
        sceneJobFor(path, partPath: scenePartIn(folder, 'salon.jpg'), sha1: sha1OfFile(path)),
        cancel: cancel,
        onProgress: seen.add,
      );

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expect(written('salon.jpg').xmp.sourceName, 'salon.jpg');
      expect(engine.worker, isNotNull);
      expect(engine.lastOutcome!.regions, greaterThan(0));
      expect(seen.map((progress) => progress.stage).toSet().toList(), ImmersiveStage.scene);
      expect((await engine.worker!.status()).jobs, 1);
    });

    test('a source given as bytes: a server original or a file of a share, copied before', () async {
      final path = scenePhoto(folder, 'shared.jpg');
      final result = await engineWith().run(
        sceneJobFor(path, partPath: scenePartIn(folder, 'shared.jpg'), sha1: sha1OfFile(path), asBytes: true),
        cancel: cancel,
      );

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    });

    test('a PNG decoded by the engine of Flutter on the root isolate, then made a scene in the worker', () async {
      final png = p.join(folder.path, 'drawing.png');
      final jpeg = scenePhoto(folder, 'source.jpg');
      final decoded = const DartSbsCodec().decodeJpeg(File(jpeg).readAsBytesSync());
      File(png).writeAsBytesSync(pngOf(decoded));
      final result = await engineWith().run(
        sceneJobFor(png, partPath: scenePartIn(folder, 'drawing.png'), sha1: sha1OfFile(png)),
        cancel: cancel,
      );

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expect(written('drawing.png').xmp.sourceName, 'drawing.png');
    });

    test('a component missing or damaged: componentsMissing before anything is read', () async {
      final model = p.join(folder.path, 'moge.onnx');
      File(model).writeAsBytesSync(List.filled(10, 1));
      final path = scenePhoto(folder, 'salon.jpg');
      final job = sceneJobFor(path, partPath: scenePartIn(folder, 'salon.jpg'), sha1: sha1OfFile(path));

      final damaged = await engineWith(files: {model: 11}).run(job, cancel: cancel);
      final gone = await engineWith(files: {p.join(folder.path, 'lama.onnx'): null}).run(job, cancel: cancel);

      expect(damaged.error, ImmersiveErrorCode.componentsMissing);
      expect(gone.error, ImmersiveErrorCode.componentsMissing);
      expect(File(scenePartIn(folder, 'salon.jpg')).existsSync(), isFalse);
    });

    test('cancelled before it starts: nothing read, nothing written; the original gone: sourceLost', () async {
      final path = scenePhoto(folder, 'salon.jpg');
      final job = sceneJobFor(path, partPath: scenePartIn(folder, 'salon.jpg'), sha1: sha1OfFile(path));
      final engine = engineWith();
      cancel.cancel();
      final cancelled = await engine.run(job, cancel: cancel);
      File(path).deleteSync();
      final other = NativeCancelFlag();
      addTearDown(other.free);
      final lost = await engine.run(job, cancel: other);

      expect(cancelled.error, ImmersiveErrorCode.cancelled);
      expect(engine.worker, isNull, reason: 'no worker for a job cancelled before it started');
      expect(lost.error, ImmersiveErrorCode.sourceLost);
    });

    test('cancelled during the job: the worker sees the flag and the job ends cancelled', () async {
      final path = scenePhoto(folder, 'salon.jpg');
      final engine = engineWith();
      final result = await engine.run(
        sceneJobFor(path, partPath: scenePartIn(folder, 'salon.jpg'), sha1: sha1OfFile(path)),
        cancel: cancel,
        onProgress: (progress) {
          if (progress.stage == ImmersiveStage.decoding) {
            cancel.cancel();
          }
        },
      );

      // The flag is read in the worker without a message: the job ends at the next step at the latest
      expect(result.error, ImmersiveErrorCode.cancelled);
      expect(File(scenePartIn(folder, 'salon.jpg')).existsSync(), isFalse);
    });

    test('one job at a time: a second call waits for the first', () async {
      final first = scenePhoto(folder, 'first.jpg');
      final second = scenePhoto(folder, 'second.jpg');
      final engine = engineWith();
      final order = <String>[];
      final other = NativeCancelFlag();
      addTearDown(other.free);
      final a = engine
          .run(
            sceneJobFor(first, partPath: scenePartIn(folder, 'first.jpg'), sha1: sha1OfFile(first)),
            cancel: cancel,
          )
          .then((result) => order.add('first ${result.isDone}'));
      final b = engine
          .run(
            sceneJobFor(second, partPath: scenePartIn(folder, 'second.jpg'), sha1: sha1OfFile(second)),
            cancel: other,
          )
          .then((result) => order.add('second ${result.isDone}'));
      await Future.wait([a, b]);

      expect(order, ['first true', 'second true']);
    });

    test('after dispose: no job, the worker closed', () async {
      final path = scenePhoto(folder, 'salon.jpg');
      final engine = engineWith();
      final job = sceneJobFor(path, partPath: scenePartIn(folder, 'salon.jpg'), sha1: sha1OfFile(path));
      await engine.run(job, cancel: cancel);
      final worker = engine.worker!;
      await engine.dispose();
      for (var i = 0; i < 50 && worker.isAlive; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(worker.isAlive, isFalse);
      expect((await engine.run(job, cancel: cancel)).error, ImmersiveErrorCode.modelFailed);
    });
  });

  test('the focal length equivalent to 35 mm of an EXIF', () {
    expect(exifFocalLength35mm(exifWithFocal35(26)), 26);
    expect(exifFocalLength35mm(exifWithFocal35(0)), isNull, reason: '0 is unknown');
    expect(exifFocalLength35mm(null), isNull);
  });
}
