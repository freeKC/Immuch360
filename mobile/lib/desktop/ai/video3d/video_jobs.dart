// The 3D videos as the queue of the conversions runs them (store/m2/release-49/lots/video3d-plan.md, sections 4.3 and
// 4.5): the settings of a job chosen in the dialog, the job as video_jobs.json of the support folder keeps it so that
// the next start offers to resume it, the control the panel pauses or stops it with, and the engine the queue calls,
// which runs VideoConversion with the programs of the FFmpeg archive, the worker isolate of Video Depth Anything Small
// and the computer kept awake, then puts the MP4 under its final name.
//
// The engine writes `.immuch360-work-<id>.mp4` beside its work folder (a hidden name no scanner imports), then this file
// takes the first free `<name>_3D_LRF_Full_SBS.mp4` (or "name (1)") of the destination folder at that moment: a file
// that took the name during the hours of the job is never replaced. A job whose work folder is gone but whose hidden
// MP4 is there (the app quit between the two) only gets its name.
//
// The lines of each job go to `video3d-<id>.log` in the logs folder of the app, which "Save logs to a file" gathers:
// the log to send with a report. The log of a job that ends well, is stopped or discarded is deleted.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_app_runtime.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_engine.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_estimates.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_job_file.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_original_copy.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('Video3dJobs');

/// What the dialog chose for a 3D video, kept with its job (and in video_jobs.json for a resume)
class VideoJobSettings {
  const VideoJobSettings({
    required this.recordId,
    required this.workFolder,
    this.quality = VideoDepthQuality.standard,
    this.strength = ReliefStrength.subtle,
    this.packing = VideoSbsPacking.full,
    this.sphereEyeWidth,
  });

  /// Its id in video_jobs.json, also the end of the name of its work folder and of its log
  final String recordId;

  /// `<destination>/.immuch360-work-<recordId>`: on the drive of the output, so that the final mux copies nothing
  final String workFolder;
  final VideoDepthQuality quality;
  final ReliefStrength strength;
  final VideoSbsPacking packing;

  /// A 360° video made 360° 3D, top and bottom: the width of each eye (sphereEyeWidths); null for a flat video
  final int? sphereEyeWidth;

  bool get half => packing == VideoSbsPacking.half;

  bool get sphere => sphereEyeWidth != null;

  Map<String, Object?> toJson() => {
    'recordId': recordId,
    'workFolder': workFolder,
    'quality': quality.name,
    'strength': strength.name,
    'packing': packing.name,
    'sphereEyeWidth': ?sphereEyeWidth,
  };

  static VideoJobSettings? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['recordId'];
    final folder = json['workFolder'];
    if (id is! String || folder is! String) {
      return null;
    }
    return VideoJobSettings(
      recordId: id,
      workFolder: folder,
      quality: VideoDepthQuality.values.asNameMap()[json['quality']] ?? VideoDepthQuality.standard,
      strength: ReliefStrength.named(json['strength']),
      packing: VideoSbsPacking.values.asNameMap()[json['packing']] ?? VideoSbsPacking.full,
      sphereEyeWidth: switch (json['sphereEyeWidth']) {
        final int width when width >= 4 && width % 4 == 0 => width,
        _ => null,
      },
    );
  }
}

/// The work folder of the job [recordId] whose MP4 goes to [folder]
String videoWorkFolderIn(String folder, String recordId) => p.join(folder, '$videoWorkPrefix$recordId');

/// A new id for a job: the time and a count, so that two jobs of one dialog never share a folder
String newVideoRecordId(DateTime now, int index) => '${now.toUtc().microsecondsSinceEpoch.toRadixString(36)}-$index';

/// The MP4 the engine writes beside the work folder, before it takes its final name
String videoMadePathOf(String workFolder) => '$workFolder.mp4';

/// A 3D video not finished, as video_jobs.json keeps it: enough to show it at the next start and to resume it
class VideoJobRecord {
  const VideoJobRecord({
    required this.sourcePath,
    required this.folder,
    required this.fileName,
    required this.settings,
    this.perMille = 0,
    this.original,
  });

  /// The file the engine reads: the original on this computer, or the copy of one downloaded first ([original])
  final String sourcePath;

  /// The original that is not on this computer, as its source describes it (DownloadableOriginal.descriptor): the
  /// next start makes the source again to go on with its download; null for a file of this computer
  final Map<String, Object?>? original;

  /// The destination folder and the name the MP4 is to take there
  final String folder;
  final String fileName;
  final VideoJobSettings settings;

  /// How far it was when last kept, in thousandths
  final int perMille;

  String get id => settings.recordId;

  VideoJobRecord withPerMille(int value) => VideoJobRecord(
    sourcePath: sourcePath,
    folder: folder,
    fileName: fileName,
    settings: settings,
    perMille: value,
    original: original,
  );

  Map<String, Object?> toJson() => {
    'sourcePath': sourcePath,
    'folder': folder,
    'fileName': fileName,
    'perMille': perMille,
    'settings': settings.toJson(),
    'original': ?original,
  };

  static VideoJobRecord? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final source = json['sourcePath'];
    final folder = json['folder'];
    final name = json['fileName'];
    final settings = VideoJobSettings.fromJson(json['settings']);
    if (source is! String || folder is! String || name is! String || settings == null) {
      return null;
    }
    final perMille = json['perMille'];
    final original = json['original'];
    return VideoJobRecord(
      sourcePath: source,
      folder: folder,
      fileName: name,
      settings: settings,
      perMille: perMille is int ? perMille.clamp(0, 1000) : 0,
      original: original is Map ? original.cast<String, Object?>() : null,
    );
  }
}

/// video_jobs.json in the support folder: the 3D videos not finished, written as a whole new file renamed over the old
/// one, one change after the other
class VideoJobsStore {
  VideoJobsStore({Future<Directory> Function()? settingsDirectory})
    : _settingsDirectory = settingsDirectory ?? getApplicationSupportDirectory;

  static final instance = VideoJobsStore();
  static const fileName = 'video_jobs.json';

  final Future<Directory> Function() _settingsDirectory;
  Future<void> _turn = Future.value();

  Future<List<VideoJobRecord>> read() async {
    late List<VideoJobRecord> records;
    await _inTurn(() async => records = await _read());
    return records;
  }

  /// Adds [record], or puts it in place of the one with its id
  Future<void> put(VideoJobRecord record) => _inTurn(() async {
    final records = await _read();
    final at = records.indexWhere((other) => other.id == record.id);
    if (at < 0) {
      records.add(record);
    } else {
      records[at] = record;
    }
    await _write(records);
  });

  Future<void> remove(String id) => _inTurn(() async {
    final records = await _read();
    final before = records.length;
    records.removeWhere((record) => record.id == id);
    if (records.length != before) {
      await _write(records);
    }
  });

  Future<File> _file() async => File(p.join((await _settingsDirectory()).path, fileName));

  Future<List<VideoJobRecord>> _read() async {
    try {
      final decoded = jsonDecode(await (await _file()).readAsString());
      final list = decoded is Map ? decoded['jobs'] : null;
      return [
        if (list is List)
          for (final entry in list) ?VideoJobRecord.fromJson(entry),
      ];
    } on FileSystemException {
      return [];
    } on FormatException catch (error) {
      _log.warning('$fileName cannot be read: $error');
      return [];
    }
  }

  Future<void> _write(List<VideoJobRecord> records) async {
    final file = await _file();
    if (records.isEmpty) {
      if (file.existsSync()) {
        await file.delete();
      }
      return;
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'jobs': [for (final record in records) record.toJson()],
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<void> _inTurn(Future<void> Function() step) {
    final next = _turn.then((_) => step());
    _turn = next.catchError((Object _) {});
    return next;
  }
}

/// How the queue stops a 3D video under way: Pause keeps its work folder, Cancel deletes it. The engine tells it how to
/// stop the model's run in progress ([onStop]); the queue lets the 3D photos asked meanwhile run between two windows
/// ([betweenWindows]).
class VideoJobControl {
  var _stop = 0;
  void Function()? _onStop;

  /// Awaited by the engine after each window
  Future<void> Function()? betweenWindows;

  bool get isStopping => _stop > 0;
  bool get isCancelled => _stop == 2;

  set onStop(void Function()? stop) {
    _onStop = stop;
    if (_stop > 0) {
      stop?.call();
    }
  }

  void pause() {
    if (_stop == 0) {
      _stop = 1;
      _onStop?.call();
    }
  }

  void cancel() {
    _stop = 2;
    _onStop?.call();
  }
}

/// A 3D video to make, as the queue gives it to the engine
class VideoJobSpec {
  const VideoJobSpec({
    required this.sourcePath,
    required this.folder,
    required this.fileName,
    required this.settings,
    this.appVersion = '',
  });

  final String sourcePath;
  final String folder;
  final String fileName;
  final VideoJobSettings settings;
  final String appVersion;
}

/// What a 3D video job made: the MP4 under its final name, and what the engine tells of it
class VideoJobDone {
  const VideoJobDone({required this.path, this.result, this.millisPerFrame});

  final String path;
  final VideoJobResult? result;

  /// The pace of this job, for the first guess of the next one at its quality (videoFrameMillis); null when it ran
  /// fewer than three windows
  final int? millisPerFrame;
}

/// What a 3D video lacks to go on: its original, or the destination folder its work and its MP4 are in (a drive or a
/// share of the NAS not connected, a file moved or renamed). Its work stays for a Resume once it is back.
enum VideoMissing { original, folder }

/// A 3D video that cannot go on now, its work kept: [path] is what is not there
class VideoJobUnreachable implements Exception {
  const VideoJobUnreachable(this.missing, this.path);

  final VideoMissing missing;
  final String path;

  @override
  String toString() => 'VideoJobUnreachable: ${missing.name} $path';
}

/// What a 3D video of [sourcePath] made in [folder] lacks now, null when both are there: the folder first, then the
/// original
({VideoMissing missing, String path})? videoMissingOf(String sourcePath, String folder) {
  if (!Directory(folder).existsSync()) {
    return (missing: VideoMissing.folder, path: folder);
  }
  if (!File(sourcePath).existsSync()) {
    return (missing: VideoMissing.original, path: sourcePath);
  }
  return null;
}

/// The engine of the 3D videos as the queue sees it; the tests give fakes
abstract interface class VideoJobEngine {
  /// Makes [spec], or goes on from its work folder. Throws [VideoJobStopped] after a pause or a cancel of [control]
  /// (the work folder deleted for a cancel), [VideoJobUnreachable] with its work kept when its original or its folder is
  /// not there, [VideoJobException] with its refusal for a video that cannot be made 3D, and the errors of the programs
  /// and the files otherwise.
  Future<VideoJobDone> run(
    VideoJobSpec spec,
    VideoJobControl control, {
    void Function(VideoJobProgress progress)? onProgress,
  });

  /// Deletes the work folder, the MP4 not renamed yet and the log of a job the user discarded
  Future<void> discard(VideoJobSettings settings);

  /// The log of the job of [settings], the one to send with a report; null when the engine keeps none
  Future<String?> logPathOf(VideoJobSettings settings);
}

/// The reason of the queue for a refusal of the engine
ConversionSkipReason videoSkipReason(VideoRefusal refusal) => switch (refusal) {
  VideoRefusal.sphere360 => ConversionSkipReason.sphere360,
  VideoRefusal.vr180 => ConversionSkipReason.vr180,
  VideoRefusal.alreadyStereo => ConversionSkipReason.alreadyStereo,
  VideoRefusal.interlaced => ConversionSkipReason.interlaced,
  VideoRefusal.dolbyVisionProfile5 => ConversionSkipReason.dolbyVisionProfile5,
  VideoRefusal.oddRotation => ConversionSkipReason.oddRotation,
  VideoRefusal.unreadable => ConversionSkipReason.unreadableVideo,
  VideoRefusal.raw360 => ConversionSkipReason.raw360Video,
  VideoRefusal.sphereLayout => ConversionSkipReason.sphereLayout,
};

/// What a job runs with on this computer, found when it starts: the programs of the FFmpeg archive and their runner,
/// and the worker of a job for its sizes
class VideoJobSetup {
  const VideoJobSetup({
    required this.ffmpeg,
    required this.ffprobe,
    required this.runner,
    required this.worker,
    this.modelSha256,
    this.encoderMemory,
  });

  final String ffmpeg;
  final String ffprobe;
  final VideoProgramRunner runner;

  /// The worker of a job of [relief] for its sizes
  final Future<VideoFrameWorker> Function(
    ({int eyeWidth, int eyeHeight, int modelWidth, int modelHeight}) sizes,
    VideoReliefSettings relief,
  )
  worker;
  final String? modelSha256;

  /// The encoders that stopped during a job on this computer (video_encoders.json), none in the tests
  final VideoEncoderMemory? encoderMemory;
}

/// Keeps the computer awake while a job runs; SystemSleepGuard in the app, nothing in the tests
abstract interface class VideoSleepGuard {
  Future<void> hold();
  Future<void> release();
}

class SystemVideoSleepGuard implements VideoSleepGuard {
  SystemVideoSleepGuard([SystemSleepGuard? guard]) : _guard = guard ?? SystemSleepGuard();

  final SystemSleepGuard _guard;

  @override
  Future<void> hold() => _guard.hold();

  @override
  Future<void> release() => _guard.release();
}

/// The engine of the 3D videos of the app: the setup found when a job starts ([setup]: the components the gate finds
/// then), the computer kept awake while it runs, its lines in its log
class DesktopVideoJobEngine implements VideoJobEngine {
  DesktopVideoJobEngine({required this.setup, VideoSleepGuard? sleep, this.logs, this.segmentSeconds = 30})
    : _sleep = sleep ?? SystemVideoSleepGuard();

  final Future<VideoJobSetup> Function() setup;
  final VideoSleepGuard _sleep;

  /// The logs folder of the app, which "Save logs to a file" gathers; null: no log file
  final Future<Directory> Function()? logs;
  final int segmentSeconds;

  /// The log of the job [recordId]
  Future<File?> logOf(String recordId) async {
    final folder = logs;
    if (folder == null) {
      return null;
    }
    try {
      return File(p.join((await folder()).path, 'video3d-$recordId.log'));
    } catch (error) {
      _log.warning('The logs folder is not known: $error');
      return null;
    }
  }

  @override
  Future<VideoJobDone> run(
    VideoJobSpec spec,
    VideoJobControl control, {
    void Function(VideoJobProgress progress)? onProgress,
  }) async {
    final settings = spec.settings;
    final work = Directory(settings.workFolder);
    final made = File(videoMadePathOf(settings.workFolder));
    final logFile = await logOf(settings.recordId);
    IOSink? sink;
    try {
      await logFile?.parent.create(recursive: true);
      sink = logFile?.openWrite(mode: FileMode.append);
    } on FileSystemException catch (error) {
      _log.warning('The log of the 3D video cannot be written: ${error.message}');
    }
    void log(String line) {
      _log.info('${settings.recordId}: $line');
      sink?.writeln('${DateTime.now().toIso8601String()} $line');
    }

    var ended = false;
    try {
      log(
        'source ${spec.sourcePath}, ${settings.quality.name}, ${settings.strength.name}, '
        '${settings.sphere ? '360° top and bottom, eyes of ${settings.sphereEyeWidth}' : settings.packing.name}',
      );
      // The app quit between the end of the mux and the final name
      if (!work.existsSync() && made.existsSync()) {
        log('the MP4 was made: it only takes its name');
        final path = await _place(made, spec);
        ended = true;
        return VideoJobDone(path: path);
      }
      // A file moved or a drive not connected is no reason to delete hours of segments: the job waits for it
      if (videoMissingOf(spec.sourcePath, spec.folder) case final lack?) {
        throw VideoJobUnreachable(lack.missing, lack.path);
      }
      final found = await setup();
      if (control.isStopping) {
        throw VideoJobStopped(control.isCancelled);
      }
      await _sleep.hold();
      VideoFrameWorker? worker;
      final relief = VideoReliefSettings(
        parallax: settings.strength.parallax,
        packing: settings.packing,
        sphere: settings.sphere,
      );
      VideoJobProgress? last;
      final conversion = VideoConversion(
        request: VideoJobRequest(
          sourcePath: spec.sourcePath,
          outputPath: made.path,
          workFolder: work,
          ffmpeg: found.ffmpeg,
          ffprobe: found.ffprobe,
          quality: settings.quality,
          relief: relief,
          segmentSeconds: segmentSeconds,
          sphereEyeWidth: settings.sphereEyeWidth,
          keys: {
            if (settings.sphere) ...{
              'com.immuch360.kind': 'StereoVideo360',
              'com.immuch360.pipeline': 'relief-360-video',
              'com.immuch360.projection': 'equirectangular',
              'com.immuch360.stereo': 'top-bottom',
              'com.immuch360.max_shift_degrees': '${relief.sphereShiftDegrees}',
            } else ...{
              'com.immuch360.kind': 'StereoVideo',
              'com.immuch360.pipeline': 'relief-v1-video',
              'com.immuch360.convergence': '${relief.convergence}',
            },
            'com.immuch360.parallax': '${relief.parallax}',
            'com.immuch360.model': 'video-depth-anything-small-onnx',
            'com.immuch360.model.sha256': ?found.modelSha256,
            'com.immuch360.depth.short_side': '${settings.quality.shortSide}',
            'com.immuch360.original.name': p.basename(spec.sourcePath),
            if (spec.appVersion.isNotEmpty) 'com.immuch360.app.version': spec.appVersion,
          },
        ),
        runner: found.runner,
        workerFactory: ({required eyeWidth, required eyeHeight, required modelWidth, required modelHeight}) async {
          final made = await found.worker((
            eyeWidth: eyeWidth,
            eyeHeight: eyeHeight,
            modelWidth: modelWidth,
            modelHeight: modelHeight,
          ), relief);
          worker = made;
          return made;
        },
        onProgress: (progress) {
          last = progress;
          onProgress?.call(progress);
        },
        onLog: log,
        betweenWindows: control.betweenWindows,
        encoderMemory: found.encoderMemory,
      );
      control.onStop = () {
        if (control.isCancelled) {
          conversion.cancel();
        } else {
          conversion.pause();
        }
        // The run of the model in progress stops within a second, not at the end of its window
        if (worker case final IsolateVideoFrameWorker running) {
          running.stop();
        }
      };
      final result = await conversion.run();
      final path = await _place(made, spec);
      log('saved as $path');
      ended = true;
      final fps = last?.framesPerSecond;
      return VideoJobDone(
        path: path,
        result: result,
        millisPerFrame: fps == null || fps <= 0 ? null : (1000 / fps).round(),
      );
    } on VideoJobStopped {
      log(control.isCancelled ? 'stopped: the work is deleted' : 'paused: the work folder is kept');
      if (control.isCancelled) {
        ended = true;
        await _deleteWork(settings);
        throw const VideoJobStopped(true);
      }
      throw const VideoJobStopped(false);
    } on VideoJobUnreachable catch (error) {
      log('paused: the ${error.missing.name} is not found at ${error.path}, the work folder is kept');
      rethrow;
    } on VideoJobException catch (error) {
      // ffprobe could not read the original because it went meanwhile (a share that dropped): its work is kept
      if (error.refusal == VideoRefusal.unreadable) {
        if (videoMissingOf(spec.sourcePath, spec.folder) case final lack?) {
          log('paused: the ${lack.missing.name} is not found at ${lack.path}, the work folder is kept');
          throw VideoJobUnreachable(lack.missing, lack.path);
        }
      }
      log('failed: ${error.message}');
      if (error.refusal != null) {
        // Nothing of a refused video is worth keeping
        ended = true;
        await _deleteWork(settings);
      }
      rethrow;
    } catch (error) {
      log('failed: $error');
      rethrow;
    } finally {
      await _sleep.release();
      await sink?.flush();
      await sink?.close();
      if (ended && logFile != null) {
        await _deleteQuietly(logFile);
      }
    }
  }

  /// The MP4 [made] under the first free name of [spec] in its folder
  static Future<String> _place(File made, VideoJobSpec spec) async {
    final reserved = await reserveFileIn(Directory(spec.folder), spec.fileName);
    try {
      await made.rename(reserved.path);
    } on FileSystemException {
      await _deleteQuietly(reserved);
      rethrow;
    }
    return reserved.path;
  }

  @override
  Future<String?> logPathOf(VideoJobSettings settings) async => (await logOf(settings.recordId))?.path;

  @override
  Future<void> discard(VideoJobSettings settings) async {
    await _deleteWork(settings);
    final logFile = await logOf(settings.recordId);
    if (logFile != null) {
      await _deleteQuietly(logFile);
    }
  }

  static Future<void> _deleteWork(VideoJobSettings settings) async {
    final work = Directory(settings.workFolder);
    // Only a folder of ours, never anything else a record would name
    if (p.basename(work.path).startsWith(videoWorkPrefix)) {
      try {
        if (work.existsSync()) {
          await work.delete(recursive: true);
        }
      } on FileSystemException catch (error) {
        _log.warning('The work folder of a 3D video stays: ${error.message}');
      }
      await _deleteQuietly(File(videoMadePathOf(work.path)));
      await _deleteQuietly(File('${videoMadePathOf(work.path)}.part'));
      // The copy of an original of the server or of a share, downloaded for this job
      await deleteVideoOriginalCopy(work.path);
    }
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (file.existsSync()) {
      await file.delete();
    }
  } on FileSystemException {
    // Gone already, or held: the next start tries again
  }
}

/// What the dialog reads of a video before Convert: the verdict of its ffprobe and of the app's own probe of its MP4
/// boxes, and the figures of its job
class VideoDialogFacts {
  const VideoDialogFacts({
    required this.check,
    this.durationSeconds,
    this.frames,
    this.source,
    this.spherical,
    this.fileName,
    this.marked360 = false,
  });

  /// The verdict read as the video says (VideoProjectionAsk.auto)
  final VideoSourceCheck check;
  final double? durationSeconds;
  final int? frames;

  /// What ffprobe and the app's probe read, and the name, so that the verdict can be read again for a 2:1 video the
  /// user says is a 360° one
  final VideoSource? source;
  final SphericalProbe? spherical;
  final String? fileName;
  final bool marked360;

  /// The verdict for a video the user says is 360° ([as360] true) or flat (false); [check] when [as360] is null or
  /// the video was not read
  VideoSourceCheck checkAs(bool? as360) {
    final name = fileName;
    if (as360 == null || name == null || !check.looksLike360) {
      return check;
    }
    return checkVideoSource(
      source,
      fileName: name,
      spherical: spherical,
      marked360: marked360,
      ask: as360 ? VideoProjectionAsk.sphere : VideoProjectionAsk.flat,
    );
  }
}

/// Reads [path] with ffprobe of [setup] and the app's probe of the st3d and sv3d boxes; [marked360] when the app takes
/// it for a 360° video already (aiVideo360Provider)
Future<VideoDialogFacts> readVideoDialogFacts(VideoJobSetup setup, String path, {bool marked360 = false}) async {
  SphericalProbe? spherical;
  try {
    spherical = await probeSphericalMetadata(videoFileRangeReader(path));
  } on Object catch (error) {
    _log.fine('The boxes of $path were not read: $error');
  }
  Map<String, Object?> json;
  try {
    json = await probeVideo(setup.runner, setup.ffprobe, path);
  } on VideoJobException {
    return VideoDialogFacts(check: checkVideoSource(null, fileName: p.basename(path)));
  }
  final source = VideoSource.fromFfprobe(json);
  final name = p.basename(path);
  final check = checkVideoSource(
    source,
    fileName: name,
    spherical: spherical,
    marked360: marked360,
    ask: VideoProjectionAsk.auto,
  );
  final grid = check.grid;
  return VideoDialogFacts(
    check: check,
    durationSeconds: source?.duration,
    frames: source == null || grid == null ? null : videoFramesOf(source, grid),
    source: source,
    spherical: spherical,
    fileName: name,
    marked360: marked360,
  );
}
