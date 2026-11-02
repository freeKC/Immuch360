// The frames of a video for a splat scene (lot SP5, video_frames.dart), on a source of synthetic frames: how many
// windows a video gives and where their candidates are, the sharpest candidate of each window kept, a blurred window
// left out, the frames numbered in the order of time in one folder, the windows counted as they are done, a cancel, a
// video that does not open, a window without a frame. The real decoding by libmpv is video_frames_libmpv_test.dart.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_inputs.dart';
import 'package:immich_mobile/desktop/ai/splat/video_frames.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import 'splat_input_support.dart';

final _jpeg = testJpeg(texturedRgba(64, 48), 64, 48);

class _Frame implements SplatFrame {
  _Frame(this.time, this.sharpness, this._source);

  @override
  final Duration time;
  @override
  final double sharpness;
  final _Source _source;

  @override
  int get width => 1920;
  @override
  int get height => 1080;

  @override
  Future<({int width, int height})> writeJpeg(String path) async {
    _source.written.add(time);
    if (_source.writeFails) {
      // ENOSPC, ERROR_DISK_FULL on Windows
      throw FileSystemException(
        'No space left on device',
        path,
        OSError('No space left', Platform.isWindows ? 112 : 28),
      );
    }
    await File(path).writeAsBytes(_jpeg);
    return (width: 1600, height: 900);
  }
}

/// A video of [duration] at [fps] whose frame at a time has the sharpness [sharpnessAt]
class _Source implements SplatFrameSource {
  _Source(this.duration, {this.fps, required this.sharpnessAt, this.opens = true, this.writeFails = false});

  final Duration duration;
  final double? fps;
  final double? Function(Duration time) sharpnessAt;
  final bool opens;
  final bool writeFails;
  final asked = <Duration>[];
  final written = <Duration>[];
  var closed = false;

  @override
  Future<SplatVideoFacts> open(String resource) async {
    if (!opens) {
      throw const ConversionException(ImmersiveErrorCode.decodeFailed, 'not a video');
    }
    return SplatVideoFacts(duration: duration, fps: fps);
  }

  @override
  Future<SplatFrame?> frameAt(Duration time) async {
    asked.add(time);
    final sharpness = sharpnessAt(time);
    return sharpness == null ? null : _Frame(time, sharpness, this);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late Directory work;
  late NativeCancelFlag cancel;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('immuch360_splat_frames_');
    cancel = NativeCancelFlag();
  });

  tearDown(() async {
    cancel.free();
    await work.delete(recursive: true);
  });

  String images() => p.join(work.path, 'images');

  group('the plan', () {
    test('150 frames up to two minutes, one every 0.8 s beyond, 250 at most', () {
      expect(splatVideoFrameCount(const Duration(seconds: 10)), 150);
      expect(splatVideoFrameCount(const Duration(seconds: 111)), 150);
      expect(splatVideoFrameCount(const Duration(minutes: 2)), 150);
      expect(splatVideoFrameCount(const Duration(minutes: 3)), 225);
      expect(splatVideoFrameCount(const Duration(minutes: 4)), SplatV1.maxVideoFrames);
      expect(splatVideoFrameCount(const Duration(minutes: 5)), SplatV1.maxVideoFrames);
    });

    test('the lighthouse of the measure: 150 windows of four candidates, each inside its window', () {
      const duration = Duration(milliseconds: 110977);
      const fps = 30000 / 1001;
      final windows = planVideoFrames(duration, fps: fps);
      expect(windows, hasLength(150));
      var previous = const Duration(microseconds: -1);
      for (final window in windows) {
        expect(window.candidates, hasLength(splatFrameCandidates));
        for (final time in window.candidates) {
          expect(time, greaterThanOrEqualTo(window.start));
          expect(time, lessThan(window.end));
          expect(time, greaterThan(previous));
          previous = time;
        }
      }
      expect(windows.first.start, Duration.zero);
      expect(windows.last.end, duration);
      expect(previous.inMicroseconds, lessThan(duration.inMicroseconds - 1e6 / fps));
    });

    test('a short video: no more candidates than frames in a window, no more windows than frames', () {
      final ten = planVideoFrames(const Duration(seconds: 10), fps: 30);
      expect(ten, hasLength(150));
      expect(ten.map((window) => window.candidates.length).toSet(), {2});
      final three = planVideoFrames(const Duration(seconds: 3), fps: 30);
      expect(three, hasLength(90));
      expect(three.map((window) => window.candidates.length).toSet(), {1});
      final unknown = planVideoFrames(const Duration(seconds: 60));
      expect(unknown.map((window) => window.candidates.length).toSet(), {splatFrameCandidates});
      expect(planVideoFrames(Duration.zero), isEmpty);
    });

    test('a moment is named as the list of the left out says it', () {
      expect(splatMomentName(const Duration(milliseconds: 62480)), '1:02.4');
      expect(splatMomentName(Duration.zero), '0:00.0');
    });
  });

  group('the frames', () {
    test(
      'the sharpest candidate of each window, the blurred windows left out, numbered in the order of time',
      () async {
        const duration = Duration(seconds: 60);
        final windows = planVideoFrames(duration, fps: 30);
        const blurredWindows = {41, 70, 71};
        int windowOf(Duration time) => windows.indexWhere((window) => time >= window.start && time < window.end);
        double sharpnessAt(Duration time) {
          final window = windowOf(time);
          // A sharpness that changes within a window, its best at a candidate that moves from window to window
          final wave = 100 + 40 * math.sin(time.inMilliseconds / 37);
          return blurredWindows.contains(window) ? wave / 10 : wave;
        }

        final source = _Source(duration, fps: 30, sharpnessAt: sharpnessAt);
        final progress = <int>[];
        final inputs = await takeVideoFrames(
          'clip.mp4',
          source: source,
          imagesFolder: images(),
          cancel: cancel,
          onProgress: (done, total) {
            expect(total, 150);
            progress.add(done);
          },
        );
        expect(progress, [for (var i = 1; i <= 150; i++) i]);
        expect(source.asked, [for (final window in windows) ...window.candidates]);
        expect(source.closed, isTrue);
        expect(inputs.fromVideo, isTrue);
        expect(inputs.total, 150);
        expect(inputs.images, hasLength(147));
        expect(inputs.blurred, 3);
        expect(inputs.leftOut.map((out) => out.name), [
          for (final index in [41, 70, 71]) splatMomentName(source.written[index]),
        ]);
        // Each frame kept is the sharpest candidate of its window
        final kept = [
          for (final (index, window) in windows.indexed)
            if (!blurredWindows.contains(index))
              window.candidates.reduce((a, b) => sharpnessAt(b) > sharpnessAt(a) ? b : a),
        ];
        expect(inputs.images.map((image) => image.source), kept.map(splatMomentName));
        expect(inputs.images.map((image) => image.relativePath), [
          for (var i = 0; i < 147; i++) '$splatVideoFolder/${splatImageName(i)}',
        ]);
        final files = Directory(
          images(),
        ).listSync(recursive: true).whereType<File>().map((file) => p.basename(file.path));
        expect(files.toSet(), {for (var i = 0; i < 147; i++) splatImageName(i)});
        expect(inputs.cameras.keys, [splatVideoFolder]);
        expect(inputs.images.map((image) => (image.width, image.height)).toSet(), {(1600, 900)}, reason: 'as written');
      },
    );

    test('a window without any frame is left out as unreadable', () async {
      final source = _Source(
        const Duration(seconds: 30),
        fps: 25,
        sharpnessAt: (time) => time >= const Duration(seconds: 10) && time < const Duration(seconds: 11) ? null : 50,
      );
      final inputs = await takeVideoFrames('clip.mp4', source: source, imagesFolder: images(), cancel: cancel);
      final unreadable = inputs.leftOut.where((out) => out.reason == SplatLeftOutReason.unreadable);
      expect(unreadable, hasLength(5), reason: 'the five windows of 0.2 s between 10 and 11 s');
      expect(inputs.images, hasLength(145));
      expect(inputs.isEnough, isTrue);
    });

    test('a cancel ends it between two candidates, and the video is let go', () async {
      final source = _Source(const Duration(seconds: 60), fps: 30, sharpnessAt: (time) => 80);
      var seen = 0;
      await expectLater(
        takeVideoFrames(
          'clip.mp4',
          source: source,
          imagesFolder: images(),
          cancel: cancel,
          onProgress: (done, total) {
            if (++seen == 5) {
              cancel.cancel();
            }
          },
        ),
        throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.cancelled)),
      );
      expect(source.asked, hasLength(5 * splatFrameCandidates));
      expect(source.closed, isTrue);
    });

    test('a video that does not open ends it, a frame that cannot be written says why', () async {
      final closed = _Source(const Duration(seconds: 20), sharpnessAt: (time) => 1, opens: false);
      await expectLater(
        takeVideoFrames('clip.mp4', source: closed, imagesFolder: images(), cancel: cancel),
        throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.decodeFailed)),
      );
      expect(closed.closed, isTrue);

      final full = _Source(const Duration(seconds: 20), fps: 30, sharpnessAt: (time) => 1, writeFails: true);
      await expectLater(
        takeVideoFrames('clip.mp4', source: full, imagesFolder: images(), cancel: cancel),
        throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.diskFull)),
      );
    });

    test(
      'a video given as bytes is written next to the images for libmpv, then deleted, and the member released',
      () async {
        final log = <String>[];
        final member = _VideoMember(Uint8List.fromList([1, 2, 3]), log);
        final source = _Source(const Duration(seconds: 20), fps: 30, sharpnessAt: (time) => 60);
        final inputs = await takeMemberFrames(member, source: source, imagesFolder: images(), cancel: cancel);
        expect(inputs.images, hasLength(150));
        expect(log, ['load', 'release']);
        expect(File(p.join(work.path, 'video.mp4')).existsSync(), isFalse);
      },
    );
  });
}

class _VideoMember implements SplatMember {
  _VideoMember(this.bytes, this.log);

  final Uint8List bytes;
  final List<String> log;

  @override
  String get name => 'VID_0001.mp4';
  @override
  DateTime? get taken => null;
  @override
  String? get camera => null;

  @override
  Future<ImmersiveSource> load(NativeCancelFlag cancel) async {
    log.add('load');
    return ImmersiveSource(name: name, size: bytes.length, sha1: 'sha1', bytes: bytes);
  }

  @override
  Future<void> release() async => log.add('release');
}
