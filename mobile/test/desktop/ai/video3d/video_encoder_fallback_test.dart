// The encoder of a 3D video that stops during the job (FreeKC's PC, 23 Nov 2026: the hardware H.264 MFT passed its
// test into the null muxer, then died at the Matroska header of the first segment, and the job failed with a bare
// "Write failed"): the test runs the job's own command, the stop is told with FFmpeg's words, the job goes on once with
// the next encoder, this computer remembers it, and a dead end names the encoder and a smaller size.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_encoder_memory.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:path/path.dart' as p;

import 'fake_ffmpeg.dart';

class _Memory implements VideoEncoderMemory {
  final stopped = <(VideoEncoder, int, int, String)>[];

  @override
  Future<Set<VideoEncoder>> stoppedAt(int width, int height) async => {
    for (final (encoder, w, h, _) in stopped)
      if (w == width && h == height) encoder,
  };

  @override
  Future<void> remember(VideoEncoder encoder, int width, int height, String said) async =>
      stopped.add((encoder, width, height, said));
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('video3d-fallback-');
    File(p.join(temp.path, 'clip.mp4')).writeAsBytesSync(List.generate(1000, (i) => i % 251));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  const windows = [VideoEncoder.h264MfHardware, VideoEncoder.h264Mf, VideoEncoder.svtAv1];

  VideoConversion conversion(
    FakeFfmpegRunner runner, {
    String name = 'clip_3D_LRF_Full_SBS.mp4',
    List<String>? logs,
    List<VideoJobProgress>? progress,
    VideoEncoderMemory? memory,
    Future<void> Function()? betweenWindows,
  }) => VideoConversion(
    request: VideoJobRequest(
      sourcePath: p.join(temp.path, 'clip.mp4'),
      outputPath: p.join(temp.path, name),
      workFolder: Directory(p.join(temp.path, '$videoWorkPrefix$name')),
      ffmpeg: 'ffmpeg',
      ffprobe: 'ffprobe',
      quality: VideoDepthQuality.fast,
      relief: const VideoReliefSettings(parallax: 0.015),
      encoders: windows,
      segmentSeconds: 1,
    ),
    runner: runner,
    workerFactory: ({required eyeWidth, required eyeHeight, required modelWidth, required modelHeight}) async =>
        LocalVideoFrameWorker(
          ops: const DartVideoFrameOps(),
          model: tinyVdaInDart,
          eyeWidth: eyeWidth,
          eyeHeight: eyeHeight,
          modelWidth: modelWidth,
          modelHeight: modelHeight,
          relief: const VideoReliefSettings(parallax: 0.015),
        ),
    onLog: logs?.add,
    onProgress: progress?.add,
    encoderMemory: memory,
    betweenWindows: betweenWindows,
  );

  FakeFfmpegRunner runner({
    Set<VideoEncoder> passing = const {VideoEncoder.h264MfHardware, VideoEncoder.h264Mf, VideoEncoder.svtAv1},
    Map<VideoEncoder, int>? diesAfter,
    int dieAtSegment = 1,
    bool remakeFails = false,
  }) => FakeFfmpegRunner(
    probe: fakeVideoProbe(60, 2.4),
    times: [for (var i = 0; i < 60; i++) i / 25],
    passing: passing,
    diesAfter: diesAfter,
    dieAtSegment: dieAtSegment,
    remakeFails: remakeFails,
  );

  List<List<String>> segmentCalls(FakeFfmpegRunner fake) => [
    for (final call in fake.calls)
      if (call.contains('pipe:0') && p.basename(call.last).startsWith('seg-')) call,
  ];

  test(
    'the test feeds the frames of a job into a Matroska file and reads it back; a death at the header fails it',
    () async {
      final fake = runner(passing: const {VideoEncoder.h264Mf});
      final reasons = <VideoEncoder, String>{};
      final chosen = await chooseVideoEncoder(
        fake,
        'ffmpeg',
        'ffprobe',
        windows,
        3072 ~/ 32,
        3072 ~/ 32,
        const VideoRate(30000, 1001),
        folder: Directory(p.join(temp.path, 'tests')),
        markLeftRight: false,
        onTest: (encoder, passed, reason) => reasons[encoder] = passed ? 'passed' : reason,
      );
      expect(chosen, VideoEncoder.h264Mf);
      expect(reasons.keys, [VideoEncoder.h264MfHardware, VideoEncoder.h264Mf]);
      expect(
        reasons[VideoEncoder.h264MfHardware],
        'stopped with -1094995529: [out#0/matroska] Could not write header (incorrect codec parameters ?): Invalid data '
        'found when processing input\n'
        '[vf#0:0] Error sending frames to consumers: Invalid data found when processing input',
      );
      expect(reasons[VideoEncoder.h264Mf], 'passed');
      final tests = [
        for (final call in fake.calls)
          if (call.last.contains('encoder-test-')) call,
      ];
      expect(tests, hasLength(3), reason: 'two encoder runs and the ffprobe count of the one that passed');
      expect(tests.first, containsAllInOrder(['-f', 'rawvideo', '-s', '96x96', '-i', 'pipe:0']));
      expect(tests.first, containsAllInOrder(['-f', 'matroska']));
      expect(tests.last, contains('-count_frames'));
      expect(Directory(p.join(temp.path, 'tests')).listSync(), isEmpty, reason: 'the files of the tests are deleted');
    },
  );

  test(
    'the hardware encoder dies in the first segment: the job goes on with the software one, said and remembered',
    () async {
      final fake = runner(diesAfter: {VideoEncoder.h264MfHardware: 2});
      final logs = <String>[];
      final progress = <VideoJobProgress>[];
      final memory = _Memory();
      final result = await conversion(fake, logs: logs, progress: progress, memory: memory).run();

      expect(result.frames, 60);
      expect(result.encoder, VideoEncoder.h264Mf);
      expect(
        logs,
        contains(
          // Frames this small reach the fake encoder at the close of the segment, not at a flush
          allOf(
            startsWith('The encoder h264MfHardware of seg-0001.seg stopped with -1094995529 after '),
            contains('frames: [out#0/matroska] Could not write header'),
          ),
        ),
      );
      expect(logs, contains('encoder test h264Mf: passed'));
      expect(logs, contains('the encoder h264MfHardware stopped: continuing with h264Mf from the last segment kept'));
      expect(memory.stopped.single.$1, VideoEncoder.h264MfHardware);
      expect((memory.stopped.single.$2, memory.stopped.single.$3), (56, 28));
      expect(memory.stopped.single.$4, contains('Could not write header'));
      expect(progress.last.encoderSwitch, (from: VideoEncoder.h264MfHardware, to: VideoEncoder.h264Mf));
      // Every segment kept is the software encoder's: the hardware one's first segment was dropped
      final segments = segmentCalls(fake);
      expect(segments.first, contains('-hw_encoding'));
      expect(segments.skip(1), everyElement(isNot(contains('-hw_encoding'))));
      expect(segments.skip(1), everyElement(containsAllInOrder(['-c:v', 'h264_mf'])));
      expect(fake.calls.where((call) => call.last.endsWith('.remade')), isEmpty, reason: 'no segment was kept before');
      expect(File(p.join(temp.path, 'clip_3D_LRF_Full_SBS.mp4')).existsSync(), isTrue);
    },
  );

  test('an encoder whose file lacks frames fails its test', () async {
    final fake = FakeFfmpegRunner(probe: fakeVideoProbe(60, 2.4), times: const [], testFramesLost: 2);
    String? reason;
    final chosen = await chooseVideoEncoder(
      fake,
      'ffmpeg',
      'ffprobe',
      const [VideoEncoder.svtAv1],
      64,
      32,
      const VideoRate(30, 1),
      folder: temp,
      onTest: (encoder, passed, why) => reason = why,
    );
    expect(chosen, isNull);
    expect(reason, 'its file holds 28 frames of 30');
  });

  test('it dies after a segment was kept: that segment is made again by the next encoder, the job goes on', () async {
    final fake = runner(diesAfter: {VideoEncoder.h264MfHardware: 3}, dieAtSegment: 2);
    final logs = <String>[];
    final result = await conversion(fake, logs: logs).run();
    expect(result.frames, 60);
    expect(result.encoder, VideoEncoder.h264Mf);
    final remade = fake.calls.where((call) => call.last.endsWith('.remade')).toList();
    expect(remade, hasLength(1));
    expect(remade.single, containsAllInOrder(['-i', endsWith('seg-0001.seg'), '-fps_mode', 'passthrough']));
    expect(remade.single, isNot(contains('-hw_encoding')));
    expect(logs, contains('segment 1 made again by h264Mf'));
    // The mux joined the remade first segment and the software ones after
    expect(fake.concatList, contains('seg-0001.seg'));
    final out = File(p.join(temp.path, 'clip_3D_LRF_Full_SBS.mp4')).readAsStringSync();
    expect(out, startsWith('remade by h264Mf: '));
  });

  test(
    'a second stop is a dead end: the encoder, the frame and FFmpeg\'s words, no smaller size for a flat video',
    () async {
      final fake = runner(diesAfter: {VideoEncoder.h264MfHardware: 2, VideoEncoder.h264Mf: 2});
      final logs = <String>[];
      try {
        await conversion(fake, logs: logs).run();
        fail('the job should fail');
      } on VideoJobException catch (error) {
        final dead = videoEncoderDeadEndOf(error.message)!;
        expect(dead.encoder, VideoEncoder.h264Mf);
        expect(dead.frame, '56 x 28');
        expect(dead.smaller, isNull);
        expect(dead.said, contains('Could not write header'));
        expect(error, isNot(isA<VideoEncoderStopped>()));
      }
      expect(logs.where((line) => line.contains('stopped with')), hasLength(2));
    },
  );

  test('no other encoder passes its test: a dead end naming the one that stopped', () async {
    final fake = runner(passing: const {VideoEncoder.h264MfHardware}, diesAfter: {VideoEncoder.h264MfHardware: 2});
    final memory = _Memory();
    try {
      await conversion(fake, memory: memory).run();
      fail('the job should fail');
    } on VideoJobException catch (error) {
      expect(videoEncoderDeadEndOf(error.message)?.encoder, VideoEncoder.h264MfHardware);
    }
    expect(memory.stopped.single.$1, VideoEncoder.h264MfHardware);
  });

  test('a segment that cannot be made again is a dead end of the next encoder', () async {
    final fake = runner(diesAfter: {VideoEncoder.h264MfHardware: 3}, dieAtSegment: 2, remakeFails: true);
    try {
      await conversion(fake).run();
      fail('the job should fail');
    } on VideoJobException catch (error) {
      expect(videoEncoderDeadEndOf(error.message)?.encoder, VideoEncoder.h264Mf);
    }
  });

  test(
    'an encoder remembered as stopped at this frame is skipped, and tried after all when none other passes',
    () async {
      final memory = _Memory()..stopped.add((VideoEncoder.h264MfHardware, 56, 28, 'Could not write header'));
      final logs = <String>[];
      final fake = runner();
      final result = await conversion(fake, logs: logs, memory: memory).run();
      expect(result.encoder, VideoEncoder.h264Mf);
      expect(logs.where((line) => line.startsWith('encoder test')), [
        'encoder test h264MfHardware: skipped, it stopped during a 3D video at 56x28 on this computer',
        'encoder test h264Mf: passed',
      ]);
      expect(segmentCalls(fake), everyElement(isNot(contains('-hw_encoding'))));

      // Another size: tried as usual
      final other = _Memory()..stopped.add((VideoEncoder.h264MfHardware, 3072, 3072, ''));
      final second = await conversion(runner(), name: 'c.mp4', memory: other).run();
      expect(second.encoder, VideoEncoder.h264MfHardware);

      // Only the remembered one passes: tried after all
      final only = await conversion(
        runner(passing: const {VideoEncoder.h264MfHardware}),
        name: 'd.mp4',
        memory: memory,
      ).run();
      expect(only.encoder, VideoEncoder.h264MfHardware);
    },
  );

  test('paused after the switch: the job file keeps the new encoder and a Resume goes on with it', () async {
    final fake = runner(diesAfter: {VideoEncoder.h264MfHardware: 2});
    final progress = <VideoJobProgress>[];
    late VideoConversion first;
    first = conversion(
      fake,
      progress: progress,
      betweenWindows: () async {
        if (progress.any((each) => each.encoderSwitch != null)) {
          first.pause();
        }
      },
    );
    await expectLater(first.run(), throwsA(isA<VideoJobStopped>()));
    final work = Directory(p.join(temp.path, '${videoWorkPrefix}clip_3D_LRF_Full_SBS.mp4'));
    final job = await VideoJobFile.read(work);
    expect(job!.settings['encoder'], 'h264Mf');

    final calls = fake.calls.length;
    final logs = <String>[];
    final resumed = await conversion(fake, logs: logs).run();
    expect(resumed.encoder, VideoEncoder.h264Mf);
    expect(resumed.frames, 60);
    // The encoder of the job file is tested again before the first frame, and only that one
    expect(logs.where((line) => line.startsWith('encoder test')), [
      'encoder test h264Mf (the encoder of the job, on resume): passed',
    ]);
    expect(
      fake.calls.skip(calls).where((call) => call.contains('pipe:0')),
      everyElement(isNot(contains('-hw_encoding'))),
    );
  });

  test(
    'on resume the encoder of the job fails its test: the next one passes, makes the kept segments again, goes on',
    () async {
      // A first run on the hardware encoder, paused after a segment was kept
      final fake = runner();
      late VideoConversion first;
      first = conversion(
        fake,
        betweenWindows: () async {
          final job = await VideoJobFile.read(
            Directory(p.join(temp.path, '${videoWorkPrefix}clip_3D_LRF_Full_SBS.mp4')),
          );
          if (job != null && job.segments.isNotEmpty) {
            first.pause();
          }
        },
      );
      await expectLater(first.run(), throwsA(isA<VideoJobStopped>()));
      final work = Directory(p.join(temp.path, '${videoWorkPrefix}clip_3D_LRF_Full_SBS.mp4'));
      final before = await VideoJobFile.read(work);
      expect(before!.settings['encoder'], 'h264MfHardware');
      expect(before.segments, isNotEmpty);

      // The driver changed meanwhile: the hardware encoder no longer passes its test
      final later = runner(passing: const {VideoEncoder.h264Mf, VideoEncoder.svtAv1});
      final logs = <String>[];
      final progress = <VideoJobProgress>[];
      final memory = _Memory();
      final resumed = await conversion(later, logs: logs, progress: progress, memory: memory).run();
      expect(resumed.encoder, VideoEncoder.h264Mf);
      expect(resumed.frames, 60);
      expect(logs.where((line) => line.startsWith('encoder test')).toList(), [
        allOf(
          startsWith('encoder test h264MfHardware (the encoder of the job, on resume): failed '),
          contains('Could not write header'),
        ),
        'encoder test h264Mf: passed',
      ]);
      expect(logs, contains('the encoder h264MfHardware of the job failed its test on resume: continuing with h264Mf'));
      expect(logs, contains('segment 1 made again by h264Mf'));
      expect(progress.last.encoderSwitch, (from: VideoEncoder.h264MfHardware, to: VideoEncoder.h264Mf));
      expect(memory.stopped, isEmpty, reason: 'a failed test is not a stop during a job');
      expect((await VideoJobFile.read(work))?.settings['encoder'], anyOf(isNull, 'h264Mf'));
      // No frame went to the hardware encoder after the resume: the test came before the first frame
      expect(segmentCalls(later), everyElement(isNot(contains('-hw_encoding'))));
      final out = File(p.join(temp.path, 'clip_3D_LRF_Full_SBS.mp4')).readAsStringSync();
      expect(out, startsWith('remade by h264Mf: '));
    },
  );

  test('on resume no encoder passes its test: the job fails with the reason, the work folder kept', () async {
    final fake = runner();
    late VideoConversion first;
    first = conversion(
      fake,
      betweenWindows: () async {
        final job = await VideoJobFile.read(Directory(p.join(temp.path, '${videoWorkPrefix}clip_3D_LRF_Full_SBS.mp4')));
        if (job != null && job.segments.isNotEmpty) {
          first.pause();
        }
      },
    );
    await expectLater(first.run(), throwsA(isA<VideoJobStopped>()));
    final logs = <String>[];
    await expectLater(
      conversion(runner(passing: const {}), logs: logs).run(),
      throwsA(isA<VideoJobException>().having((error) => error.message, 'message', contains('passed its test'))),
    );
    expect(logs.where((line) => line.startsWith('encoder test')), hasLength(3));
    expect(Directory(p.join(temp.path, '${videoWorkPrefix}clip_3D_LRF_Full_SBS.mp4')).existsSync(), isTrue);
  });

  test('the smaller 360° size proposed by a dead end', () {
    expect(videoSmallerSphereEye(4096), 3072);
    expect(videoSmallerSphereEye(3072), 2048);
    expect(videoSmallerSphereEye(2048), isNull);
    expect(videoSmallerSphereEye(null), isNull);
  });

  test('the file of this computer: kept per encoder and size, forgotten after 30 days', () async {
    var now = DateTime.utc(2026, 11, 23, 9, 37);
    final memory = FileVideoEncoderMemory(directory: () async => temp, now: () => now);
    expect(await memory.stoppedAt(3072, 3072), isEmpty);
    await memory.remember(VideoEncoder.h264MfHardware, 3072, 3072, 'Could not write header');
    await memory.remember(VideoEncoder.h264MfHardware, 3072, 3072, 'again');
    await memory.remember(VideoEncoder.h264Mf, 4096, 4096, '');
    expect(await memory.stoppedAt(3072, 3072), {VideoEncoder.h264MfHardware});
    expect(await memory.stoppedAt(4096, 4096), {VideoEncoder.h264Mf});
    expect(await memory.stoppedAt(2048, 2048), isEmpty);
    final text = File(p.join(temp.path, FileVideoEncoderMemory.fileName)).readAsStringSync();
    expect('h264MfHardware'.allMatches(text), hasLength(1), reason: 'one entry per encoder and size');
    // Read again by another instance, as the next start of the app
    expect(await FileVideoEncoderMemory(directory: () async => temp, now: () => now).stoppedAt(3072, 3072), {
      VideoEncoder.h264MfHardware,
    });
    now = now.add(const Duration(days: videoEncoderMemoryDays + 1));
    expect(await memory.stoppedAt(3072, 3072), isEmpty);
    File(p.join(temp.path, FileVideoEncoderMemory.fileName)).writeAsStringSync('not json');
    expect(await memory.stoppedAt(3072, 3072), isEmpty);
  });
}
