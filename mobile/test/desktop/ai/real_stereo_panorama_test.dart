// The 3D version of real 360° photos on the real depth model (lot P1, design-final 2026-10-27, sections 4.4 and 10.2),
// by hand only, never in the CI, which downloads no model: Depth Anything V2 Small of phase 1 on ONNX Runtime, the
// engine of the app (StereoPanoramaEngine.onnx, its worker, its session kept from one panorama to the next) on every
// panorama of IMMUCH360_AI_PANORAMAS (the CC0 360° photos of Poly Haven of the lot). Each file is read back by the
// readers of the app (our packet, GPano, a square read top and bottom, the scanner of the library); the originals are
// compared byte for byte after the run. For a look without a headset, each panorama also gets the map of its depth
// (the same views and merge as the engine, at 2048 x 1024) and a red and cyan anaglyph of its two eyes; the files, the
// pictures and a summary with the time of each step go to IMMUCH360_AI_WORK.
//
// With IMMUCH360_AI_VARIANTS, two more 3D versions of each panorama go next to the one of the engine (A), made from the
// same map, for a comparison in the headset before the contract of relief-360-v1 is changed or kept (P1-review, M1):
//  B  the shift scaled so that the largest d * cos(latitude) of the whole sphere moves by exactly 1°, never more;
//  C  d brought between the percentiles 2 and 98 of the band of latitudes within 30° of the horizon (walls,
//     furniture, people), clamped to [0, 1] everywhere (the floor under the band at 1), then the 5 x 5 dilation of
//     relief-v1, 1° for d = 1 at the equator.
// For A, B and C, the summary gives the shift at a few latitudes (median and largest of the row, in degrees) and the
// part filled in; a variant past 8 % filled is written anyway and said refused by the rule. The app and its contract
// are not changed by them: they are files to look at.
//
//   IMMUCH360_ORT_LIB        the library of ONNX Runtime (libonnxruntime.so.1.31.0, onnxruntime.dll)
//   IMMUCH360_AI_MODEL       depth_anything_v2_small.onnx, checked by its SHA-256 against the catalogue
//   IMMUCH360_AI_PANORAMAS   a folder of 360° photos (2:1 JPEG or PNG)
//   IMMUCH360_AI_WORK        a folder for the 3D panoramas, the pictures and the summary
//   IMMUCH360_AI_VARIANTS    when set, the variants B and C as well

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart' show SbsCodecChoice;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart';
import 'package:immich_mobile/desktop/ai/panorama/relief_360.dart';
import 'package:immich_mobile/desktop/ai/panorama/stereo_panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart' show encodeScenePicture;
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
  final variants = environment['IMMUCH360_AI_VARIANTS'] != null;
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
        // The map of the depth, as the engine makes it (the eye by area, then the picture of the views), for a look
        final decoded = const DartSbsCodec().decodeJpeg(bytesIn);
        final (eyeWidth, eyeHeight) = stereoPanoramaEyeSize(decoded.width);
        final eye = resampleArea(decoded, eyeWidth, eyeHeight);
        final (mapWidth, mapHeight) = stereoPanoramaMapSize(eyeWidth);
        final picture = resampleArea(eye, mapWidth, mapHeight);
        final backend = OrtDepthBackend(libraryPath: library, modelPath: model);
        try {
          final views = relief360Views();
          final maps = <DepthMap>[for (final view in views) backend.estimate(tangentViewInput(picture, view))];
          final merged = mergeViewDepths(views, maps, width: mapWidth, height: mapHeight);
          final normalised = normaliseDepth(merged.map);
          entry['lowRelief'] = normalised.lowRelief;
          entry['uncovered'] = merged.uncovered;
          final stem = p.basenameWithoutExtension(name);
          File(p.join(out.path, '${stem}_depth.png')).writeAsBytesSync(_grey(normalised.depth));
          if (variants && result.isDone) {
            entry['variants'] = _writeVariants(
              eye: eye,
              normalised: normalised,
              raw: merged.map,
              packet: ImmersiveXmp.findIn(File(target).readAsBytesSync())! as StereoPanoramaXmp,
              exif: JpegHeader.read(File(target).readAsBytesSync()).exif,
              folder: out.path,
              stem: stem,
              target: p.basenameWithoutExtension(target),
            );
          }
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

/// The latitudes, in degrees, at which the summary gives the shift of each variant
const _latitudes = [60, 30, 10, 0, -10, -30, -45, -60];

/// The variants B and C of the 3D version of a panorama (see the top of this file), written next to the engine's
/// [target] (A) in [folder], with its [packet] and its [exif]; the shifts of A, B and C for the summary
List<Map<String, Object?>> _writeVariants({
  required SbsDecoded eye,
  required NormalisedDepth normalised,
  required ReliefDepth raw,
  required StereoPanoramaXmp packet,
  required Uint8List? exif,
  required String folder,
  required String stem,
  required String target,
}) {
  final width = eye.width;
  final height = eye.height;

  // B: the largest d * cos(latitude) of the eye, read as the right eye reads the map, moves by 1°
  final sampler = SphereDepthSampler(normalised.depth, width, height);
  final row = Float64List(width);
  var largest = 0.0;
  for (var y = 0; y < height; y++) {
    sampler.sampleRow(y, row);
    final cosine = math.cos(erpLatitude(y, height));
    for (final d in row) {
      largest = math.max(largest, d * cosine);
    }
  }
  final shiftB = largest > 0 ? Relief360V1.maxShiftDegrees / largest : Relief360V1.maxShiftDegrees;

  // C: the percentiles of the band within 30° of the horizon, clamped, dilated
  final band = <double>[];
  for (var y = 0; y < raw.height; y++) {
    if (erpLatitude(y, raw.height).abs() < 30 * math.pi / 180) {
      for (var x = 0; x < raw.width; x++) {
        final value = raw.values[y * raw.width + x];
        if (value.isFinite) {
          band.add(value);
        }
      }
    }
  }
  final sorted = Float64List.fromList(band)..sort();
  final p2 = reliefPercentile(sorted, ReliefV1.lowPercentile);
  final p98 = reliefPercentile(sorted, ReliefV1.highPercentile);
  final spread = p98 - p2 > 0 ? p98 - p2 : 1.0;
  final clamped = Float64List(raw.values.length);
  for (var i = 0; i < clamped.length; i++) {
    final value = raw.values[i];
    clamped[i] = value.isFinite ? ((value - p2) / spread).clamp(0.0, 1.0) : 0.5;
  }
  final mapC = dilateForeground(ReliefDepth(raw.width, raw.height, clamped));
  File(p.join(folder, '${stem}_C_depth.png')).writeAsBytesSync(_grey(mapC));

  final made = <Map<String, Object?>>[];
  for (final (name, map, shift, how) in [
    (
      'A',
      normalised.depth,
      Relief360V1.maxShiftDegrees,
      'relief-360-v1 as the contract has it: d between the percentiles 2 and 98 of the whole sphere, '
          '1° for d = 1 at the equator',
    ),
    ('B', normalised.depth, shiftB, 'the same map, the largest d * cos(latitude) of the sphere moved by exactly 1°'),
    (
      'C',
      mapC,
      Relief360V1.maxShiftDegrees,
      'd between the percentiles 2 and 98 of the latitudes within 30° of the horizon, clamped to [0, 1], '
          'dilated 5 x 5, 1° for d = 1 at the equator',
    ),
  ]) {
    final half = 4 * width * height;
    final frame = Uint8List(2 * half)..setAll(0, eye.rgba);
    final right = writeRelief360RightEye(
      left: frame,
      width: width,
      height: height,
      map: map,
      lowRelief: normalised.lowRelief,
      maxShiftDegrees: shift,
      target: frame,
      targetOffset: half,
    );
    final rows = SphereDepthSampler(map, width, height);
    final latitudes = <String, List<double>>{};
    for (final latitude in _latitudes) {
      final y = ((0.5 - latitude / 180) * height - 0.5).round().clamp(0, height - 1);
      rows.sampleRow(y, row);
      final cosine = math.cos(erpLatitude(y, height));
      final shifts = [for (final d in row) shift * d * cosine]..sort();
      latitudes['$latitude'] = [_rounded(shifts[shifts.length ~/ 2]), _rounded(shifts.last)];
    }
    made.add({
      'variant': name,
      'how': how,
      'maxShiftDegrees': _rounded(shift),
      'shiftDegreesAtLatitude': latitudes,
      'filledFraction': right.filledFraction,
      'refusedByTheRule': right.refused,
      'flags': [for (final flag in right.flags) flag.xmp],
    });
    if (name == 'A') {
      continue;
    }
    final variant = StereoPanoramaXmp(
      origin: packet.origin,
      relief: packet.relief,
      pipeline: packet.pipeline,
      width: packet.width,
      height: packet.height,
      depthModel: packet.depthModel,
      depthModelSha256: packet.depthModelSha256,
      maxShiftDegrees: _rounded(shift),
      region: packet.region,
      sourceCoverage: packet.sourceCoverage,
      parentDerivativeId: packet.parentDerivativeId,
      derivativeId: newImmersiveDerivativeId(),
      sourceName: packet.sourceName,
      sourceSize: packet.sourceSize,
      sourceSha1: packet.sourceSha1,
      sourceQuarterTurns: packet.sourceQuarterTurns,
      qualityFlags: right.flags,
      created: packet.created,
      creatorTool: 'Immuch360 Desktop (real_stereo_panorama_test, variant $name of P1-review M1)',
      description: packet.description,
      digitalSourceType: packet.digitalSourceType,
    );
    final picture = SbsDecoded(width: width, height: 2 * height, rgba: frame, iccProfile: eye.iccProfile);
    final (jpeg, _) = encodeScenePicture(
      SbsCodecChoice.auto.codecs(),
      picture,
      quality: PanoV1.quality,
      exif: exif,
      xmp: variant.toXml(),
    );
    final path = p.join(folder, '${target}_$name.jpg');
    File(path).writeAsBytesSync(jpeg);
    final back = ImmersiveXmp.findIn(File(path).readAsBytesSync())! as StereoPanoramaXmp;
    expect(back.digitalSourceType, iptcCompositeWithTrainedAlgorithmicMedia, reason: path);
    expect(back.description, packet.description, reason: path);
    expect(guessStereoLayout(width: width, height: 2 * height), StereoLayout.topBottom);
    File(p.join(folder, '${stem}_${name}_anaglyph.jpg')).writeAsBytesSync(_anaglyph(picture));
  }
  return made;
}

double _rounded(double value) => (value * 1000).round() / 1000;

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
