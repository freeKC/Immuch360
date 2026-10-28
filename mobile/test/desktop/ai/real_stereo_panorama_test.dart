// The 3D version of real 360° photos on the real depth model (lot P1, design-final 2026-10-27, sections 4.4 and 10.2),
// by hand only, never in the CI, which downloads no model: Depth Anything V2 Small of phase 1 on ONNX Runtime, the
// engine of the app (StereoPanoramaEngine.onnx, its worker, its session kept from one panorama to the next) on every
// panorama of IMMUCH360_AI_PANORAMAS (the CC0 360° photos of Poly Haven of the lot). Each file is read back by the
// readers of the app (our packet, GPano, a square read top and bottom, the scanner of the library); the originals are
// compared byte for byte after the run. For a look without a headset, each panorama also gets the map of its depth
// (the same views and merge as the engine, at 2048 x 1024) and a red and cyan anaglyph of its two eyes; the files, the
// pictures and a summary with the time of each step go to IMMUCH360_AI_WORK.
//
//   IMMUCH360_ORT_LIB        the library of ONNX Runtime (libonnxruntime.so.1.31.0, onnxruntime.dll)
//   IMMUCH360_AI_MODEL       depth_anything_v2_small.onnx, checked by its SHA-256 against the catalogue
//   IMMUCH360_AI_PANORAMAS   a folder of 360° photos (2:1 JPEG or PNG)
//   IMMUCH360_AI_WORK        a folder for the 3D panoramas, the pictures and the summary

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart';
import 'package:immich_mobile/desktop/ai/panorama/stereo_panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart'
    show parseGPanoProjectionType;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final library = environment['IMMUCH360_ORT_LIB'];
  final model = environment['IMMUCH360_AI_MODEL'];
  final panoramas = environment['IMMUCH360_AI_PANORAMAS'];
  final work = environment['IMMUCH360_AI_WORK'];
  final missing = [
    if (library == null) 'IMMUCH360_ORT_LIB',
    if (model == null) 'IMMUCH360_AI_MODEL',
    if (panoramas == null) 'IMMUCH360_AI_PANORAMAS',
    if (work == null) 'IMMUCH360_AI_WORK',
  ];
  final skip = missing.isEmpty ? null : 'by hand: set ${missing.join(', ')}';

  test(
    'the 3D version of every 360° photo, read back, its original untouched',
    () async {
      expect(sha256.convert(File(model!).readAsBytesSync()).toString(), depthModelOnnxComponent.sha256);
      final out = Directory(p.join(work!, 'stereo'))..createSync(recursive: true);
      final originals = Directory(panoramas!).listSync().whereType<File>().where((file) {
        final extension = p.extension(file.path).toLowerCase();
        return const {'.jpg', '.jpeg', '.png'}.contains(extension);
      }).toList()..sort((a, b) => a.path.compareTo(b.path));
      expect(originals, isNotEmpty);
      final before = {for (final file in originals) file.path: sha256.convert(file.readAsBytesSync()).toString()};

      final engine = StereoPanoramaEngine.onnx(
        libraryPath: library!,
        modelPath: model,
        modelSize: depthModelOnnxComponent.size,
      );
      addTearDown(engine.dispose);
      final summary = <Map<String, Object?>>[];
      for (final original in originals) {
        final name = p.basename(original.path);
        final target = p.join(out.path, derivedFileNameFor(ImmersiveKind.stereoPanorama360, name));
        final part = p.join(out.path, '.${p.basename(target)}.part');
        final bytesIn = original.readAsBytesSync();
        final cancel = NativeCancelFlag();
        final watch = Stopwatch()..start();
        final ImmersiveResult result;
        try {
          result = await engine.run(
            StereoPanoramaJob(
              id: name,
              source: ImmersiveSource(
                name: name,
                size: bytesIn.length,
                sha1: sha1OfFile(original.path),
                path: original.path,
              ),
              partPath: part,
              derivativeId: newImmersiveDerivativeId(),
              creatorTool: 'Immuch360 Desktop (real_stereo_panorama_test)',
              created: '2026-10-28T12:00:00+01:00',
            ),
            cancel: cancel,
          );
        } finally {
          cancel.free();
        }
        final seconds = watch.elapsedMilliseconds / 1000;
        final entry = <String, Object?>{
          'panorama': name,
          'seconds': seconds,
          'steps': {for (final MapEntry(:key, :value) in result.stageTimes.entries) key.name: value.inMilliseconds},
          'result': result.error?.name ?? 'done',
          'message': result.message,
          'alignments': [
            for (final alignment in engine.lastOutcome?.alignments ?? const <ViewAlignment>[])
              [alignment.scale, alignment.shift],
          ],
        };
        if (result.isDone) {
          File(part).renameSync(target);
          final bytes = File(target).readAsBytesSync();
          final xmp = ImmersiveXmp.findIn(bytes)! as StereoPanoramaXmp;
          final details = result.details! as StereoPanoramaResultDetails;
          expect((details.width, details.height), (Relief360V1.eyeWidth, 2 * Relief360V1.eyeHeight), reason: name);
          expect(xmp.origin, ImmersiveOrigin.estimatedDepth, reason: name);
          expect(xmp.sourceSha1, sha1OfFile(original.path), reason: name);
          expect(parseGPanoProjectionType(latin1.decode(bytes.sublist(0, 65536))), 'equirectangular', reason: name);
          expect(guessStereoLayout(width: details.width, height: details.height), StereoLayout.topBottom);
          final metadata = readMediaMetadataSync(target, LibraryMediaKind.image);
          expect(metadata.immersive, isA<StereoPanoramaXmp>(), reason: '$name: the library reads a 3D panorama');
          expect(metadata.projection, 'equirectangular', reason: name);
          final frame = const DartSbsCodec().decodeJpeg(bytes);
          File(p.join(out.path, '${p.basenameWithoutExtension(name)}_anaglyph.jpg')).writeAsBytesSync(_anaglyph(frame));
          entry.addAll({
            'filledFraction': details.filledFraction,
            'flags': [for (final flag in xmp.qualityFlags) flag.xmp],
            'fileBytes': bytes.length,
          });
        }
        // The map of the depth, as the engine makes it, for a look
        final decoded = const DartSbsCodec().decodeJpeg(bytesIn);
        final picture = resampleArea(decoded, Relief360V1.mapWidth, Relief360V1.mapHeight);
        final backend = OrtDepthBackend(libraryPath: library, modelPath: model);
        try {
          final views = relief360Views();
          final maps = <DepthMap>[for (final view in views) backend.estimate(tangentViewInput(picture, view))];
          final merged = mergeViewDepths(views, maps, width: Relief360V1.mapWidth, height: Relief360V1.mapHeight);
          final normalised = normaliseDepth(merged.map);
          entry['lowRelief'] = normalised.lowRelief;
          File(
            p.join(out.path, '${p.basenameWithoutExtension(name)}_depth.png'),
          ).writeAsBytesSync(_grey(normalised.depth));
        } finally {
          backend.close();
        }
        summary.add(entry);
        // ignore: avoid_print
        print(jsonEncode(entry));
      }
      final after = {for (final file in originals) file.path: sha256.convert(file.readAsBytesSync()).toString()};
      expect(after, before, reason: 'the originals are never written');
      File(p.join(work, 'summary.json')).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(summary));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// A PNG of [map], d from 0 (black, far) to 1 (white, near)
Uint8List _grey(ReliefDepth map) {
  final image = img.Image(width: map.width, height: map.height, numChannels: 1);
  for (var y = 0; y < map.height; y++) {
    for (var x = 0; x < map.width; x++) {
      final value = (255 * map.values[y * map.width + x]).round().clamp(0, 255);
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return img.encodePng(image);
}

/// A red and cyan anaglyph of the frame [frame] (top and bottom, the left eye on top), at half the size of an eye
Uint8List _anaglyph(SbsDecoded frame) {
  final width = frame.width;
  final eye = frame.height ~/ 2;
  final rgba = frame.rgba;
  final outWidth = width ~/ 2;
  final outHeight = eye ~/ 2;
  final image = img.Image(width: outWidth, height: outHeight);
  for (var y = 0; y < outHeight; y++) {
    for (var x = 0; x < outWidth; x++) {
      final left = 4 * ((2 * y) * width + 2 * x);
      final right = 4 * ((eye + 2 * y) * width + 2 * x);
      int grey(int at) => (0.299 * rgba[at] + 0.587 * rgba[at + 1] + 0.114 * rgba[at + 2]).round();
      image.setPixelRgb(x, y, grey(left), grey(right), grey(right));
    }
  }
  return img.encodeJpg(image, quality: 90);
}
