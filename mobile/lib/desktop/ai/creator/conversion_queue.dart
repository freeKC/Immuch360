// The queue of the 3D conversions of a computer (design-final 2026-10-26, section 2.6), on the model of
// NetworkUploadNotifier: one queue for the whole app and one job at a time, since one photo already takes all the
// useful memory and every core but two. Each job has its own state and result, and the failure of one never stops the
// others (spec 5.4). A job is cancelled, retried, or cleared once it ended; "Retry failed" and "Cancel all" act on the
// whole queue.
//
// A disk full fails its job (its .part deleted) and pauses the queue: the user frees some space, then Resume runs that
// photo again and goes on. A photo that already has a 3D version with the same settings is skipped by default; the
// batch may make a new version instead, or replace that version, which is only done to a file that still carries our
// XMP and its DerivativeId when it is read again just before. The original is never opened for writing: the engine
// writes a .part, and the writer of the 3D photos renames it at the end (lot A5b).
//
// The queue does not survive the window: closing it asks first (close_guard.dart, reason "conversions"), and the
// journal of the .part files cleans up what a quit left.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:logging/logging.dart';

final _log = Logger('ConversionQueue');

/// Where the 3D photos are written (lot A5b): a .part with a dot name in the destination folder, kept in the journal
/// of partial files while it is written, then renamed onto the final name, reserved only at the end
abstract interface class ConversionOutput {
  /// The .part of [job] in the folder of its target (the check of the dialog may have made it already). Throws a
  /// [ConversionException]: readOnly, diskFull or writeFailed.
  Future<String> begin(ConversionJob job);

  /// Renames [partPath] onto the final name of [job] and gives the path written, which may differ from the target
  /// ("name (1)"). [replacing] is a version of ours, read again just before, that the new file takes the place of. Null
  /// when the name is taken and the user chose to skip such files; the .part is deleted then. Throws a
  /// [ConversionException] as [begin].
  Future<String?> finish(ConversionJob job, String partPath, {String? replacing});

  /// Deletes [partPath] and forgets it; nothing when it is gone already
  Future<void> discard(String partPath);
}

/// What the queue runs with, given by the AI screens (lot A5c): the engine (A4b), the writer of the 3D photos (A5b)
/// and the finder of the versions with the library index (A6a). The tests give fakes.
class ConversionTools {
  ConversionTools({
    required this.engine,
    required this.output,
    required this.finder,
    required this.creatorTool,
    this.software,
    this.depthModelSha256 = depthModelOnnxSha256,
    DateTime Function()? now,
    String Function()? newDerivativeId,
  }) : now = now ?? DateTime.now,
       newDerivativeId = newDerivativeId ?? StereoPhotoXmp.newDerivativeId;

  final ImmersiveEngine engine;
  final ConversionOutput output;
  final ExistingVersionFinder finder;

  /// xmp:CreatorTool, "Immuch360 Desktop 3.3.0 (windows)", and the EXIF Software, "Immuch360 Desktop 3.3.0"
  final String creatorTool;
  final String? software;

  /// The model the engine runs, part of the settings a version is compared on
  final String depthModelSha256;
  final DateTime Function() now;
  final String Function() newDerivativeId;
}

final conversionToolsProvider = Provider<ConversionTools>(
  (ref) => throw UnimplementedError('The AI screens give the tools of the conversions'),
);

/// The jobs of the queue, in the order they came
class ConversionQueueState {
  const ConversionQueueState({this.jobs = const [], this.isPaused = false});

  final List<ConversionJob> jobs;

  /// Stopped after a disk full: nothing starts until Resume
  final bool isPaused;

  /// The jobs waiting or under way: what quitting would stop, and the number the button of the bar shows
  int get pending => jobs.where((job) => !job.state.isEnded).length;

  bool get hasWork => pending > 0;

  /// The job under way, if any
  ConversionJob? get current => jobs.where((job) => job.state.isActive).firstOrNull;

  bool get hasFailed => jobs.any((job) => job.state == ConversionState.failed);

  bool get hasEnded => jobs.any((job) => job.state.isEnded);

  ConversionJob? byId(String id) => jobs.where((job) => job.id == id).firstOrNull;

  ConversionQueueState copyWith({List<ConversionJob>? jobs, bool? isPaused}) =>
      ConversionQueueState(jobs: jobs ?? this.jobs, isPaused: isPaused ?? this.isPaused);
}

class ConversionQueueNotifier extends Notifier<ConversionQueueState> {
  /// The stop flag of the job under way, read by the engine between two steps
  final _flags = <String, NativeCancelFlag>{};

  /// The jobs a disk full failed since the queue paused: Resume runs them again
  final _diskFull = <String>{};
  var _pumping = false;
  var _disposed = false;
  var _lastId = 0;

  @override
  ConversionQueueState build() {
    ref.onDispose(() {
      _disposed = true;
      // The job under way stops at its next check; its own end frees the flag, which the engine may still read
      for (final flag in _flags.values) {
        flag.cancel();
      }
    });
    return const ConversionQueueState();
  }

  /// Adds a batch, "1 of n" to "n of n", each photo with what to do when a version with the same settings exists;
  /// a request with a reason to skip is added skipped. Gives the ids of the jobs.
  List<String> add(List<ConversionRequest> requests, {ExistingVersionChoice existing = ExistingVersionChoice.skip}) {
    if (requests.isEmpty) {
      return const [];
    }
    final jobs = [
      for (final (index, request) in requests.indexed)
        ConversionJob(
          id: 'conversion-${++_lastId}',
          source: request.source,
          batchIndex: index + 1,
          batchSize: requests.length,
          target: request.target,
          quarterTurns: request.quarterTurns & 3,
          existing: existing,
          state: request.skip == null ? ConversionState.waiting : ConversionState.skipped,
          skipReason: request.skip,
        ),
    ];
    state = state.copyWith(jobs: [...state.jobs, ...jobs]);
    unawaited(_pump());
    return [for (final job in jobs) job.id];
  }

  /// Cancels a job: one waiting never runs, the one under way stops at its next check and leaves no file
  void cancel(String id) {
    final job = state.byId(id);
    if (job == null) {
      return;
    }
    if (job.state == ConversionState.waiting) {
      _set(id, (job) => job.copyWith(state: ConversionState.cancelled));
    } else if (job.state.isActive) {
      _flags[id]?.cancel();
    }
  }

  /// Cancels every job waiting and the one under way; a pause has nothing left to hold
  void cancelAll() {
    _diskFull.clear();
    state = ConversionQueueState(
      jobs: [
        for (final job in state.jobs)
          job.state == ConversionState.waiting ? job.copyWith(state: ConversionState.cancelled) : job,
      ],
    );
    for (final flag in _flags.values) {
      flag.cancel();
    }
  }

  /// Runs a failed or cancelled job again. Asking for it is asking the queue to go on: a pause ends too.
  void retry(String id) {
    final job = state.byId(id);
    if (job == null || !_retriable(job)) {
      return;
    }
    _diskFull.remove(id);
    _set(id, (job) => job.restarted());
    state = state.copyWith(isPaused: false);
    unawaited(_pump());
  }

  /// Runs every failed job again, and ends a pause
  void retryFailed() {
    if (!state.hasFailed) {
      return;
    }
    _diskFull.clear();
    state = ConversionQueueState(
      jobs: [for (final job in state.jobs) job.state == ConversionState.failed ? job.restarted() : job],
    );
    unawaited(_pump());
  }

  /// Forgets the jobs that ended: done, skipped, cancelled and failed. A pause with nothing left waiting ends.
  void clearFinished() {
    final jobs = [
      for (final job in state.jobs)
        if (!job.state.isEnded) job,
    ];
    _diskFull.removeWhere((id) => !jobs.any((job) => job.id == id));
    state = ConversionQueueState(jobs: jobs, isPaused: state.isPaused && jobs.isNotEmpty);
  }

  /// Goes on after a disk full, the photos it failed first
  void resume() {
    if (!state.isPaused) {
      return;
    }
    state = ConversionQueueState(
      jobs: [
        for (final job in state.jobs)
          _diskFull.contains(job.id) && job.state == ConversionState.failed ? job.restarted() : job,
      ],
    );
    _diskFull.clear();
    unawaited(_pump());
  }

  bool _retriable(ConversionJob job) =>
      job.target != null && (job.state == ConversionState.failed || job.state == ConversionState.cancelled);

  /// Runs the jobs waiting, in their order, one at a time, until none is left or the queue pauses
  Future<void> _pump() async {
    if (_pumping) {
      return;
    }
    _pumping = true;
    try {
      while (!_disposed && !state.isPaused) {
        final next = state.jobs.where((job) => job.state == ConversionState.waiting).firstOrNull;
        if (next == null) {
          break;
        }
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(ConversionJob job) async {
    final id = job.id;
    final ConversionTools tools;
    try {
      tools = ref.read(conversionToolsProvider);
    } catch (error, stack) {
      _log.severe('The tools of the conversions are missing', error, stack);
      _end(id, ImmersiveErrorCode.modelFailed, '$error');
      return;
    }
    final cancel = NativeCancelFlag();
    _flags[id] = cancel;
    _set(id, (job) => job.copyWith(state: ConversionState.reading, perMille: 0));
    String? part;
    // What an unexpected error means at each step
    var failure = ImmersiveErrorCode.sourceLost;
    try {
      final target = job.target!;
      final source = await job.source.prepare(cancel);
      if (cancel.isCancelled) {
        _end(id, ImmersiveErrorCode.cancelled);
        return;
      }

      ExistingVersion? same;
      if (job.existing != ExistingVersionChoice.newVersion) {
        same = await tools.finder.withSettings(
          DerivedRuleOriginal(name: source.name, size: source.size, folder: job.source.folder, sha1: source.sha1),
          versionSettingsKey(depthModelSha256: tools.depthModelSha256, quarterTurns: job.quarterTurns),
          folder: target.folder,
        );
        if (same != null && job.existing == ExistingVersionChoice.skip) {
          final path = same.path;
          _set(
            id,
            (job) => job.copyWith(
              state: ConversionState.skipped,
              skipReason: ConversionSkipReason.sameSettingsExists,
              existingVersionPath: path,
            ),
          );
          return;
        }
      }
      if (cancel.isCancelled) {
        _end(id, ImmersiveErrorCode.cancelled);
        return;
      }

      failure = ImmersiveErrorCode.writeFailed;
      part = await tools.output.begin(state.byId(id) ?? job);

      failure = ImmersiveErrorCode.modelFailed;
      final result = await tools.engine.run(
        ImmersiveJob(
          id: id,
          source: source,
          partPath: part,
          quarterTurns: job.quarterTurns,
          derivativeId: tools.newDerivativeId(),
          creatorTool: tools.creatorTool,
          created: StereoPhotoXmp.xmpDateTime(tools.now()),
          exif: _withSoftware(job.source.exif, tools.software),
        ),
        cancel: cancel,
        onProgress: (progress) => _progress(id, progress),
      );
      if (cancel.isCancelled) {
        _end(id, ImmersiveErrorCode.cancelled);
        return;
      }
      final error = result.error;
      if (error != null) {
        _end(id, error, result.message);
        return;
      }

      failure = ImmersiveErrorCode.writeFailed;
      _set(id, (job) => job.copyWith(state: ConversionState.writing));
      // Read again just before: a file that is no longer ours is never replaced, the new one goes beside it
      final replacing = same != null && job.existing == ExistingVersionChoice.replace && await _stillOurs(tools, same)
          ? same.path
          : null;
      final written = await tools.output.finish(state.byId(id) ?? job, part, replacing: replacing);
      if (written == null) {
        _set(id, (job) => job.copyWith(state: ConversionState.skipped, skipReason: ConversionSkipReason.nameTaken));
        return;
      }
      part = null;
      _set(
        id,
        (job) => job.copyWith(
          state: ConversionState.done,
          perMille: 1000,
          writtenPath: written,
          replaced: replacing != null,
          existingVersionPath: same?.path,
          eyeWidth: result.eyeWidth,
          eyeHeight: result.eyeHeight,
          reduced: result.reduced,
          qualityFlags: result.qualityFlags,
        ),
      );
    } on ConversionException catch (error) {
      _end(id, error.code, error.message);
    } catch (error, stack) {
      _log.warning('Conversion $id failed', error, stack);
      _end(id, failure, '$error');
    } finally {
      final partPath = part;
      if (partPath != null) {
        try {
          await tools.output.discard(partPath);
        } catch (error) {
          _log.warning('The partial file of $id could not be deleted', error);
        }
      }
      try {
        await job.source.release();
      } catch (error) {
        _log.warning('The temporary copy of $id could not be deleted', error);
      }
      _flags.remove(id);
      cancel.free();
    }
  }

  Future<bool> _stillOurs(ConversionTools tools, ExistingVersion version) async =>
      await tools.finder.readOurs(version.path) != null;

  /// Ends a job that made no file: cancelled, or failed with [code]; a disk full pauses the queue
  void _end(String id, ImmersiveErrorCode code, [String? message]) {
    if (code == ImmersiveErrorCode.cancelled) {
      _set(id, (job) => job.copyWith(state: ConversionState.cancelled));
      return;
    }
    _set(id, (job) => job.copyWith(state: ConversionState.failed, error: code, message: message));
    if (code == ImmersiveErrorCode.diskFull && !_disposed) {
      _diskFull.add(id);
      state = state.copyWith(isPaused: true);
    }
  }

  void _progress(String id, ImmersiveProgress progress) => _set(
    id,
    (job) => job.state.isActive
        ? job.copyWith(state: ConversionState.of(progress.stage), perMille: progress.perMille.clamp(0, 1000))
        : job,
  );

  void _set(String id, ConversionJob Function(ConversionJob job) change) {
    if (_disposed) {
      return;
    }
    state = state.copyWith(jobs: [for (final job in state.jobs) job.id == id ? change(job) : job]);
  }
}

ImmersiveExif _withSoftware(ImmersiveExif exif, String? software) => exif.software != null || software == null
    ? exif
    : ImmersiveExif(
        dateTimeOriginal: exif.dateTimeOriginal,
        offsetTimeOriginal: exif.offsetTimeOriginal,
        latitude: exif.latitude,
        longitude: exif.longitude,
        altitude: exif.altitude,
        software: software,
      );

final conversionQueueProvider = NotifierProvider<ConversionQueueNotifier, ConversionQueueState>(
  ConversionQueueNotifier.new,
);
