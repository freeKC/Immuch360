// The measure of the plan for the photos of a splat scene (lot SP5), by hand only, never in the CI: every JPEG of a
// folder prepared by the app's code, as the job will (the members read one at a time from their files, the native
// codec when this build has it, a few photos at once), timed. The skull of the measure of 1 November 2026 (55 photos of
// 11.9 Mpx) must be ready in under 20 s on the PC.
//
//   IMMUCH360_SPLAT_PHOTOS  a folder of photos
//   IMMUCH360_SPLAT_OUT     a folder for the images and summary.json (the time, the folders, the focal lengths)
//   IMMUCH360_SPLAT_AT_ONCE photos prepared at once, splatPhotosAtOnce() by default

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/native_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/splat_members.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_inputs.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

void main() {
  final environment = Platform.environment;
  final photos = environment['IMMUCH360_SPLAT_PHOTOS'];
  final out = environment['IMMUCH360_SPLAT_OUT'];

  test(
    'the photos of a folder made ready for COLMAP, timed',
    () async {
      final files = [
        for (final entry in Directory(photos!).listSync())
          if (entry is File && RegExp(r'\.jpe?g$', caseSensitive: false).hasMatch(entry.path)) entry.path,
      ]..sort();
      final cancel = NativeCancelFlag();
      addTearDown(cancel.free);
      final images = p.join(out!, 'images');
      final watch = Stopwatch()..start();
      final plan = planSplatPhotos([
        // Each read with its SHA-1, as the queue reads a file of this computer
        for (final path in files) SourceSplatMember(LocalFileSource(path)),
      ]);
      final atOnce = int.tryParse(environment['IMMUCH360_SPLAT_AT_ONCE'] ?? '') ?? splatPhotosAtOnce();
      final inputs = await prepareSplatPhotos(plan.taken, imagesFolder: images, cancel: cancel, atOnce: atOnce);
      final elapsed = watch.elapsed;
      final first = inputs.images.first;
      final camera = cameraExifOf(JpegHeader.read(File(p.join(images, first.relativePath)).readAsBytesSync()).exif);
      final resolution = camera.focalPlaneXResolution;
      final unit = switch (camera.focalPlaneResolutionUnit) {
        3 => 10.0,
        4 => 1.0,
        5 => 0.001,
        _ => 25.4,
      };
      final summary = {
        'photos': files.length,
        'elapsedMs': elapsed.inMilliseconds,
        'atOnce': atOnce,
        'nativeCodec': NativeSbsCodec.available,
        'kept': inputs.images.length,
        'leftOut': [for (final left in inputs.leftOut) '${left.name}: ${left.reason.name}'],
        'cameras': inputs.cameras,
        'size': '${first.width}x${first.height}',
        'focalLength35mm': camera.focalLength35mm,
        // What COLMAP starts from when the file gives no 35 mm equivalent: FocalLength by the focal plane resolution
        'colmapFocalPixels': camera.focalLengthMm != null && resolution != null
            ? camera.focalLengthMm! * resolution.$1 / resolution.$2 / unit
            : null,
      };
      await File(p.join(out, 'summary.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(summary));
      // ignore: avoid_print
      print('${inputs.images.length} of ${files.length} photos in ${elapsed.inMilliseconds} ms: $summary');
    },
    skip: photos == null || out == null ? 'IMMUCH360_SPLAT_PHOTOS and IMMUCH360_SPLAT_OUT' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
