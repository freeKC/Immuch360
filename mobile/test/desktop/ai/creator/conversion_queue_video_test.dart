// The 3D videos in the queue of the conversions (release 49, video3d-plan.md section 4.5): a job from its reading to
// its MP4 with its frames, pace and segments, kept in video_jobs.json while it is not finished; Pause with its work
// kept and Resume going on from it; Stop and Discard deleting it; the refusals of the engine as reasons to skip; a
// failure with its words and its log, a full disk pausing the queue; the videos stopped put back at the next start;
// the 3D photos asked meanwhile let go first between two windows. Then the real engine (VideoConversion, the window
// loop, relief-v1 in Dart) on a synthetic clip played by an FFmpeg in Dart, paused after its first segment and resumed
// through the queue: the bytes of an uninterrupted job.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_frame_ops.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_jobs.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_conversion_output.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_video_job_engine.dart';
import '../video3d/fake_ffmpeg.dart';

/// A video of the server: no file on this computer
class _ServerVideo implements ConversionSource {
  @override
  String get name => 'server.mp4';

  @override
  String? get folder => null;

  @override
  ImmersiveExif get exif => const ImmersiveExif();

  @override
  Future<ImmersiveSource> prepare(_) => throw const ConversionException(ImmersiveErrorCode.sourceLost);

  @override
  Future<void> release() async {}
}

/// The engine of the 3D photos, held at its depth until [release]
class _Photos extends FakeImmersiveEngine {
  _Photos() : super(holdStage: ImmersiveStage.depth);
}

void main() {
  late Directory root;
  late String videos;
  late Directory support;
  late VideoJobEngine engine;
  late ImmersiveEngine photos;
  late VideoJobsStore store;
  late DesktopAiSettingsStore settings;
  late ProviderContainer container;
  late int records;

  setUp(() {
    root = Directory.systemTemp.createTempSync('conversion_queue_video_');
    videos = p.join(root.path, 'Videos');
    Directory(videos).createSync();
    support = Directory(p.join(root.path, 'support'))..createSync();
    store = VideoJobsStore(settingsDirectory: () async => support);
    settings = DesktopAiSettingsStore(settingsDirectory: () async => support);
    engine = FakeVideoJobEngine(logFolder: p.join(root.path, 'logs'));
    photos = FakeImmersiveEngine();
    records = 0;
  });

  tearDown(() {
    container.dispose();
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        root.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });

  ConversionQueueNotifier queue() {
    container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWith(
          (ref) => ConversionTools(
            engine: photos,
            output: FakeConversionOutput(),
            finder: ExistingVersionFinder(),
            creatorTool: 'Immuch360 Desktop 3.4.4 (linux)',
            settings: settings,
            video: engine,
            videoJobs: store,
            appVersion: '3.4.4',
            // Room for a 3D photo beside a video, whatever this computer has free
            memory: const _Memory(),
          ),
        ),
      ],
    );
    return container.read(conversionQueueProvider.notifier);
  }

  ConversionQueueState state() => container.read(conversionQueueProvider);

  Future<void> until(bool Function(ConversionQueueState state) test, {Duration within = const Duration(seconds: 20)}) {
    if (test(state())) {
      return Future.value();
    }
    final reached = Completer<void>();
    final subscription = container.listen(conversionQueueProvider, (_, next) {
      if (!reached.isCompleted && test(next)) {
        reached.complete();
      }
    });
    return reached.future.timeout(within).whenComplete(subscription.close);
  }

  ConversionRequest video(String name, {String? folder}) {
    final path = p.join(folder ?? videos, name);
    File(path).writeAsBytesSync(List.generate(1000, (i) => i % 251));
    return ConversionRequest(
      source: LocalFileSource(path),
      target: ConversionTarget(folder: p.dirname(path), fileName: videoOutputName(name, VideoSbsPacking.full)),
    );
  }

  List<String> addVideos(
    ConversionQueueNotifier notifier,
    List<ConversionRequest> requests, {
    VideoDepthQuality quality = VideoDepthQuality.standard,
  }) => notifier.addVideos(
    requests,
    settingsOf: (index) {
      final id = 'job${records++}';
      return VideoJobSettings(
        recordId: id,
        workFolder: videoWorkFolderIn(requests[index].target!.folder, id),
        quality: quality,
      );
    },
  );

  ConversionJob job(String id) => state().byId(id)!;

  test('a 3D video runs from its reading to its MP4, kept in video_jobs.json until it is made', () async {
    final notifier = queue();
    final seen = <ConversionState>[];
    final frames = <int>[];
    container.listen(conversionQueueProvider, (_, next) {
      final job = next.jobs.single;
      if (seen.isEmpty || seen.last != job.state) {
        seen.add(job.state);
      }
      if (job.videoProgress case final progress?) {
        frames.add(progress.framesDone);
      }
    });
    final ids = addVideos(notifier, [video('clip.mp4')]);
    await until((state) => state.jobs.single.state.isEnded);

    final made = job(ids.single);
    expect(seen, [
      ConversionState.waiting,
      ConversionState.reading,
      ConversionState.depth,
      ConversionState.writing,
      ConversionState.done,
    ]);
    expect(frames.first, 0);
    expect(frames, containsAllInOrder([22, 44, 66, 88, 110]));
    expect(made.writtenPath, p.join(videos, 'clip_3D_LRF_Full_SBS.mp4'));
    expect(File(made.writtenPath!).existsSync(), isTrue);
    expect(made.videoDone?.frames, 110);
    expect(made.perMille, 1000);
    expect(await store.read(), isEmpty);
    // Its pace, the first guess of the next one at that quality
    expect((await settings.read()).videoFrameMillis, {'standard': 800});
    final spec = (engine as FakeVideoJobEngine).runs.single;
    expect(spec.settings.workFolder, p.join(videos, '${videoWorkPrefix}job0'));
    expect(spec.appVersion, '3.4.4');
  });

  test('its progress: frames, pace and time left once three windows ran, segments, the mux; never back', () async {
    (engine as FakeVideoJobEngine).holdAfter = 3;
    final notifier = queue();
    final ids = addVideos(notifier, [video('clip.mp4')]);
    await until((state) => state.jobs.single.videoProgress?.windows == 3);

    final running = job(ids.single);
    expect(running.state, ConversionState.depth);
    expect(running.videoProgress!.framesDone, 66);
    expect(running.videoProgress!.framesPerSecond, 1.25);
    expect(running.remaining, const Duration(seconds: 35));
    expect(running.perMille, (66 / 110 * 990).round());
    expect(state().videoMaking?.id, ids.single);
    expect(state().pending, 1);
    // Kept for the next start with how far it is
    final kept = await store.read();
    expect(kept.single.fileName, 'clip_3D_LRF_Full_SBS.mp4');
    expect(kept.single.sourcePath, p.join(videos, 'clip.mp4'));

    (engine as FakeVideoJobEngine).release();
    await until((state) => state.jobs.single.state == ConversionState.done);
  });

  test('Pause keeps its work; Resume goes on from it, with the same settings', () async {
    final fake = engine as FakeVideoJobEngine..holdAfter = 2;
    final notifier = queue();
    final ids = addVideos(notifier, [video('clip.mp4')], quality: VideoDepthQuality.fine);
    await until((state) => state.jobs.single.videoProgress?.windows == 2);

    notifier.pause(ids.single);
    await until((state) => state.jobs.single.state == ConversionState.paused);
    expect(fake.stops, ['pause']);
    expect(fake.discarded, isEmpty);
    final paused = job(ids.single);
    expect(paused.videoProgress?.framesDone, 44);
    expect(paused.perMille, greaterThan(0));
    expect(state().pending, 0, reason: 'nothing for the close guard to stop');
    expect(state().hasEnded, isFalse, reason: 'Clear finished keeps it');
    notifier.clearFinished();
    expect(state().jobs, hasLength(1));
    final kept = await store.read();
    expect(kept.single.id, 'job0');
    expect(kept.single.settings.quality, VideoDepthQuality.fine);

    fake.holdAfter = null;
    notifier.retry(ids.single);
    await until((state) => state.jobs.single.state == ConversionState.done);
    expect(fake.runs, hasLength(2));
    expect(fake.runs.last.settings.workFolder, fake.runs.first.settings.workFolder);
    expect(fake.runs.last.settings.quality, VideoDepthQuality.fine);
    expect(await store.read(), isEmpty);
  });

  test('Stop deletes the work of the video under way; Discard that of one paused; a video waiting is paused', () async {
    final fake = engine as FakeVideoJobEngine..holdAfter = 1;
    final notifier = queue();
    final ids = addVideos(notifier, [video('a.mp4'), video('b.mp4')]);
    await until((state) => state.byId(ids[0])?.videoProgress?.windows == 1);

    // b.mp4 waits behind a.mp4 on the processor lane: paused, it never starts
    notifier.pause(ids[1]);
    expect(job(ids[1]).state, ConversionState.paused);

    notifier.cancel(ids[0]);
    await until((state) => state.byId(ids[0])!.state == ConversionState.cancelled);
    expect(fake.stops, ['cancel']);
    expect(fake.discarded.map((settings) => settings.recordId), ['job0']);
    expect(fake.runs, hasLength(1), reason: 'b.mp4 paused before it ran');

    notifier.cancel(ids[1]);
    await until((state) => state.byId(ids[1])!.state == ConversionState.cancelled);
    await until((_) => fake.discarded.length == 2);
    expect(fake.discarded.last.recordId, 'job1');
    expect(await store.read(), isEmpty);
  });

  test('a video the engine refuses is skipped with its reason, its work deleted', () async {
    final fake = engine as FakeVideoJobEngine;
    const reasons = {
      VideoRefusal.sphere360: ConversionSkipReason.sphere360,
      VideoRefusal.vr180: ConversionSkipReason.vr180,
      VideoRefusal.alreadyStereo: ConversionSkipReason.alreadyStereo,
      VideoRefusal.interlaced: ConversionSkipReason.interlaced,
      VideoRefusal.dolbyVisionProfile5: ConversionSkipReason.dolbyVisionProfile5,
      VideoRefusal.oddRotation: ConversionSkipReason.oddRotation,
      VideoRefusal.unreadable: ConversionSkipReason.unreadableVideo,
    };
    expect(reasons.keys, VideoRefusal.values);
    final notifier = queue();
    for (final MapEntry(key: refusal, value: reason) in reasons.entries) {
      fake.refusal = refusal;
      final id = addVideos(notifier, [video('${refusal.name}.mp4')]).single;
      await until((state) => state.byId(id)!.state.isEnded);
      expect(job(id).state, ConversionState.skipped, reason: refusal.name);
      expect(job(id).skipReason, reason, reason: refusal.name);
      expect(videoSkipReason(refusal), reason);
    }
    expect(await store.read(), isEmpty);
  });

  test('a failure says the words of the engine and names its log; Retry goes on from the work folder', () async {
    final fake = engine as FakeVideoJobEngine..failure = 'The encoder stopped with 1: Invalid argument';
    final notifier = queue();
    final id = addVideos(notifier, [video('clip.mp4')]).single;
    await until((state) => state.byId(id)!.state.isEnded);

    final failed = job(id);
    expect(failed.state, ConversionState.failed);
    expect(failed.error, ImmersiveErrorCode.modelFailed);
    expect(failed.message, 'The encoder stopped with 1: Invalid argument');
    expect(failed.keptFolder, p.join(root.path, 'logs', 'video3d-job0.log'));
    expect(state().isPaused, isFalse);
    expect((await store.read()).single.id, 'job0', reason: 'kept: Retry resumes it');

    fake.failure = null;
    notifier.retry(id);
    await until((state) => state.byId(id)!.state == ConversionState.done);
  });

  test('a full disk fails the video and pauses the queue; Resume of the queue goes on with it', () async {
    final fake = engine as FakeVideoJobEngine..failure = 'The encoder stopped with 1: No space left on device';
    final notifier = queue();
    final id = addVideos(notifier, [video('clip.mp4')]).single;
    await until((state) => state.byId(id)!.state.isEnded);

    expect(job(id).error, ImmersiveErrorCode.diskFull);
    expect(state().isPaused, isTrue);
    expect(videoFailureCode('There is not enough space on the disk.'), ImmersiveErrorCode.diskFull);
    expect(videoFailureCode('Conversion failed!'), ImmersiveErrorCode.modelFailed);

    fake.failure = null;
    notifier.resume();
    await until((state) => state.byId(id)!.state == ConversionState.done);
  });

  test('a video with no file on this computer is skipped with that reason', () async {
    final notifier = queue();
    final id = notifier.addVideos([
      ConversionRequest(
        source: _ServerVideo(),
        target: ConversionTarget(folder: videos, fileName: 'server_3D_LRF_Full_SBS.mp4'),
      ),
    ], settingsOf: (_) => VideoJobSettings(recordId: 's', workFolder: videoWorkFolderIn(videos, 's'))).single;
    await until((state) => state.byId(id)!.state.isEnded);
    expect(job(id).skipReason, ConversionSkipReason.videoNotLocal);
    expect((engine as FakeVideoJobEngine).runs, isEmpty);
  });

  test(
    'the videos a quit stopped come back paused at the next start; a record whose work is gone is forgotten',
    () async {
      final work = videoWorkFolderIn(videos, 'kept');
      Directory(work).createSync();
      File(p.join(videos, 'kept.mp4')).writeAsBytesSync([1, 2, 3]);
      await store.put(
        VideoJobRecord(
          sourcePath: p.join(videos, 'kept.mp4'),
          folder: videos,
          fileName: 'kept_3D_LRF_Half_SBS.mp4',
          settings: VideoJobSettings(
            recordId: 'kept',
            workFolder: work,
            quality: VideoDepthQuality.fast,
            strength: ReliefStrength.strong,
            packing: VideoSbsPacking.half,
          ),
          perMille: 420,
        ),
      );
      await store.put(
        VideoJobRecord(
          sourcePath: p.join(videos, 'gone.mp4'),
          folder: videos,
          fileName: 'gone_3D_LRF_Full_SBS.mp4',
          settings: VideoJobSettings(recordId: 'gone', workFolder: videoWorkFolderIn(videos, 'gone')),
        ),
      );
      final notifier = queue();
      final restored = await notifier.restoreVideoJobs();

      expect(restored, hasLength(1));
      final back = restored.single;
      expect(back.state, ConversionState.paused);
      expect(back.perMille, 420);
      expect(back.source.name, 'kept.mp4');
      expect(back.target?.fileName, 'kept_3D_LRF_Half_SBS.mp4');
      expect(back.video?.strength, ReliefStrength.strong);
      expect(back.video?.packing, VideoSbsPacking.half);
      expect((await store.read()).map((record) => record.id), ['kept']);
      // Twice: never twice in the queue
      expect(await notifier.restoreVideoJobs(), isEmpty);

      notifier.retry(back.id);
      await until((state) => state.byId(back.id)!.state == ConversionState.done);
      expect(job(back.id).writtenPath, p.join(videos, 'kept_3D_LRF_Half_SBS.mp4'));
    },
  );

  test('a 3D photo asked while a video runs goes first, between two of its windows', () async {
    final fake = engine as FakeVideoJobEngine..holdAfter = 1;
    final photoEngine = _Photos();
    photos = photoEngine;
    final notifier = queue();
    final videoId = addVideos(notifier, [video('clip.mp4')]).single;
    await until((state) => state.byId(videoId)?.videoProgress?.windows == 1);

    final photoPath = p.join(videos, 'salon.jpg');
    File(photoPath).writeAsBytesSync(List.generate(100, (i) => i));
    final photoId = notifier.add([
      ConversionRequest(source: LocalFileSource(photoPath), target: ConversionTarget.nextTo(photoPath)),
    ]).single;
    expect(job(photoId).state, ConversionState.waiting, reason: 'the lane is the video one');
    fake.release();
    await until((state) => state.byId(photoId)!.state == ConversionState.depth);
    expect(job(videoId).yielding, isTrue);
    expect(job(videoId).state, ConversionState.depth);
    photoEngine.release();
    await until((state) => state.byId(videoId)!.state == ConversionState.done);
    expect(job(photoId).state, ConversionState.done);
    expect(job(videoId).yielding, isFalse);
  });

  group('the real engine on a synthetic clip', () {
    late FakeFfmpegRunner runner;

    DesktopVideoJobEngine real({List<double>? times}) => DesktopVideoJobEngine(
      setup: () async => VideoJobSetup(
        ffmpeg: 'ffmpeg',
        ffprobe: 'ffprobe',
        runner: runner = FakeFfmpegRunner(
          probe: fakeVideoProbe(100, 4),
          times: times ?? [for (var i = 0; i < 100; i++) i / 25],
        ),
        worker: (sizes, relief) async => LocalVideoFrameWorker(
          ops: const DartVideoFrameOps(),
          model: tinyVdaInDart,
          eyeWidth: sizes.eyeWidth,
          eyeHeight: sizes.eyeHeight,
          modelWidth: sizes.modelWidth,
          modelHeight: sizes.modelHeight,
          relief: relief,
        ),
      ),
      sleep: _NoSleep(),
      logs: () async => Directory(p.join(root.path, 'logs')),
      segmentSeconds: 1,
    );

    test('made through the queue, paused after its first segment and resumed: the bytes of a whole job', () async {
      engine = real();
      final notifier = queue();
      final wholeFolder = Directory(p.join(root.path, 'w'))..createSync();
      final whole = addVideos(notifier, [video('whole.mp4', folder: wholeFolder.path)]);
      await until((state) => state.byId(whole.single)!.state.isEnded, within: const Duration(seconds: 60));
      expect(job(whole.single).state, ConversionState.done, reason: '${job(whole.single).message}');
      final wholeBytes = File(job(whole.single).writtenPath!).readAsStringSync();
      expect(job(whole.single).videoDone?.frames, 100);
      expect(job(whole.single).videoDone?.segments, 3);

      final request = video('clip.mp4');
      final id = addVideos(notifier, [request]).single;
      // Paused once its first segment is closed
      final paused = Completer<void>();
      final subscription = container.listen(conversionQueueProvider, (_, next) {
        final progress = next.byId(id)?.videoProgress;
        if (!paused.isCompleted && progress != null && progress.segmentsDone >= 1) {
          paused.complete();
          notifier.pause(id);
        }
      });
      await until((state) => state.byId(id)!.state.isEnded, within: const Duration(seconds: 60));
      subscription.close();
      expect(job(id).state, ConversionState.paused, reason: '${job(id).message}');
      final work = Directory(videoWorkFolderIn(videos, 'job1'));
      expect((await VideoJobFile.read(work))!.segments, isNotEmpty);
      expect(File(p.join(root.path, 'logs', 'video3d-job1.log')).existsSync(), isTrue);

      notifier.retry(id);
      await until((state) => state.byId(id)!.state.isEnded, within: const Duration(seconds: 60));
      expect(job(id).state, ConversionState.done, reason: '${job(id).message}');
      final decoder = runner.calls.firstWhere((call) => call.contains('-stats_enc_pre'));
      expect(decoder, contains('-ss'), reason: 'resumed, not started again');
      final made = File(job(id).writtenPath!);
      expect(made.path, p.join(videos, 'clip_3D_LRF_Full_SBS.mp4'));
      expect(made.readAsStringSync(), wholeBytes);
      expect(work.existsSync(), isFalse, reason: 'the work folder goes once the MP4 is in place');
      expect(File(videoMadePathOf(work.path)).existsSync(), isFalse);
      expect(File(p.join(root.path, 'logs', 'video3d-job1.log')).existsSync(), isFalse);
      expect(await store.read(), isEmpty);
    });

    test('a name taken meanwhile is never replaced: the MP4 takes "name (1)"', () async {
      engine = real();
      final notifier = queue();
      final request = video('clip.mp4');
      final taken = File(p.join(videos, 'clip_3D_LRF_Full_SBS.mp4'))..writeAsStringSync('mine');
      final id = addVideos(notifier, [request]).single;
      await until((state) => state.byId(id)!.state.isEnded, within: const Duration(seconds: 60));
      expect(job(id).state, ConversionState.done, reason: '${job(id).message}');
      expect(job(id).writtenPath, p.join(videos, 'clip_3D_LRF_Full_SBS (1).mp4'));
      expect(taken.readAsStringSync(), 'mine');
    });

    test('Stop during the frames deletes the work folder and the log', () async {
      engine = real();
      final notifier = queue();
      final id = addVideos(notifier, [video('clip.mp4')]).single;
      final stopped = Completer<void>();
      final subscription = container.listen(conversionQueueProvider, (_, next) {
        if (!stopped.isCompleted && (next.byId(id)?.videoProgress?.windows ?? 0) >= 1) {
          stopped.complete();
          notifier.cancel(id);
        }
      });
      await until((state) => state.byId(id)!.state.isEnded, within: const Duration(seconds: 60));
      subscription.close();
      expect(job(id).state, ConversionState.cancelled);
      expect(Directory(videoWorkFolderIn(videos, 'job0')).existsSync(), isFalse);
      expect(File(p.join(root.path, 'logs', 'video3d-job0.log')).existsSync(), isFalse);
      expect(File(p.join(videos, 'clip_3D_LRF_Full_SBS.mp4')).existsSync(), isFalse);
    });
  });
}

class _Memory implements MemoryProbe {
  const _Memory();

  @override
  MemoryFacts read() => const MemoryFacts(physical: 64 << 30, available: 48 << 30);
}

class _NoSleep implements VideoSleepGuard {
  @override
  Future<void> hold() async {}

  @override
  Future<void> release() async {}
}
