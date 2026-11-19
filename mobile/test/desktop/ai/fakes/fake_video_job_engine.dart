// An engine of the 3D videos for the tests of the queue and of the screens: it tells frames window after window (22
// new frames each, its pace from the third one), awaits the queue between two windows, can hold after a window until
// [release] or a stop, then fails, refuses, or writes `<name>_3D_LRF_Full_SBS.mp4` under the first free name.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_jobs.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';

class FakeVideoJobEngine implements VideoJobEngine {
  FakeVideoJobEngine({this.frames = 110, this.holdAfter, this.refusal, this.failure, this.logFolder});

  /// The frames of each video
  int frames;

  /// Held after this many windows, until [release] or a stop of the queue
  int? holdAfter;

  /// Refused by "ffprobe", with its reason
  VideoRefusal? refusal;

  /// Fails with these words after its frames
  String? failure;

  /// Where its log would be; null for none
  final String? logFolder;

  final runs = <VideoJobSpec>[];
  final discarded = <VideoJobSettings>[];
  final stops = <String>[];
  var _release = Completer<void>();

  /// Frames done per work folder: a resumed job goes on from there, as the real one does from its segments
  final _doneOf = <String, int>{};

  /// Lets a held job go on
  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<VideoJobDone> run(
    VideoJobSpec spec,
    VideoJobControl control, {
    void Function(VideoJobProgress progress)? onProgress,
  }) async {
    runs.add(spec);
    _release = Completer<void>();
    final stopped = Completer<void>();
    control.onStop = () {
      stops.add(control.isCancelled ? 'cancel' : 'pause');
      if (!stopped.isCompleted) {
        stopped.complete();
      }
    };
    final refused = refusal;
    if (refused != null) {
      throw VideoJobException('Refused: ${refused.name}', refusal: refused);
    }
    final work = spec.settings.workFolder;
    var done = _doneOf[work] ?? 0;
    var windows = 0;
    var segments = done ~/ 44;
    Never stop() {
      _doneOf[work] = done;
      if (control.isCancelled) {
        _doneOf.remove(work);
        discarded.add(spec.settings);
      }
      throw VideoJobStopped(control.isCancelled);
    }

    onProgress?.call(VideoJobProgress(framesDone: done, framesTotal: frames, segmentsDone: segments));
    while (done < frames) {
      // A microtask, not a timer: the widget tests run in a fake clock
      await Future<void>.microtask(() {});
      if (control.isStopping) {
        stop();
      }
      done = (done + 22).clamp(0, frames);
      windows++;
      if (windows % 2 == 0) {
        segments++;
      }
      final fps = windows >= 3 ? 1.25 : null;
      onProgress?.call(
        VideoJobProgress(
          framesDone: done,
          framesTotal: frames,
          framesPerSecond: fps,
          timeLeft: fps == null ? null : Duration(seconds: ((frames - done) / fps).round()),
          windows: windows,
          segmentsDone: segments,
        ),
      );
      await control.betweenWindows?.call();
      if (control.isStopping) {
        stop();
      }
      if (windows == holdAfter) {
        await Future.any([_release.future, stopped.future]);
        // The next hold waits for the next release
        _release = Completer<void>();
        if (control.isStopping) {
          stop();
        }
      }
    }
    final failed = failure;
    if (failed != null) {
      _doneOf[work] = done;
      throw VideoJobException(failed);
    }
    onProgress?.call(
      VideoJobProgress(
        framesDone: frames,
        framesTotal: frames,
        timeLeft: Duration.zero,
        segmentsDone: segments + 1,
        muxing: true,
      ),
    );
    _doneOf.remove(work);
    final file = await reserveFileIn(Directory(spec.folder), spec.fileName);
    await file.writeAsString('3D video of ${spec.sourcePath}');
    return VideoJobDone(
      path: file.path,
      millisPerFrame: 800,
      result: VideoJobResult(
        outputPath: file.path,
        frames: frames,
        slots: frames,
        encoder: VideoEncoder.svtAv1,
        windows: windows,
        cuts: const [50],
        holesMean: 0.01,
        segments: segments + 1,
      ),
    );
  }

  @override
  Future<void> discard(VideoJobSettings settings) async {
    discarded.add(settings);
    _doneOf.remove(settings.workFolder);
  }

  @override
  Future<String?> logPathOf(VideoJobSettings settings) async =>
      logFolder == null ? null : '$logFolder/video3d-${settings.recordId}.log';
}
