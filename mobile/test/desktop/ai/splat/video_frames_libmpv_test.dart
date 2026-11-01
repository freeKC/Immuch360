// The frames of a splat scene taken by a real libmpv (lot SP5, mpv_frame_source.dart): on Windows the libmpv of a build
// of the app, on Linux the system's (libmpv_for_tests.dart), skipped elsewhere or without one. The fixture
// portrait-blur-6s.mp4 (make_portrait_blur.sh) is a video filmed upright as a phone stores it, lying with its rotation
// in the file, sharp only from 0.40 to 0.57 s of each second, blurred all along its fourth second: its frames must come
// out upright (180 x 320, the white band at the top), each window of a second must keep its sharp moment, at half a
// second exactly, and the blurred second must be left out.
//
// By hand, the measure of the plan on a real video (never in the CI):
//   IMMUCH360_SPLAT_VIDEO  a video (the lighthouse of the measure: 150 frames in under 2 minutes)
//   IMMUCH360_SPLAT_OUT    a folder for its images and summary.json (the time, the frames kept and their moments)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/splat/mpv_frame_source.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_inputs.dart';
import 'package:immich_mobile/desktop/ai/splat/video_frames.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import '../../video/libmpv_for_tests.dart';

void main() {
  final libmpv = libmpvForTests();
  final library = libmpv.library;
  final skip = libmpv.skip ?? false;
  final environment = Platform.environment;
  final measured = environment['IMMUCH360_SPLAT_VIDEO'];
  final out = environment['IMMUCH360_SPLAT_OUT'];

  late Directory work;
  late NativeCancelFlag cancel;

  setUpAll(() {
    if (library != null) {
      loadLibmpvForTests(library);
    }
  });

  setUp(() async {
    work = await Directory.systemTemp.createTemp('immuch360_splat_mpv_');
    cancel = NativeCancelFlag();
  });

  tearDown(() async {
    cancel.free();
    await work.delete(recursive: true);
  });

  for (final (how, maxStep) in [('frame steps', const Duration(seconds: 1)), ('exact seeks', Duration.zero)]) {
    test(
      'a portrait video comes out upright, the sharp moment of each second is kept, the blurred second left out: $how',
      () async {
        final fixture = File(p.join('test', 'fixtures', 'video', 'portrait-blur-6s.mp4')).absolute.path;
        final images = p.join(work.path, 'images');
        final source = MpvSplatFrameSource(maxStep: maxStep);
        final inputs = await takeVideoFrames(
          fixture,
          source: source,
          imagesFolder: images,
          cancel: cancel,
          frames: 6,
          candidates: 5,
        );
        expect(inputs.total, 6);
        expect(inputs.images.map((image) => image.source), ['0:00.5', '0:01.5', '0:02.5', '0:04.5', '0:05.5']);
        // The fourth second is blurred all along: its best candidate, whichever, stays under half of its neighbours'
        expect(inputs.leftOut.map((left) => left.reason), [SplatLeftOutReason.blurred]);
        expect(inputs.leftOut.single.name, startsWith('0:03.'));
        for (final image in inputs.images) {
          expect((image.width, image.height), (180, 320), reason: 'upright, as the rotation of the file says');
          final decoded = img.decodeJpg(File(p.join(images, image.relativePath)).readAsBytesSync())!;
          expect((decoded.width, decoded.height), (180, 320));
          double meanOfRows(int from, int to) {
            var sum = 0.0;
            for (var y = from; y < to; y++) {
              for (var x = 0; x < decoded.width; x++) {
                sum += decoded.getPixel(x, y).luminance;
              }
            }
            return sum / ((to - from) * decoded.width);
          }

          expect(meanOfRows(0, 24), greaterThan(200), reason: 'the white band at the top of ${image.source}');
          expect(meanOfRows(296, 320), lessThan(170), reason: 'the texture at the bottom of ${image.source}');
        }
        final sharp = inputs.images.map((image) => image.sharpness).reduce((a, b) => a < b ? a : b);
        expect(sharp, greaterThan(500), reason: 'the frames kept are the sharp ones');
        if (maxStep == Duration.zero) {
          expect((source.seeks, source.steps), (30, 0));
        } else {
          expect(source.seeks, 0, reason: 'from the first frame, every candidate is a few frames ahead');
          expect(source.steps, inInclusiveRange(150, 180));
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }

  test(
    'the measure of the plan on a real video: IMMUCH360_SPLAT_VIDEO into IMMUCH360_SPLAT_OUT',
    () async {
      final folder = Directory(out!);
      final images = p.join(folder.path, 'images');
      final watch = Stopwatch()..start();
      final progress = <int>[];
      final source = MpvSplatFrameSource();
      final inputs = await takeVideoFrames(
        measured!,
        source: source,
        imagesFolder: images,
        cancel: cancel,
        onProgress: (done, total) => progress.add(watch.elapsedMilliseconds),
      );
      final elapsed = watch.elapsed;
      final summary = {
        'video': p.basename(measured),
        'elapsedMs': elapsed.inMilliseconds,
        'windows': inputs.total,
        'kept': inputs.images.length,
        'blurred': inputs.blurred,
        'unreadable': inputs.leftOut.where((left) => left.reason == SplatLeftOutReason.unreadable).length,
        'firstWindowMs': progress.isEmpty ? null : progress.first,
        'seeks': source.seeks,
        'steps': source.steps,
        'written': inputs.images.isEmpty ? null : '${inputs.images.first.width}x${inputs.images.first.height}',
        'frames': [
          for (final image in inputs.images)
            {'name': image.relativePath, 'at': image.source, 'sharpness': image.sharpness},
        ],
        'leftOut': [
          for (final left in inputs.leftOut) {'at': left.name, 'reason': left.reason.name},
        ],
      };
      await File(
        p.join(folder.path, 'summary.json'),
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(summary));
      // ignore: avoid_print
      print(
        '${inputs.images.length} of ${inputs.total} frames in ${elapsed.inMilliseconds} ms, '
        '${inputs.blurred} blurred windows',
      );
      if (inputs.total <= SplatV1.videoFrames) {
        expect(elapsed, lessThan(const Duration(minutes: 2)), reason: 'the plan: 150 frames in under 2 minutes');
      }
    },
    skip: skip != false
        ? skip
        : (measured == null || out == null ? 'IMMUCH360_SPLAT_VIDEO and IMMUCH360_SPLAT_OUT' : false),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
