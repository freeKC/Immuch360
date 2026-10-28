// The engine of the 3D scenes on the real models and real photos (lot S1, design-final 2026-10-27, section 10.2), by
// hand only, never in the CI, which downloads no model: our export of MoGe-2 ViT-S and LaMa on ONNX Runtime, the
// engine of the app (SceneEngine.onnx, its worker, its sessions kept from one photo to the next) on every photo of
// IMMUCH360_AI_PHOTOS. Each scene is read back by the probe of the phase 1 (a flat photo), by the scanner of the
// library (a scene), by the reader of the tail and a reader of its glb; its zone is not empty, its meshes keep the
// bounds of the format; the originals are compared byte for byte after the run. The scenes, their .glb and a summary
// with the time of each step go to IMMUCH360_AI_WORK, for a look in a glTF viewer and the comparison with the measure
// M2.
//
//   IMMUCH360_ORT_LIB    the library of ONNX Runtime (libonnxruntime.so.1.31.0, onnxruntime.dll)
//   IMMUCH360_AI_MOGE    moge_2_vits_normal_immuch360.onnx, checked by its SHA-256 against the catalogue
//   IMMUCH360_AI_LAMA    lama_fp32.onnx, the same (the measure M2 gave the bands to LaMa; MI-GAN is the seam of P3)
//   IMMUCH360_AI_PHOTOS  a folder of photos (JPEG, PNG): the twelve of the lot V
//   IMMUCH360_AI_WORK    a folder for the scenes and the summary
//
// The same run with no network: `sudo unshare -n sudo -u $USER env ... flutter test` and this file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:path/path.dart' as p;

import 'scene/scene_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final library = environment['IMMUCH360_ORT_LIB'];
  final moge = environment['IMMUCH360_AI_MOGE'];
  final lama = environment['IMMUCH360_AI_LAMA'];
  final photos = environment['IMMUCH360_AI_PHOTOS'];
  final work = environment['IMMUCH360_AI_WORK'];
  final missing = [
    if (library == null) 'IMMUCH360_ORT_LIB',
    if (moge == null) 'IMMUCH360_AI_MOGE',
    if (lama == null) 'IMMUCH360_AI_LAMA',
    if (photos == null) 'IMMUCH360_AI_PHOTOS',
    if (work == null) 'IMMUCH360_AI_WORK',
  ];
  final skip = missing.isEmpty ? null : 'by hand: set ${missing.join(', ')}';

  test(
    'a scene of every photo, read back, its originals untouched',
    () async {
      for (final (path, component) in [(moge!, mogeGeometryComponent), (lama!, lamaInpaintComponent)]) {
        final sum = sha256.convert(File(path).readAsBytesSync()).toString();
        expect(sum, component.sha256, reason: '$path is not ${component.id}');
      }
      final scenes = Directory(p.join(work!, 'scenes'))..createSync(recursive: true);
      final originals = Directory(photos!).listSync().whereType<File>().where((file) {
        final extension = p.extension(file.path).toLowerCase();
        return const {'.jpg', '.jpeg', '.png', '.heic', '.webp'}.contains(extension);
      }).toList()..sort((a, b) => a.path.compareTo(b.path));
      expect(originals, isNotEmpty);
      final before = {for (final file in originals) file.path: sha256.convert(file.readAsBytesSync()).toString()};

      final engine = SceneEngine.onnx(
        libraryPath: library!,
        mogePath: moge,
        mogeSha256: mogeGeometryComponent.sha256!,
        lamaPath: lama,
        lamaSha256: lamaInpaintComponent.sha256!,
        geometryModel: mogeGeometryComponent.id,
        inpaintModel: lamaInpaintComponent.id,
        mogeSize: mogeGeometryComponent.size,
        lamaSize: lamaInpaintComponent.size,
      );
      addTearDown(engine.dispose);
      final summary = <Map<String, Object?>>[];
      for (final original in originals) {
        final name = p.basename(original.path);
        final stem = p.basenameWithoutExtension(name);
        final part = p.join(scenes.path, '.${stem}_scene3D.jpg.part');
        final glbPart = p.join(scenes.path, '.${stem}_scene3D.glb.part');
        final cancel = NativeCancelFlag();
        final watch = Stopwatch()..start();
        final ImmersiveResult result;
        try {
          result = await engine.run(
            sceneJobFor(original.path, partPath: part, sha1: sha1OfFile(original.path), glbPartPath: glbPart),
            cancel: cancel,
          );
        } finally {
          cancel.free();
        }
        final seconds = watch.elapsedMilliseconds / 1000;
        expect(result.isDone, isTrue, reason: '$name: ${result.error} ${result.message}');
        final target = p.join(scenes.path, '${stem}_scene3D.jpg');
        final glbTarget = p.join(scenes.path, '${stem}_scene3D.glb');
        File(part).renameSync(target);
        File(glbPart).renameSync(glbTarget);

        final bytes = File(target).readAsBytesSync();
        final xmp = ImmersiveXmp.findIn(bytes)! as SceneXmp;
        final glbBytes = sceneBytesOf(bytes, xmp);
        expect(glbBytes, isNotNull, reason: '$name: the tail');
        expect(File(glbTarget).readAsBytesSync(), glbBytes, reason: '$name: the .glb copy');
        final glb = GlbView.read(glbBytes!);
        expect(glb.list('meshes').length, inInclusiveRange(1, SceneV1.maxMeshes), reason: name);
        for (final accessor in glb.list('accessors').where((accessor) => accessor['type'] == 'VEC3')) {
          expect(accessor['count'] as int, lessThanOrEqualTo(SceneV1.maxMeshVertices), reason: name);
        }
        expect(probeStereoPhotoHead(Uint8List.sublistView(bytes, 0, 131072), name: p.basename(target)), isNull);
        final metadata = readMediaMetadataSync(target, LibraryMediaKind.image);
        expect(metadata.immersive, isA<SceneXmp>(), reason: '$name: the library reads a scene');
        expect(metadata.projection, isNull, reason: name);
        expect(xmp.safe!.lateral, greaterThan(0), reason: '$name: a zone');
        expect(xmp.request, isNotNull, reason: '$name: the request of the headset');
        final details = result.details! as SceneResultDetails;
        final outcome = engine.lastOutcome!;
        final entry = {
          'photo': name,
          'seconds': seconds,
          'steps': {for (final MapEntry(:key, :value) in result.stageTimes.entries) key.name: value.inMilliseconds},
          'regions': outcome.regions,
          'decoder': outcome.decoder,
          'encoder': outcome.encoder,
          'meshes': details.meshes,
          'vertices': details.vertices,
          'triangles': details.triangles,
          'withinStartBudget': details.vertices <= 60000 && details.triangles <= 120000,
          'gridStep': xmp.gridStep,
          'safe': xmp.safe!.toJson(),
          'scale': xmp.sceneScale,
          'fieldOfView': xmp.fieldOfView,
          'fieldOfViewSource': xmp.fieldOfViewSource?.xmp,
          'hiddenFraction': xmp.hiddenFraction,
          'flags': [for (final flag in xmp.qualityFlags) flag.xmp],
          'textureMax': xmp.sceneTextureMax,
          'fileBytes': bytes.length,
          'sceneBytes': glbBytes.length,
        };
        summary.add(entry);
        // ignore: avoid_print
        print(jsonEncode(entry));
      }
      final after = {for (final file in originals) file.path: sha256.convert(file.readAsBytesSync()).toString()};
      expect(after, before, reason: 'the originals are never written');
      File(p.join(work, 'summary.json')).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
