// The engine of the splat scenes (plan 2026-11-01, sections 2.1, 2.2 and 2.4, lot SP6): one SplatJob, photos or a
// video, made into `<name>_splat.spz` (SPZ version 2, at most 150 000 gaussians, spherical harmonics of degree 3, the
// scale of a place or of an object), and into the same gaussians as a .ply when asked, written to the .part files the
// queue gives. Its steps, each reported with its counts and the time left of the whole job (splat_time.dart):
//  1. reading: the key of the job, the SHA-1 of its settings (SplatSettings.key, the .ply apart) and of its members
//     (name, time taken, camera), which names its work folder, splat-<16 hexadecimal digits>, under the first root of
//     the work folders with an ASCII path (splat_work_folder.dart); the folders of the splat scenes unused for a day go
//     first, under every root;
//  2. photos, or frames: the images prepared by what the engine is given ([SplatImagesMaker]: in the app, the photos
//     of lot SP5 or the frames of the video by the app's libmpv), the members read one after the other; the sum of each
//     one read is kept in splat.json of the work folder; fewer than SplatV1.minImages usable images fail as
//     tooFewImages ("12/150");
//  3. features, matching, mapping: COLMAP on the processor (colmap_runner.dart, lot SP4), the poses of the cameras,
//     written to splat.json once found; from then on every progress tells the images placed (ImmersiveProgress.placed),
//     so that the panel says a scene of fewer than SplatV1.incompleteShare of them may be incomplete while it trains;
//  4. training: Brush on the graphics card (brush_runner.dart), which asks the card again before it starts, its steps
//     and the time left by the pace of its last 1 000 steps;
//  5. splatCopy: the export of Brush read, its scale set from the gaussians, the centres of the cameras and where they
//     look, an object set upright on the plane it stands on (lot SPF2), the SPZ and the .ply written in an isolate
//     (splat_files.dart, lot SP3), under a second for 150 000 gaussians; the result says how it was set upright.
// Cancel stops the program under way within a second (SidecarRun looks every 200 ms; the preparation of the photos
// between two photos, the frames between two candidates); the copy, under a second, ends before the job does.
//
// Retry from the poses: a job that failed or was cancelled once COLMAP had placed its photos keeps its work folder a
// day after its last use (managed_process.dart). A job of the same key finds it, reads each member again for its sum
// (a photo of this computer is hashed in place; an original of the server gives the checksum of its asset,
// SplatMemberSum, or is downloaded and released at once), and when
// every sum is the one kept, starts again at the training, from the model COLMAP aligned. Retry from the images (lot
// SPF1): a job that failed in COLMAP, once its images were prepared, keeps its work folder a day too, with its images,
// the database and the models of COLMAP, which a diagnosis reads (FreeKC's frames of 3 November, 68 of 139 placed,
// went with the failure); a job of the same key whose sums are the ones kept starts again at COLMAP, from those images.
// Otherwise the folder is emptied and the job starts from the photos. The folder goes once the queue saved the file the
// job made (ImmersiveResult.afterSaved: a destination that refuses it, or a Cancel during the copy, leaves it for
// Retry), and at once after a failure before the images were prepared, after a full disk, and after a cancel before
// the poses were found ([splatWorkKept]). A failure that leaves it names it (ImmersiveResult.keptFolder) for the
// panel.
//
// After a failure, a Cancel apart, the logs of the programs (logs/ of the work folder) are first copied into the logs
// folder of the app when the engine is given one ([SplatEngine.failureLogs]: keepSplatFailureLogs, the five newest
// kept, the failure, its step and what became of the work folder at their top), so that a failure whose work folder
// goes still says what COLMAP did: "Save logs to a file" takes them with the log.
//
// No Flutter here: the engine also runs in splat_probe, a program compiled by `dart compile exe` that makes a scene on
// a PC with the real programs (lot SP6, artifact of the windows job of the desktop workflow); the app gives it the
// preparation of lot SP5, which needs Flutter (splat_images.dart).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/desktop/ai/creator/write_failure.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_model.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_files.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_time.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SplatEngine');

/// What the preparation gave: [images] usable, of [total] photos or frames, [blurred] of them left out as blurred
class SplatPrepared {
  const SplatPrepared({required this.images, required this.total, this.blurred = 0});

  final int images;
  final int total;
  final int blurred;
}

/// Prepares the images of a job into [imagesFolder] (one folder per camera under it), reading [members] one after the
/// other: the photos, or the frames of the video when [video]. [onProgress] gets what is done of all. Throws a
/// BackendException: cancelled once [cancel] is set, diskFull, readOnly, sourceLost...
typedef SplatImagesMaker =
    Future<SplatPrepared> Function(
      List<SplatMember> members, {
      required bool video,
      required String imagesFolder,
      required NativeCancelFlag cancel,
      required void Function(int done, int total) onProgress,
    });

/// The name of the file of a work folder that keeps what a job found: its key, the sums of its members, its images and
/// its poses once COLMAP placed them
const splatStateFileName = 'splat.json';

/// The key of [job]: the SHA-1 in hexadecimal of its settings and of its members (see the top of this file)
String splatJobKey(SplatJob job) {
  final text = StringBuffer('${job.settings.key}|video=${job.isVideo}');
  for (final member in job.members) {
    text.write('\n${member.name}|${member.taken?.toUtc().toIso8601String() ?? ''}|${member.camera ?? ''}');
  }
  return sha1.convert(utf8.encode(text.toString())).toString();
}

/// Whether the work folder of a job is kept when the job ends (see the top of this file): until its file is saved once
/// [done]; a day once the poses were [placed] (Retry from them); a day after a [failure] once the images were
/// [prepared], except a Cancel and a full disk (Retry from the images, and a diagnosis); otherwise it goes at once
bool splatWorkKept({required bool done, required bool placed, required bool prepared, ImmersiveErrorCode? failure}) =>
    done ||
    placed ||
    (prepared && failure != null && failure != ImmersiveErrorCode.cancelled && failure != ImmersiveErrorCode.diskFull);

/// What the log of a failure says of a work folder kept
const _keptSaid =
    'The work folder is kept a day, for Retry and for a diagnosis (its images, the database and the models of COLMAP)';

/// What a job found, as splat.json keeps it: its images once prepared, and those COLMAP [placed] once it did
class _Found {
  const _Found({required this.images, required this.total, required this.blurred, this.placed});

  final int images;
  final int total;
  final int blurred;
  final int? placed;
}

/// A member whose sum is kept when the preparation reads it
class _SummedMember implements SplatMember {
  _SummedMember(this.member);

  final SplatMember member;
  String? sum;

  @override
  String get name => member.name;

  @override
  DateTime? get taken => member.taken;

  @override
  String? get camera => member.camera;

  @override
  Future<ImmersiveSource> load(NativeCancelFlag cancel) async {
    final source = await member.load(cancel);
    sum = source.sha1;
    return source;
  }

  @override
  Future<void> release() => member.release();
}

/// See the top of this file
class SplatEngine implements ImmersiveEngine {
  SplatEngine({
    required this.images,
    required this.colmap,
    required this.brush,
    List<SplatWorkRoot>? roots,
    Directory? Function(List<SplatWorkRoot> roots)? pickRoot,
    Duration Function()? elapsed,
    this.failureLogs,
  }) : roots = roots ?? splatWorkRoots(),
       _pickRoot = pickRoot ?? ((roots) => asciiWorkRoot(roots)),
       _elapsed = elapsed ?? _stopwatch();

  /// Prepares the photos or the frames
  final SplatImagesMaker images;
  final ColmapRunner colmap;
  final BrushRunner brush;

  /// The roots of the work folders, in order
  final List<SplatWorkRoot> roots;

  /// Where the logs of the programs of a job that failed are copied (the logs folder of the app); none when null
  final Directory? failureLogs;
  final Directory? Function(List<SplatWorkRoot> roots) _pickRoot;
  final Duration Function() _elapsed;

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  @override
  Future<ImmersiveResult> run(
    SplatJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    final times = <ImmersiveStage, Duration>{};
    final first = job.isVideo ? ImmersiveStage.frames : ImmersiveStage.photos;
    // The images the job will take, not its members: a video is one member and 150 frames
    final model = SplatTimeModel(
      reference: job.timings.isEmpty
          ? splatTimingsOf(job.isVideo ? splatSceneVideoDefaultTimings : splatSceneDefaultTimings)
          : job.timings,
      stages: job.stages,
      images: job.plannedImages ?? splatPlannedImages(job.members.length, video: job.isVideo),
      video: job.isVideo,
      steps: job.settings.steps,
    );
    var stage = ImmersiveStage.reading;
    var stageStarted = _elapsed();
    // The images COLMAP placed, once it did, told with every progress
    SplatPlaced? placedNow;
    void report(ImmersiveStage at, double fraction, {int? done, int? total, Duration? stageLeft}) {
      if (at != stage) {
        stage = at;
        stageStarted = _elapsed();
      }
      onProgress?.call(
        ImmersiveProgress(
          at,
          model.perMille(at, fraction),
          step: done,
          steps: total,
          remaining: model.left(at, inStage: _elapsed() - stageStarted, done: done, total: total, stageLeft: stageLeft),
          placed: placedNow,
        ),
      );
    }

    Duration timeOf(ImmersiveStage at) => _elapsed() - (stage == at ? stageStarted : _elapsed());

    void checkCancel() {
      if (cancel.isCancelled) {
        throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
      }
    }

    SplatWorkFolder? work;
    var done = false;
    // The failure the job ends with, for the logs it keeps
    (ImmersiveErrorCode, String)? failed;
    ImmersiveResult fail(ImmersiveErrorCode code, String message) {
      failed = (code, message);
      final folder = work;
      final kept = folder != null && code != ImmersiveErrorCode.cancelled && _kept(folder, done: false, failure: code)
          ? folder.root.path
          : null;
      return ImmersiveResult.failed(code, message: message, stageTimes: times, keptFolder: kept);
    }

    try {
      report(ImmersiveStage.reading, 0);
      final key = splatJobKey(job);
      await deleteOldSplatWork(roots);
      final root = _pickRoot(roots);
      if (root == null) {
        throw const BackendException(
          ImmersiveErrorCode.writeFailed,
          'No folder for the work files of the splat scene has a path COLMAP can read',
        );
      }
      work = SplatWorkFolder(Directory(p.join(root.path, splatWorkFolderName(key))));
      times[ImmersiveStage.reading] = timeOf(ImmersiveStage.reading);
      checkCancel();

      // What a job of the same photos found, when their sums have not changed: its poses, or its images
      var found = await _keptFound(
        job,
        work,
        key,
        cancel,
        (read, all) => report(first, read / all, done: read, total: all),
      );
      checkCancel();
      ColmapModel? aligned;
      if (found != null && found.placed != null) {
        try {
          aligned = ColmapModel.read(work.aligned);
        } on Object catch (error) {
          _log.warning('The poses kept in ${work.root.path} do not read, found again from its images: $error');
          found = _Found(images: found.images, total: found.total, blurred: found.blurred);
        }
      }
      final keptPlaced = found?.placed;
      if (found == null || keptPlaced == null || aligned == null) {
        final SplatPrepared prepared;
        if (found != null) {
          // The images of the last try, which COLMAP failed on: placed again from them
          _log.info('The images of ${work.root.path} are taken again: ${found.images} of ${found.total}');
          prepared = SplatPrepared(images: found.images, total: found.total, blurred: found.blurred);
          model
            ..read = found.total
            ..images = found.images;
        } else {
          await _fresh(work);
          final members = [for (final member in job.members) _SummedMember(member)];
          report(first, 0, done: 0, total: model.read);
          prepared = await images(
            members,
            video: job.isVideo,
            imagesFolder: work.images.path,
            cancel: cancel,
            onProgress: (count, all) {
              // What the preparation reads, once it says (the frames of a video longer than two minutes)
              if (all > 0 && all != model.read) {
                model
                  ..read = all
                  ..images = all;
              }
              report(first, all == 0 ? 0 : count / all, done: count, total: all);
            },
          );
          // The preparation by what it read, the steps after it by the images it kept
          model.read = prepared.total;
          times[first] = model.normalized(first, timeOf(first));
          checkCancel();
          if (prepared.images < SplatV1.minImages) {
            throw BackendException(
              ImmersiveErrorCode.tooFewImages,
              splatCountsMessage(prepared.images, prepared.total),
            );
          }
          model.images = prepared.images;
          _writeState(work, {
            'key': key,
            'sums': [for (final member in members) member.sum],
            'images': prepared.images,
            'total': prepared.total,
            'blurred': prepared.blurred,
          });
        }

        report(ImmersiveStage.features, 0, done: 0, total: prepared.images);
        final poses = await colmap.poses(
          work,
          images: prepared.images,
          video: job.isVideo,
          cancel: cancel,
          onProgress: (progress) => report(
            progress.stage,
            progress.total == 0 ? 0 : progress.done / progress.total,
            done: progress.done,
            total: progress.total,
          ),
        );
        for (final (name, at) in [
          ('features', ImmersiveStage.features),
          ('matching', ImmersiveStage.matching),
          ('mapping', ImmersiveStage.mapping),
        ]) {
          final took = poses.times[name];
          if (took != null) {
            times[at] = model.normalized(
              at,
              took + (at == ImmersiveStage.mapping ? poses.times['align'] ?? Duration.zero : Duration.zero),
            );
          }
        }
        aligned = poses.model;
        found = _Found(images: prepared.images, total: prepared.total, blurred: prepared.blurred, placed: poses.placed);
        _writeState(work, {..._readState(work) ?? const {}, 'placed': poses.placed});
        if (poses.incomplete) {
          _log.warning(
            'Splat scene ${job.id}: only ${poses.placed} of ${poses.images} images placed, made all the same: the '
            'scene may be incomplete',
          );
        }
      } else {
        model
          ..read = found.total
          ..images = found.images;
      }
      placedNow = SplatPlaced(found.placed!, found.images);
      checkCancel();

      report(ImmersiveStage.training, 0, done: 0, total: job.settings.steps);
      final pace = SplatTrainingPace();
      final trained = await brush.train(
        work,
        settings: job.settings,
        cancel: cancel,
        onProgress: (progress) {
          pace.add(progress.step, progress.elapsed);
          report(
            ImmersiveStage.training,
            progress.steps == 0 ? 0 : progress.step / progress.steps,
            done: progress.step,
            total: progress.steps,
            stageLeft: pace.left(progress.steps),
          );
        },
        onWaiting: (free) => _log.info('Brush waits for the graphics card: ${free ~/ (1 << 20)} MiB free'),
        onStarted: (pid) => _log.info('Brush started, process $pid'),
      );
      times[ImmersiveStage.training] = model.normalized(ImmersiveStage.training, trained.time);
      checkCancel();

      report(ImmersiveStage.splatCopy, 0);
      final written = await writeSplatFiles(
        brushPly: trained.ply.path,
        spzPath: job.partPath,
        plyPath: job.plyPartPath,
        subject: job.settings.subject,
        cameras: aligned.centres,
        axes: aligned.axes,
        shDegree: job.settings.shDegree,
        maxGaussians: job.settings.maxGaussians,
      );
      times[ImmersiveStage.splatCopy] = timeOf(ImmersiveStage.splatCopy);
      report(ImmersiveStage.splatCopy, 1);
      _log.info(
        'Splat scene ${job.id}: ${written.gaussians} gaussians (${written.dropped} dropped), '
        '${found.placed} of ${found.images} images placed, ${written.scale.note}; ${written.scale.said}',
      );
      done = true;
      final made = work;
      return ImmersiveResult.made(
        // Kept until the queue saved the file: a destination that refuses it leaves the poses and the training for Retry
        afterSaved: () => _settle(made, keep: false),
        details: SplatResultDetails(
          gaussians: written.gaussians,
          images: found.images,
          placed: found.placed!,
          subject: job.settings.subject,
          scale: written.scale.factor,
          fromVideo: job.isVideo,
          blurred: found.blurred,
          shDegree: written.shDegree,
          plyBytes: written.plyBytes,
          upright: written.scale.upright,
        ),
        bytesWritten: written.spzBytes,
        stageTimes: times,
      );
    } on BackendException catch (error) {
      if (error.code != ImmersiveErrorCode.cancelled) {
        _log.warning('Splat scene ${job.id} failed: ${error.code.name}: ${error.message}');
      }
      return fail(cancel.isCancelled ? ImmersiveErrorCode.cancelled : error.code, error.message);
    } on SplatFormatException catch (error) {
      return fail(ImmersiveErrorCode.trainingFailed, 'The export of Brush cannot be read: ${error.message}');
    } on FileSystemException catch (error) {
      return fail(writeFailureOf(error).errorCode, error.osError?.message ?? error.message);
    } catch (error, stack) {
      _log.warning('Splat scene ${job.id} could not be made', error, stack);
      return fail(cancel.isCancelled ? ImmersiveErrorCode.cancelled : ImmersiveErrorCode.modelFailed, '$error');
    } finally {
      final folder = work;
      if (folder != null) {
        final failure = failed;
        final keep = _kept(folder, done: done, failure: failure?.$1);
        final logs = failureLogs;
        if (failure != null && failure.$1 != ImmersiveErrorCode.cancelled && logs != null) {
          final (code, message) = failure;
          final what = job.isVideo ? 'a video' : '${job.members.length} photos';
          final kept = await keepSplatFailureLogs(
            folder,
            logs,
            header:
                'Splat scene ${job.id} (${job.lead.name}, $what, ${job.settings.subject.name}) failed: ${code.name}: '
                '$message\nThe last step the panel showed: ${stage.name}\n'
                '${keep ? _keptSaid : 'The work folder is deleted'}',
          );
          if (kept != null) {
            _log.info('The logs of the programs of splat scene ${job.id} are kept in ${kept.path}');
          }
        }
        final placed = _readState(folder)?['placed'] is int;
        await _settle(
          folder,
          keep: keep,
          why: done
              ? 'until the file is saved'
              : placed
              ? 'a day, for Retry from its poses'
              : 'a day, for Retry from its images and a diagnosis',
        );
      }
    }
  }

  /// Whether [work] stays when the job ends ([splatWorkKept]), by what splat.json says it holds
  bool _kept(SplatWorkFolder work, {required bool done, ImmersiveErrorCode? failure}) {
    final state = _readState(work);
    return splatWorkKept(
      done: done,
      placed: state?['placed'] is int,
      prepared: state?['images'] is int,
      failure: failure,
    );
  }

  /// What [work] kept for [key] (its poses, or its images only), when every member read again has the sum it had; null
  /// otherwise
  Future<_Found?> _keptFound(
    SplatJob job,
    SplatWorkFolder work,
    String key,
    NativeCancelFlag cancel,
    void Function(int read, int all) onRead,
  ) async {
    final state = _readState(work);
    final images = state?['images'];
    final total = state?['total'];
    final placed = state?['placed'];
    final blurred = state?['blurred'];
    if (state == null || state['key'] != key || images is! int || total is! int) {
      return null;
    }
    final withPoses = placed is int && work.aligned.existsSync();
    // Without the poses, the images COLMAP failed on, all of them
    if (!withPoses && _files(() => colmapImageNames(work.images).length) != images) {
      return null;
    }
    final sums = state['sums'];
    if (sums is! List || sums.length != job.members.length) {
      return null;
    }
    // A member the preparation never read (beyond the 200 photos taken) is not looked at, nor counted
    final read = [
      for (final (index, member) in job.members.indexed)
        if (sums[index] != null) (member, sums[index]),
    ];
    for (final (index, (member, kept)) in read.indexed) {
      onRead(index, read.length);
      // The sum the server gives for its asset, else the member read again (an original of the server downloaded)
      var sum = switch (member) {
        SplatMemberSum(:final knownSha1) => knownSha1,
        _ => null,
      };
      if (sum == null) {
        try {
          sum = (await member.load(cancel)).sha1;
        } catch (error) {
          if (cancel.isCancelled) {
            throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
          }
          _log.info('${member.name} could not be read again: $error');
        } finally {
          await member.release();
        }
      }
      if (sum != kept) {
        _log.info('${member.name} changed since its images were prepared: they are made again');
        return null;
      }
    }
    onRead(read.length, read.length);
    if (withPoses) {
      _log.info('The poses of ${work.root.path} are taken again: $placed of $images images placed');
    }
    return _Found(
      images: images,
      total: total,
      blurred: blurred is int ? blurred : 0,
      placed: withPoses ? placed : null,
    );
  }

  /// [action] on the files of the work folder; one that cannot be read leaves nothing to take again
  T? _files<T>(T Function() action) {
    try {
      return action();
    } on FileSystemException {
      return null;
    }
  }

  /// [work] empty and marked used now; the delete runs off this isolate (the window's in the app)
  Future<void> _fresh(SplatWorkFolder work) async {
    try {
      if (work.root.existsSync()) {
        await work.root.delete(recursive: true);
      }
      work.root.createSync(recursive: true);
      touchAiWorkFolder(work.root);
    } on FileSystemException catch (error) {
      throw splatFileFailure(error, 'the splat scene', ImmersiveErrorCode.writeFailed);
    }
  }

  Map<String, Object?>? _readState(SplatWorkFolder work) {
    try {
      final json = jsonDecode(File(p.join(work.root.path, splatStateFileName)).readAsStringSync());
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  void _writeState(SplatWorkFolder work, Map<String, Object?> state) {
    try {
      final file = File(p.join(work.root.path, splatStateFileName));
      final partial = File('${file.path}.part')..writeAsStringSync(jsonEncode(state), flush: true);
      partial.renameSync(file.path);
    } on FileSystemException catch (error) {
      throw splatFileFailure(error, 'the splat scene', ImmersiveErrorCode.writeFailed);
    }
  }

  /// At the end of a job: [work] kept and marked used when it may serve a Retry ([keep], [splatWorkKept]: the file made
  /// and not saved yet, a failure once the poses were found, or a failure of COLMAP once the images were prepared), the
  /// log saying how long ([why]), else deleted
  Future<void> _settle(SplatWorkFolder work, {required bool keep, String why = ''}) async {
    if (keep) {
      touchAiWorkFolder(work.root);
      _log.info('The work folder ${work.root.path} is kept $why');
      return;
    }
    // A program on Windows may hold a file of its folder a moment after it ended: tried again, the window's isolate
    // never held, the delete itself running off it
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        if (work.root.existsSync()) {
          await work.root.delete(recursive: true);
        }
        return;
      } on FileSystemException catch (error) {
        if (attempt == 9) {
          _log.warning('The work folder ${work.root.path} stays until it is a day old: $error');
          touchAiWorkFolder(work.root);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  @override
  Future<void> dispose() async {}
}
