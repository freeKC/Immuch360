// A 360° video made 360° 3D (lot ai-360-3d-51), through the worker of the sphere and the whole engine with the FFmpeg
// program played in Dart and tiny_vda.onnx in Dart: the frame top and bottom with the left eye on top as it came, no
// shift at the poles, the right eye wrapped around the seam; the six faces keeping their windows together, a cut
// found once on the whole frame; a state after a window, written, read back and resumed giving the bytes of a job
// never stopped; the segments not marked left right, the MP4 marked 360° top and bottom and read back by the app's
// probe; a flat job refusing a 360° video as before.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/sphere_video_worker.dart';
import 'package:immich_mobile/desktop/ai/video3d/spherical_mp4_writer.dart';
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:path/path.dart' as p;

import 'fake_ffmpeg.dart';
import 'tiny_mp4.dart';

const _eyeWidth = 56;
const _eyeHeight = 28;
const _side = 28;

LocalSphereVideoFrameWorker _worker() => LocalSphereVideoFrameWorker(
  ops: const DartVideoFrameOps(),
  model: tinyVdaInDart,
  eyeWidth: _eyeWidth,
  eyeHeight: _eyeHeight,
  side: _side,
  shiftDegrees: 12,
);

/// A frame of the sphere: a pattern that moves, and a different scene from frame [cut] on
Uint8List _frame(int index, {int cut = 1 << 30}) {
  final rgb = fakeVideoFrame(index, width: _eyeWidth, height: _eyeHeight);
  if (index >= cut) {
    for (var i = 0; i < rgb.length; i += 3) {
      rgb[i] = 230 - rgb[i] ~/ 4;
      rgb[i + 1] = 240 - rgb[i + 1] ~/ 3;
    }
  }
  return rgb;
}

Future<List<VideoSbsFrame>> _run(
  LocalSphereVideoFrameWorker worker,
  Iterable<int> indexes, {
  int cut = 1 << 30,
}) async => [for (final i in indexes) ...await worker.add(_frame(i, cut: cut))];

void main() {
  test(
    'each frame top and bottom: the left eye on top as it came, the right eye below, the same at the poles',
    () async {
      final worker = _worker();
      final frames = [...await _run(worker, Iterable.generate(40)), ...await worker.finish()];
      expect([for (final frame in frames) frame.index], List.generate(40, (i) => i));
      const eye = _eyeWidth * _eyeHeight * 3;
      const row = _eyeWidth * 3;
      var poles = 0;
      var equator = 0;
      for (final frame in frames) {
        expect(frame.bytes.length, 2 * eye);
        expect(Uint8List.sublistView(frame.bytes, 0, eye), _frame(frame.index));
        int differs(int y) {
          var sum = 0;
          for (var i = 0; i < row; i++) {
            sum += (frame.bytes[eye + y * row + i] - frame.bytes[y * row + i]).abs();
          }
          return sum;
        }

        poles += differs(0) + differs(_eyeHeight - 1);
        equator += differs(_eyeHeight ~/ 2) + differs(_eyeHeight ~/ 2 - 1);
      }
      // The equator moves, the rows of the poles hardly (cos(latitude) of 0.056 there in this small frame)
      expect(equator, greaterThan(40 * row));
      expect(poles, lessThan(equator ~/ 10));
      expect((await worker.counts()).windows, 2);
    },
  );

  test('a cut found once on the whole frame: every face starts its scene there', () async {
    final worker = _worker();
    final frames = [...await _run(worker, Iterable.generate(50), cut: 30), ...await worker.finish()];
    expect(frames.length, 50);
    expect((await worker.counts()).cuts, [30]);
  });

  test('the state after a window, written and read back, goes on as a job never stopped', () async {
    final whole = _worker();
    final expected = [...await _run(whole, Iterable.generate(70)), ...await whole.finish()];

    final first = _worker();
    final before = <VideoSbsFrame>[];
    VdaLoopState? state;
    for (var i = 0; i < 70 && state == null; i++) {
      before.addAll(await first.add(_frame(i)));
      if (i > 32) {
        state = await first.stateAfterWindow();
      }
    }
    expect(state, isNotNull);
    final read = decodeVdaLoopState(encodeVdaLoopState(state!))!;
    expect(read.views.length, 6);
    expect(read.alignment!.length, 12);
    expect(read.firstHeld, before.length);

    final second = _worker();
    await second.restore(read, [for (var i = 0; i < vdaBlended; i++) _frame(read.firstHeld + i)]);
    final after = [
      ...await _run(second, Iterable.generate(70 - read.nextIndex, (i) => read.nextIndex + i)),
      ...await second.finish(),
    ];
    final resumed = [...before, ...after];
    expect(resumed.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      expect(resumed[i].index, expected[i].index);
      expect(resumed[i].bytes, expected[i].bytes, reason: 'frame $i');
    }
  });

  group('the engine', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('video3d-sphere-');
      File(p.join(temp.path, 'trip.mp4')).writeAsBytesSync(List.generate(1000, (i) => i % 251));
    });
    tearDown(() => temp.deleteSync(recursive: true));

    VideoConversion conversion(FakeFfmpegRunner runner, {int? sphere = _eyeWidth, void Function(String)? onLog}) =>
        VideoConversion(
          request: VideoJobRequest(
            sourcePath: p.join(temp.path, 'trip.mp4'),
            outputPath: p.join(temp.path, 'trip_360_3D.mp4'),
            workFolder: Directory(p.join(temp.path, '${videoWorkPrefix}trip')),
            ffmpeg: 'ffmpeg',
            ffprobe: 'ffprobe',
            quality: VideoDepthQuality.fast,
            relief: const VideoReliefSettings(parallax: 0.02, sphere: true),
            encoders: const [VideoEncoder.svtAv1],
            segmentSeconds: 1,
            sphereEyeWidth: sphere,
          ),
          runner: runner,
          workerFactory: ({required eyeWidth, required eyeHeight, required modelWidth, required modelHeight}) async {
            expect((eyeWidth, eyeHeight, modelWidth, modelHeight), (_eyeWidth, _eyeHeight, 280, 280));
            return LocalSphereVideoFrameWorker(
              ops: const DartVideoFrameOps(),
              model: tinyVdaInDart,
              eyeWidth: eyeWidth,
              eyeHeight: eyeHeight,
              side: _side,
              shiftDegrees: 1,
            );
          },
          onLog: onLog,
        );

    Map<String, Object?> sphereProbe({List<Map<String, Object?>> side = const []}) {
      final probe = fakeVideoProbe(40, 1.6, width: 112, height: 56, audio: 'aac');
      final video = (probe['streams']! as List).first as Map<String, Object?>;
      video['side_data_list'] = [
        {'side_data_type': 'Spherical Mapping', 'projection': 'equirectangular'},
        ...side,
      ];
      return probe;
    }

    test('a 360° video: eyes of 2:1, the frame top and bottom, segments unmarked, the MP4 marked 360° 3D', () async {
      final runner = FakeFfmpegRunner(probe: sphereProbe(), times: [for (var i = 0; i < 40; i++) i / 25], mp4Mux: true);
      final logs = <String>[];
      final result = await conversion(runner, onLog: logs.add).run();
      expect(result.frames, 40);
      final decoder = runner.calls.firstWhere((call) => call.contains('-stats_enc_pre'));
      expect(decoder[decoder.indexOf('-vf') + 1], 'scale=56:28:flags=area,format=rgb24');
      // The test of the encoder: the command of a segment at the square frame, unmarked as the segments
      final test = runner.calls.firstWhere((call) => p.basename(call.last).startsWith('encoder-test-'));
      expect(test, containsAllInOrder(['-s', '56x56', '-framerate', '25/1', '-i', 'pipe:0']));
      expect(test, isNot(contains('stereo_mode=left_right')));
      final segments = runner.calls.where((call) => call.contains('matroska')).toList();
      expect(segments, isNotEmpty);
      for (final segment in segments) {
        expect(segment[segment.indexOf('-s') + 1], '56x56');
        expect(segment, isNot(contains('stereo_mode=left_right')));
      }
      expect(logs, contains(startsWith('marked as a 360° video top and bottom: 1 video track')));
      // The stages of the sphere timed in the job log (lot ai-360-3d-51)
      expect(
        logs,
        contains(
          matches(
            RegExp(
              r'^timings of this run, \d+ frames: decode \d+, faces \d+, window \d+, model \d+, merge \d+, right eye \d+, encode \d+ ms a frame',
            ),
          ),
        ),
      );
      final output = File(p.join(temp.path, 'trip_360_3D.mp4'));
      final bytes = output.readAsBytesSync();
      final probe = await probeSphericalMetadata(
        (offset, length) async =>
            Uint8List.sublistView(bytes, offset.clamp(0, bytes.length), (offset + length).clamp(0, bytes.length)),
      );
      expect((probe.hasSphericalMetadata, probe.stereo, probe.halfSphere), (true, StereoLayout.topBottom, false));
      expect(File('${output.path}.part').existsSync(), isFalse);
      expect(File('${output.path}.part.sphere').existsSync(), isFalse);
    });

    test('paused after a segment and resumed: the same bytes as a job never stopped', () async {
      Future<String> make(String folder, {bool pause = false}) async {
        final runner = FakeFfmpegRunner(
          probe: sphereProbe(),
          times: [for (var i = 0; i < 70; i++) i / 25],
          mp4Mux: true,
        );
        late VideoConversion job;
        var paused = false;
        job = conversion(
          runner,
          onLog: (line) {
            if (pause && !paused && line.startsWith('segment 1:')) {
              paused = true;
              job.pause();
            }
          },
        );
        try {
          await job.run();
        } on VideoJobStopped {
          expect(pause, isTrue);
          final resumed = conversion(runner);
          await resumed.run();
          final resume = runner.calls.lastWhere((call) => call.contains('-stats_enc_pre'));
          expect(resume, contains('-ss'));
        }
        final out = File(p.join(temp.path, 'trip_360_3D.mp4'));
        final sum = crypto.sha256.convert(out.readAsBytesSync()).toString();
        out.renameSync(p.join(temp.path, '$folder.mp4'));
        return sum;
      }

      final whole = await make('whole');
      final resumed = await make('resumed', pause: true);
      expect(resumed, whole);
    });

    test('a 360° video in a flat job is refused as before; a 360° job refuses two eyes and VR180', () async {
      final times = [for (var i = 0; i < 40; i++) i / 25];
      await expectLater(
        conversion(FakeFfmpegRunner(probe: sphereProbe(), times: times), sphere: null).run(),
        throwsA(isA<VideoJobException>().having((e) => e.refusal, 'refusal', VideoRefusal.sphere360)),
      );
      await expectLater(
        conversion(
          FakeFfmpegRunner(
            probe: sphereProbe(
              side: [
                {'side_data_type': 'Stereo 3D', 'type': 'top and bottom'},
              ],
            ),
            times: times,
          ),
        ).run(),
        throwsA(isA<VideoJobException>().having((e) => e.refusal, 'refusal', VideoRefusal.alreadyStereo)),
      );
    });

    test('the engine reads the boxes of the source with the app\'s own probe, as the dialog does for a file of this '
        'computer: a downloaded file whose marks ffprobe does not give is still seen as 360° or as two eyes', () async {
      final times = [for (var i = 0; i < 40; i++) i / 25];
      // ffprobe sees a plain 2:1 video, no side data; the file itself says 360°
      Map<String, Object?> plain() => fakeVideoProbe(40, 1.6, width: 112, height: 56, audio: 'aac');
      Future<void> source(StereoLayout stereo) async {
        final unmarked = p.join(temp.path, 'unmarked.mp4');
        File(unmarked).writeAsBytesSync(tinyMp4(width: 112, height: 56));
        await writeSphericalMp4(unmarked, p.join(temp.path, 'trip.mp4'), stereo: stereo);
      }

      await source(StereoLayout.mono);
      await expectLater(
        conversion(FakeFfmpegRunner(probe: plain(), times: times), sphere: null).run(),
        throwsA(isA<VideoJobException>().having((e) => e.refusal, 'refusal', VideoRefusal.sphere360)),
      );
      await source(StereoLayout.topBottom);
      await expectLater(
        conversion(FakeFfmpegRunner(probe: plain(), times: times)).run(),
        throwsA(isA<VideoJobException>().having((e) => e.refusal, 'refusal', VideoRefusal.alreadyStereo)),
      );
    });
  });
}
