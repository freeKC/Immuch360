// The queue of the AI conversions of a computer (design-final 2026-10-26, section 2.6; design-final 2026-10-27,
// sections 2.5 and 4.5), on the model of NetworkUploadNotifier: one queue for the whole app. Each job has its own state
// and result, and the failure of one never stops the others (spec 5.4). A job is cancelled, retried, or cleared once
// it ended; "Retry failed" and "Cancel all" act on the whole queue.
//
// Each kind of job (ConversionKind) runs on the engine of its kind (ConversionEngine), given the spec of its kind only.
// Two lanes, one job at a time on each: the processor (3D photos, 3D scenes, 360° 3D panoramas), where one photo
// already takes every core but two, and the graphics card (360° panoramas), so that a generation of several minutes
// never holds the 3D photos back. A job starts beside the one of the other lane only when the memory free holds both
// (memory_probe.dart), counting what that job may still take: all its need until its models run, a panorama that reads
// its photo having taken nothing yet. It waits otherwise, looked at again every few seconds, and starts at the latest
// when the other ends.
//
// The 3D version of a panorama is chained after it: it waits for the panorama, is made from the file the panorama job
// wrote (or the version with the same settings it found), as a version of the photo, and is skipped with its reason
// when the panorama was not made; Retry of the panorama runs it again too. A panorama the app generated, chosen by
// itself later ("Make the 3D version"), gives a version of its photo the same way, from the packet it carries.
//
// A disk full fails its job (its .part deleted) and pauses the queue, both lanes: nothing new starts until the user
// frees some space and Resume runs that photo again. A photo that already has a version of the kind with the same
// settings is skipped by default; the batch may make a new version instead (a panorama then draws a new seed), or
// replace that version when it is in the destination folder. The original is never opened for writing: the engine
// writes a .part, and the writer of the versions renames it at the end (lot A5b). The writer alone decides whether a
// file may be replaced, by reading it again just before the rename: the queue has no rule of its own for that.
//
// A job tells "step 12 of 28" when its engine does, and its time left: the time the step tells (a generation), else
// the times of the steps on this computer (AiTimings), which each job done keeps up to date in desktop_ai.json.
//
// Before a job of the graphics card starts, the card is asked again for the memory it has free (lot C6,
// gpu_budget.dart): held by other programs, the job waits with what is free, the lane of the graphics card with it
// (a second panorama would only wait the same), the processor lane going on; the card is asked again a little later,
// or at once when the user asks (checkGraphicsCardAgain), and a card gone fails the job.
//
// The queue does not survive the window: closing it asks first (close_guard.dart, reasons "conversions" and
// "generation"), and the journal of the .part files cleans up what a quit left.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ConversionQueue');

/// What became of a version at the end of its job, as the writer tells it (SaveOutcome of the writer of lot A5b)
enum ConversionSaveOutcome {
  /// Under its name, or the first free "name (n)" of it
  saved,

  /// In place of an earlier 3D photo of ours
  replaced,

  /// Not kept: the name was taken and the user chose to skip such files
  skipped,
}

/// The file a job ended with
class ConversionSaved {
  const ConversionSaved({required this.path, required this.outcome});

  /// The 3D photo; for a skipped one, the file that was already there
  final String path;
  final ConversionSaveOutcome outcome;
}

/// Where the 3D photos are written (lot A5b): a .part with a dot name in the destination folder, kept in the journal
/// of partial files while it is written, then renamed onto the final name, reserved only at the end
abstract interface class ConversionOutput {
  /// The .part of [job] in the folder of its target (the check of the dialog may have made it already). Throws a
  /// [ConversionException]: readOnly, diskFull or writeFailed.
  Future<String> begin(ConversionJob job);

  /// Puts [partPath] under the final name of [job], in the folder of its target and nowhere else, as [whenExists] says
  /// when that name is taken, and tells what it did: keepBoth takes the first free "name (n)"; replace takes the place
  /// of [replaceName] (a file of that folder, the final name when null) only when it is a 3D photo of ours made from
  /// [original] (its sum, else its name and size) with its DerivativeId, read again just before, and keeps both
  /// otherwise; skip leaves the file there and deletes the .part. [original] itself is never replaced. This is
  /// SafeWriter.commit of lot A5b, with the same rule for a file that may be replaced.
  ///
  /// Throws a [ConversionException] as [begin], and the queue discards the .part then. The writer of A5b throws
  /// CreatorWriteException: its adapter gives failure.errorCode in a ConversionException, or a disk full at the rename
  /// would end as writeFailed and no longer pause the queue.
  Future<ConversionSaved> finish(
    ConversionJob job,
    String partPath, {
    required ImmersiveSource original,
    required AiWhenExists whenExists,
    String? replaceName,
  });

  /// Deletes [partPath] and forgets it; nothing when it is gone already
  Future<void> discard(String partPath);
}

/// The engine of one kind of job and what the queue asks before it runs one: the key of the settings the file would
/// carry, to find a version made with the same settings, and for a panorama the generator and its steps. The 3D photo
/// has its own (ConversionTools.engine); desktop_conversion_tools.dart registers the others, the tests the fakes.
class ConversionEngine {
  const ConversionEngine({required this.engine, required this.settingsKey, this.generator, this.steps});

  /// Runs the specs of this kind only
  final ImmersiveEngine engine;

  /// The settingsKey the XMP of the file of a job would carry, the job reading [source] (the original, or the panorama
  /// of a chained job) with [quarterTurns]; null when it cannot be told before the run: no version is looked for then
  final FutureOr<String?> Function(ImmersiveSource source, int quarterTurns) settingsKey;

  /// A panorama: the transformer by its catalogue id (the variant the gate chose) and the steps of the generation
  final String? generator;
  final int? steps;
}

/// What the queue runs with, given by the AI screens (lot A5c): the engine of the 3D photos (A4b) and those of the
/// other kinds, the writer of the versions (A5b), the finder of the versions with the library index (A6a), the memory
/// of the computer and the settings that keep the times of the steps. The tests give fakes.
class ConversionTools {
  ConversionTools({
    required this.engine,
    required this.output,
    required this.finder,
    required this.creatorTool,
    this.software,
    this.depthModelSha256 = depthModelOnnxSha256,
    this.engines = const {},
    this.memory = const SystemMemoryProbe(),
    this.memoryRecheck = const Duration(seconds: 5),
    this.gpuBudget,
    this.gpuRecheck = const Duration(seconds: 15),
    this.settings,
    DateTime Function()? now,
    String Function()? newDerivativeId,
    int Function()? newSeed,
  }) : now = now ?? DateTime.now,
       newDerivativeId = newDerivativeId ?? StereoPhotoXmp.newDerivativeId,
       newSeed = newSeed ?? _randomSeed;

  /// The engine of the 3D photos
  final ImmersiveEngine engine;

  /// The engines of the other kinds; one given for the 3D photo takes the place of [engine]
  final Map<ConversionKind, ConversionEngine> engines;
  final ConversionOutput output;
  final ExistingVersionFinder finder;

  /// xmp:CreatorTool, "Immuch360 Desktop 3.3.0 (windows)", and the EXIF Software, "Immuch360 Desktop 3.3.0"
  final String creatorTool;
  final String? software;

  /// The model the engine of the 3D photos runs, part of the settings a 3D photo is compared on
  final String depthModelSha256;

  /// The memory of the computer, read before a job starts beside one of the other lane, and how often a job that
  /// waits for it reads it again
  final MemoryProbe memory;
  final Duration memoryRecheck;

  /// Asked before each job of the graphics card whether the card has the memory free for it now, and how often a job
  /// that waits for it asks again; null in the tests and builds that give none: such a job starts as any other
  final GpuBudget? gpuBudget;
  final Duration gpuRecheck;

  /// Where the times of the steps are kept (desktop_ai.json); null: the timings of the design only, nothing kept
  final DesktopAiSettingsStore? settings;
  final DateTime Function() now;
  final String Function() newDerivativeId;

  /// The seed of a panorama, drawn for each job: "Make a new version" gives another panorama
  final int Function() newSeed;

  late final _sbs = ConversionEngine(
    engine: engine,
    settingsKey: (source, quarterTurns) =>
        versionSettingsKey(depthModelSha256: depthModelSha256, quarterTurns: quarterTurns),
  );

  /// The engine of the jobs of [kind], null when this build has none
  ConversionEngine? engineFor(ConversionKind kind) =>
      engines[kind] ?? (kind == ConversionKind.sbsFromPhoto ? _sbs : null);

  /// Whether this build makes the files of [kind]
  bool supports(ConversionKind kind) => engineFor(kind) != null;
}

final _seeds = math.Random.secure();

/// A seed of a generation, positive and within 31 bits for every generator
int _randomSeed() => _seeds.nextInt(0x7fffffff);

final conversionToolsProvider = Provider<ConversionTools>(
  (ref) => throw UnimplementedError('The AI screens give the tools of the conversions'),
);

/// The jobs of the queue, in the order they came
class ConversionQueueState {
  const ConversionQueueState({this.jobs = const [], this.isPaused = false});

  final List<ConversionJob> jobs;

  /// Stopped after a disk full: nothing starts on either lane until Resume
  final bool isPaused;

  /// The jobs waiting or under way: what quitting would stop, and the number the button of the bar shows
  int get pending => jobs.where((job) => !job.state.isEnded).length;

  bool get hasWork => pending > 0;

  /// A job under way, if any: the first one
  ConversionJob? get current => jobs.where((job) => job.state.isActive).firstOrNull;

  /// The jobs under way, one per lane at most
  List<ConversionJob> get running => [
    for (final job in jobs)
      if (job.state.isActive) job,
  ];

  /// The job under way on [lane], if any
  ConversionJob? onLane(ConversionLane lane) =>
      jobs.where((job) => job.state.isActive && job.kind.lane == lane).firstOrNull;

  /// The panorama being generated, once its generation tells its steps: what closing the window would stop
  ConversionJob? get generating => jobs
      .where(
        (job) =>
            job.kind == ConversionKind.panoramaFromPhoto &&
            job.state == ConversionState.generating &&
            job.steps != null,
      )
      .firstOrNull;

  bool get hasFailed => jobs.any((job) => job.state == ConversionState.failed);

  bool get hasEnded => jobs.any((job) => job.state.isEnded);

  ConversionJob? byId(String id) => jobs.where((job) => job.id == id).firstOrNull;

  ConversionQueueState copyWith({List<ConversionJob>? jobs, bool? isPaused}) =>
      ConversionQueueState(jobs: jobs ?? this.jobs, isPaused: isPaused ?? this.isPaused);
}

class ConversionQueueNotifier extends Notifier<ConversionQueueState> {
  /// The stop flag of each job under way, read by the engine between two steps
  final _flags = <String, NativeCancelFlag>{};

  /// The job under way on each lane
  final _lanes = <ConversionLane, String>{};

  /// The jobs a disk full failed since the queue paused: Resume runs them again
  final _diskFull = <String>{};

  /// When the step shown of each job under way started, for its time left
  final _stepStarted = <String, DateTime>{};

  /// The 3D versions waiting for their panorama when Cancel all was asked: skipped with their reason once it ends
  /// without its file, cancelled when it was written all the same (its rename was under way)
  final _stoppedWithParent = <String>{};

  /// The times of the steps this computer measured, read once from the settings then kept up to date
  Map<String, Map<String, int>>? _measured;
  Timer? _recheck;

  /// A job of the graphics card waits for its memory: no job starts on that lane until [_gpuRecheck] asks again
  var _gpuWaits = false;
  Timer? _gpuRecheck;
  var _disposed = false;
  var _lastId = 0;

  @override
  ConversionQueueState build() {
    ref.onDispose(() {
      _disposed = true;
      _recheck?.cancel();
      _gpuRecheck?.cancel();
      // The jobs under way stop at their next check; their own end frees the flag, which the engine may still read
      for (final flag in _flags.values) {
        flag.cancel();
      }
    });
    return const ConversionQueueState();
  }

  /// Adds a batch of [kind], "1 of n" to "n of n", each photo with what to do when a version with the same settings
  /// exists and when the name of its file is taken; a request with a reason to skip is added skipped. With
  /// [alsoStereo], each panorama that runs is followed by its 3D version, chained after it, in the same folder. Gives
  /// the ids of the jobs, each chained job right after its panorama.
  List<String> add(
    List<ConversionRequest> requests, {
    ConversionKind kind = ConversionKind.sbsFromPhoto,
    ExistingVersionChoice existing = ExistingVersionChoice.skip,
    AiWhenExists whenExists = AiWhenExists.keepBoth,
    bool alsoStereo = false,
  }) {
    if (requests.isEmpty) {
      return const [];
    }
    final chained = alsoStereo && kind == ConversionKind.panoramaFromPhoto;
    final jobs = <ConversionJob>[];
    for (final (index, request) in requests.indexed) {
      final job = ConversionJob(
        id: 'conversion-${++_lastId}',
        source: request.source,
        kind: kind,
        batchIndex: index + 1,
        batchSize: requests.length,
        target: request.target,
        quarterTurns: request.quarterTurns & 3,
        existing: existing,
        whenExists: whenExists,
        state: request.skip == null ? ConversionState.waiting : ConversionState.skipped,
        skipReason: request.skip,
      );
      jobs.add(job);
      final target = request.target;
      if (chained && request.skip == null && target != null) {
        jobs.add(
          ConversionJob(
            id: 'conversion-${++_lastId}',
            source: request.source,
            kind: ConversionKind.stereoPanoramaFromPanorama,
            parentId: job.id,
            batchIndex: index + 1,
            batchSize: requests.length,
            target: ConversionTarget.inFolder(
              target.folder,
              request.source.name,
              kind: ConversionKind.stereoPanoramaFromPanorama,
            ),
            quarterTurns: request.quarterTurns & 3,
            existing: existing,
            whenExists: whenExists,
          ),
        );
      }
    }
    state = state.copyWith(jobs: [...state.jobs, ...jobs]);
    _pump();
    return [for (final job in jobs) job.id];
  }

  /// Cancels a job: one waiting never runs (nor the 3D version chained after it), the one under way stops at its next
  /// check and leaves no file
  void cancel(String id) {
    final job = state.byId(id);
    if (job == null) {
      return;
    }
    if (job.state == ConversionState.waiting) {
      _stoppedWithParent.remove(id);
      _set(id, (job) => job.copyWith(state: ConversionState.cancelled, waitingFor: () => null));
      // The job the lane of the graphics card waited for is gone: the next one asks the card at once
      if (job.waitingFor == ConversionWait.graphicsMemory) {
        checkGraphicsCardAgain();
      } else {
        _pump();
      }
    } else if (job.state.isActive) {
      _flags[id]?.cancel();
    }
  }

  /// Cancels every job waiting and those under way; a pause has nothing left to hold. A 3D version waiting for its
  /// panorama is skipped with its reason once the panorama ends cancelled (at once for one that waited), as after
  /// Cancel of the panorama: Retry of the panorama runs it again. Nothing starts after it: one whose panorama was
  /// written all the same is cancelled.
  void cancelAll() {
    _diskFull.clear();
    bool waitsForParent(ConversionJob job) =>
        job.state == ConversionState.waiting && job.parentId != null && job.inputPath == null;
    _stoppedWithParent.addAll([
      for (final job in state.jobs)
        if (waitsForParent(job)) job.id,
    ]);
    state = ConversionQueueState(
      jobs: [
        for (final job in state.jobs)
          job.state == ConversionState.waiting && !waitsForParent(job)
              ? job.copyWith(state: ConversionState.cancelled, waitingFor: () => null)
              : job,
      ],
    );
    for (final flag in _flags.values) {
      flag.cancel();
    }
    // Nothing waits for the graphics card any more: the next job of it asks the card at once
    _gpuRecheck?.cancel();
    _gpuRecheck = null;
    _gpuWaits = false;
    _settleChained();
  }

  /// Runs a failed or cancelled job again, and the 3D version chained after it. Asking for it is asking the queue to
  /// go on: a pause ends too.
  void retry(String id) {
    final job = state.byId(id);
    if (job == null || !_retriable(job)) {
      return;
    }
    _diskFull.remove(id);
    state = ConversionQueueState(jobs: _restarted({id}));
    _pump();
  }

  /// Runs every failed job again, and the 3D versions chained after them; ends a pause
  void retryFailed() {
    if (!state.hasFailed) {
      return;
    }
    _diskFull.clear();
    state = ConversionQueueState(
      jobs: _restarted({
        for (final job in state.jobs)
          if (job.state == ConversionState.failed) job.id,
      }),
    );
    _pump();
  }

  /// Forgets the jobs that ended: done, skipped, cancelled and failed. A pause with nothing left waiting ends.
  void clearFinished() {
    _settleChained();
    final jobs = [
      for (final job in state.jobs)
        if (!job.state.isEnded) job,
    ];
    _diskFull.removeWhere((id) => !jobs.any((job) => job.id == id));
    state = ConversionQueueState(jobs: jobs, isPaused: state.isPaused && jobs.isNotEmpty);
  }

  /// Forgets a job that ended, as Clear finished does for all of them: a version deleted from the panel. Nothing for a
  /// job waiting or under way.
  void remove(String id) {
    _settleChained();
    final job = state.byId(id);
    if (job == null || !job.state.isEnded) {
      return;
    }
    _diskFull.remove(id);
    final jobs = [
      for (final other in state.jobs)
        if (other.id != id) other,
    ];
    state = ConversionQueueState(jobs: jobs, isPaused: state.isPaused && jobs.any((job) => !job.state.isEnded));
  }

  /// Asks the graphics card again now for the memory the job waiting for it needs, instead of a little later
  void checkGraphicsCardAgain() {
    _gpuRecheck?.cancel();
    _gpuRecheck = null;
    _gpuWaits = false;
    _pump();
  }

  /// Goes on after a disk full, the photos it failed first
  void resume() {
    if (!state.isPaused) {
      return;
    }
    state = ConversionQueueState(
      jobs: _restarted({
        for (final job in state.jobs)
          if (_diskFull.contains(job.id) && job.state == ConversionState.failed) job.id,
      }),
    );
    _diskFull.clear();
    _pump();
  }

  bool _retriable(ConversionJob job) =>
      job.target != null && (job.state == ConversionState.failed || job.state == ConversionState.cancelled);

  /// The jobs with [ids] as they were added, and the jobs chained after them that were skipped for them
  List<ConversionJob> _restarted(Set<String> ids) => [
    for (final job in state.jobs)
      if (ids.contains(job.id) || (job.skipReason == ConversionSkipReason.parentNotMade && ids.contains(job.parentId)))
        job.restarted()
      else
        job,
  ];

  /// Gives each chained job waiting the file its parent made, or skips it when the parent ended without one; cancels it
  /// when Cancel all stopped its parent
  void _settleChained() {
    for (final job in state.jobs) {
      final parentId = job.parentId;
      if (parentId == null || job.state != ConversionState.waiting || job.inputPath != null) {
        continue;
      }
      final parent = state.byId(parentId);
      if (parent != null && !parent.state.isEnded) {
        continue;
      }
      final stopped = _stoppedWithParent.remove(job.id);
      final made = switch (parent) {
        ConversionJob(state: ConversionState.done, :final writtenPath) => writtenPath,
        ConversionJob(
          state: ConversionState.skipped,
          skipReason: ConversionSkipReason.sameSettingsExists,
          :final existingVersionPath,
        ) =>
          existingVersionPath,
        _ => null,
      };
      _set(
        job.id,
        (job) => switch (made) {
          null => job.copyWith(
            state: ConversionState.skipped,
            skipReason: ConversionSkipReason.parentNotMade,
            waitingFor: () => null,
          ),
          _ when stopped => job.copyWith(state: ConversionState.cancelled, waitingFor: () => null),
          _ => job.copyWith(inputPath: () => made),
        },
      );
    }
  }

  /// Starts on each free lane the first job waiting that may run: its parent made, if it has one; beside a job of the
  /// other lane, only when the memory free holds both, that job counted with what it may still take (one started a
  /// moment before in this same pass included). Nothing starts while the queue is paused.
  void _pump() {
    if (_disposed) {
      return;
    }
    _settleChained();
    if (state.isPaused) {
      return;
    }
    ConversionTools? tools;
    try {
      tools = ref.read(conversionToolsProvider);
    } catch (_) {
      // Each job then fails and says why (_run)
    }
    // The first job that may run on each free lane, in the order they came: a panorama added before the scenes starts
    // before them, and a lane never keeps the other one waiting for ever
    final order = {for (final (index, job) in state.jobs.indexed) job.id: index};
    final candidates = [
      for (final lane in ConversionLane.values)
        if (!_lanes.containsKey(lane) && !(lane == ConversionLane.gpu && _gpuWaits))
          ?state.jobs
              .where(
                (job) =>
                    job.state == ConversionState.waiting &&
                    job.kind.lane == lane &&
                    (job.parentId == null || job.inputPath != null),
              )
              .firstOrNull,
    ]..sort((a, b) => order[a.id]!.compareTo(order[b.id]!));
    for (final next in candidates) {
      // The job under way on the other lane, one started a moment before in this pass included
      final beside = [for (final id in _lanes.values) state.byId(id)].nonNulls.firstOrNull;
      if (tools != null &&
          _lanes.isNotEmpty &&
          !fitsBeside(
            jobMemoryNeedOf(next.kind.output),
            tools.memory.read(),
            besideNeeds: beside == null || beside.state.isEnded
                ? 0
                : jobMemoryStillNeeded(beside.kind.output, beside.state.stage),
          )) {
        if (next.waitingFor != ConversionWait.memory) {
          _set(next.id, (job) => job.copyWith(waitingFor: () => ConversionWait.memory));
        }
        _recheck ??= Timer(tools.memoryRecheck, () {
          _recheck = null;
          _pump();
        });
        continue;
      }
      final lane = next.kind.lane;
      _lanes[lane] = next.id;
      unawaited(
        _run(next).whenComplete(() {
          _lanes.remove(lane);
          _pump();
        }),
      );
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
    final kindEngine = tools.engineFor(job.kind);
    if (kindEngine == null) {
      _end(id, ImmersiveErrorCode.modelFailed, 'This build has no engine for ${job.kind.name}');
      return;
    }
    if (job.kind.lane == ConversionLane.gpu && !await _graphicsCardReady(id, tools)) {
      return;
    }
    final cancel = NativeCancelFlag();
    _flags[id] = cancel;
    _stepStarted[id] = tools.now();
    _set(
      id,
      (job) => job.copyWith(
        state: ConversionState.reading,
        perMille: 0,
        waitingFor: () => null,
        waitingFree: () => null,
        step: () => null,
        steps: () => null,
        remaining: () => null,
      ),
    );
    String? part;
    // What an unexpected error means at each step
    var failure = ImmersiveErrorCode.sourceLost;
    try {
      final timings = AiTimings(await _measuredTimings(tools));
      final target = job.target!;
      final input = job.inputPath;
      final ImmersiveSource source;
      final ImmersiveSource original;
      PanoramaXmp? parent;
      if (input == null) {
        final prepared = await job.source.prepare(cancel);
        // A panorama the app generated, chosen by itself ("Make the 3D version"): its 3D version is a version of the
        // photo it was generated from, as when it is chained after it
        final generated = job.kind == ConversionKind.stereoPanoramaFromPanorama
            ? await _generatedPanoramaIn(prepared)
            : null;
        if (generated == null) {
          source = original = prepared;
        } else {
          parent = generated;
          source = ImmersiveSource(
            name: prepared.name,
            size: prepared.size,
            sha1: '',
            path: prepared.path,
            bytes: prepared.bytes,
          );
          original = _photoNamedBy(generated);
        }
      } else {
        // The panorama its parent made: the 3D version is a version of the photo the panorama names
        (source, parent) = await _panoramaAt(input);
        original = _photoOf(job.source, parent);
      }
      if (cancel.isCancelled) {
        _end(id, ImmersiveErrorCode.cancelled);
        return;
      }

      ExistingVersion? same;
      if (job.existing != ExistingVersionChoice.newVersion) {
        // Skip looks wherever the index knows a version; Replace only in the destination folder, where the new file
        // goes and was checked: a version elsewhere stays, and the new one is written beside the others
        same = await _sameSettings(tools, kindEngine, job, source, original, target, parent: parent);
        if (same != null && job.existing == ExistingVersionChoice.skip) {
          final path = same.path;
          _set(
            id,
            (job) => job.copyWith(
              state: ConversionState.skipped,
              skipReason: ConversionSkipReason.sameSettingsExists,
              existingVersionPath: path,
              remaining: () => null,
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
      final spec = _specOf(job, tools, kindEngine, source: source, original: original, parent: parent, part: part);
      if (spec == null) {
        _end(id, ImmersiveErrorCode.componentsMissing, 'No generator for ${job.kind.name} in this build');
        return;
      }
      assert(spec.kind == job.kind.output, 'The spec of ${job.kind.name} is a ${spec.kind.name}');
      final ImmersiveResult result;
      try {
        result = await kindEngine.engine.run(
          spec,
          cancel: cancel,
          onProgress: (progress) => _progress(id, progress, timings, tools.now),
        );
      } on TypeError catch (error) {
        // The parameter of ImmersiveEngine.run is covariant: an engine registered for another kind refuses this spec
        _end(id, ImmersiveErrorCode.modelFailed, 'The engine of ${job.kind.name} cannot run it: $error');
        return;
      }
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
      _set(id, (job) => job.copyWith(state: ConversionState.writing, step: () => null, steps: () => null));
      // The version of the destination folder with the same settings for Replace; never a replace for a new version,
      // whatever the choice for a name taken says; otherwise that choice. Whether the file may be replaced is read by
      // the writer just before the rename.
      final (AiWhenExists whenExists, String? replaceName) = switch (job.existing) {
        ExistingVersionChoice.replace when same != null => (AiWhenExists.replace, p.basename(same.path)),
        ExistingVersionChoice.newVersion => (AiWhenExists.keepBoth, null),
        _ => (job.whenExists, null),
      };
      final saved = await tools.output.finish(
        state.byId(id) ?? job,
        part,
        original: original,
        whenExists: whenExists,
        replaceName: replaceName,
      );
      // Renamed, or deleted for a name taken: the writer took it
      part = null;
      if (saved.outcome == ConversionSaveOutcome.skipped) {
        _set(
          id,
          (job) => job.copyWith(
            state: ConversionState.skipped,
            skipReason: ConversionSkipReason.nameTaken,
            remaining: () => null,
          ),
        );
        return;
      }
      // Kept before the job is told done: nothing of it is still written once it shows done
      await _keepTimings(tools, job.kind, result.stageTimes);
      // What the writer did, not what was asked: it keeps both when the version is no longer ours at the rename
      final replaced = saved.outcome == ConversionSaveOutcome.replaced;
      _set(
        id,
        (job) => job.copyWith(
          state: ConversionState.done,
          perMille: 1000,
          writtenPath: saved.path,
          replaced: replaced,
          existingVersionPath: replaced ? saved.path : null,
          eyeWidth: result.eyeWidth,
          eyeHeight: result.eyeHeight,
          reduced: result.reduced,
          qualityFlags: result.qualityFlags,
          details: result.details,
          remaining: () => null,
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
      _stepStarted.remove(id);
      cancel.free();
    }
  }

  /// Whether the job [id] of the graphics card may start now: the card has the memory free (or nothing is asked of it,
  /// tools without a budget). Otherwise the job waits with what is free and the lane with it, asked again after
  /// ConversionTools.gpuRecheck; or it fails when no card can take it. False too when it was cancelled meanwhile.
  Future<bool> _graphicsCardReady(String id, ConversionTools tools) async {
    final budget = tools.gpuBudget;
    if (budget == null) {
      return true;
    }
    GpuBudgetCheck check;
    try {
      check = await budget.check();
    } catch (error, stack) {
      _log.warning('The graphics card could not be asked for $id', error, stack);
      check = const GpuBudgetUnavailable(AiGateReason.gpuNoAnswer);
    }
    if (state.byId(id)?.state != ConversionState.waiting) {
      return false;
    }
    switch (check) {
      case GpuBudgetReady():
        return true;
      case GpuBudgetWait(:final free):
        _set(id, (job) => job.copyWith(waitingFor: () => ConversionWait.graphicsMemory, waitingFree: () => free));
        _gpuWaits = true;
        _gpuRecheck?.cancel();
        _gpuRecheck = Timer(tools.gpuRecheck, () {
          _gpuRecheck = null;
          _gpuWaits = false;
          _pump();
        });
        return false;
      case GpuBudgetUnavailable(:final reason):
        _end(id, ImmersiveErrorCode.gpuUnavailable, reason.name);
        return false;
    }
  }

  /// The spec of [job] for its engine; null for a panorama whose engine names no generator
  ImmersiveJobSpec? _specOf(
    ConversionJob job,
    ConversionTools tools,
    ConversionEngine kindEngine, {
    required ImmersiveSource source,
    required ImmersiveSource original,
    required PanoramaXmp? parent,
    required String part,
  }) {
    final derivativeId = tools.newDerivativeId();
    final created = StereoPhotoXmp.xmpDateTime(tools.now());
    final exif = _withSoftware(job.source.exif, tools.software);
    switch (job.kind) {
      case ConversionKind.sbsFromPhoto:
        return ImmersiveJob(
          id: job.id,
          source: source,
          partPath: part,
          quarterTurns: job.quarterTurns,
          derivativeId: derivativeId,
          creatorTool: tools.creatorTool,
          created: created,
          exif: exif,
        );
      case ConversionKind.sceneFromPhoto:
        return SceneJob(
          id: job.id,
          sources: [source],
          partPath: part,
          quarterTurns: job.quarterTurns,
          derivativeId: derivativeId,
          creatorTool: tools.creatorTool,
          created: created,
          exif: exif,
        );
      case ConversionKind.panoramaFromPhoto:
        final generator = kindEngine.generator;
        final steps = kindEngine.steps;
        if (generator == null || steps == null) {
          return null;
        }
        return PanoramaJob(
          id: job.id,
          source: source,
          partPath: part,
          quarterTurns: job.quarterTurns,
          derivativeId: derivativeId,
          creatorTool: tools.creatorTool,
          created: created,
          exif: exif,
          generator: generator,
          steps: steps,
          seed: tools.newSeed(),
        );
      case ConversionKind.stereoPanoramaFromPanorama:
        return StereoPanoramaJob(
          id: job.id,
          source: source,
          photo: parent == null ? null : original,
          parent: parent,
          partPath: part,
          quarterTurns: job.quarterTurns,
          derivativeId: derivativeId,
          creatorTool: tools.creatorTool,
          created: created,
          exif: exif,
        );
    }
  }

  /// The panorama at [path] a chained job reads, and its packet. Throws a [ConversionException]: sourceLost when it
  /// is gone or names no photo.
  Future<(ImmersiveSource, PanoramaXmp)> _panoramaAt(String path) async {
    final head = await readFileHead(path);
    final xmp = head == null ? null : ImmersiveXmp.findIn(head);
    if (xmp is! PanoramaXmp || xmp.sourceName == null || xmp.sourceSize == null || xmp.sourceSha1 == null) {
      throw ConversionException(
        ImmersiveErrorCode.sourceLost,
        head == null ? 'The 360° panorama is gone' : 'The 360° panorama does not name its photo',
      );
    }
    try {
      final size = await File(path).length();
      // Its own sum is never written: the 3D version is a version of the photo
      return (ImmersiveSource(name: p.basename(path), size: size, sha1: '', path: path), xmp);
    } on FileSystemException catch (error) {
      throw ConversionException(ImmersiveErrorCode.sourceLost, error.osError?.message ?? error.message);
    }
  }

  /// The packet of [source] when it is a panorama the app generated that names its photo, null for any other picture
  /// (a 360° photo of the user)
  Future<PanoramaXmp?> _generatedPanoramaIn(ImmersiveSource source) async {
    final path = source.path;
    final bytes = source.bytes;
    final head = path != null
        ? await readFileHead(path)
        : bytes == null
        ? null
        : Uint8List.sublistView(bytes, 0, math.min(bytes.length, versionHeadLength));
    final xmp = head == null ? null : ImmersiveXmp.findIn(head);
    return xmp is PanoramaXmp && xmp.sourceName != null && xmp.sourceSize != null && xmp.sourceSha1 != null
        ? xmp
        : null;
  }

  /// The photo [panorama] names, for a panorama chosen by itself: where its file is, the queue does not know
  ImmersiveSource _photoNamedBy(PanoramaXmp panorama) => ImmersiveSource(
    name: panorama.sourceName!,
    size: panorama.sourceSize!,
    sha1: panorama.sourceSha1!,
    bytes: Uint8List(0),
  );

  /// The photo a panorama was made from, as its packet names it: its file on this computer when the job came from one,
  /// so that the writer never takes its place
  ImmersiveSource _photoOf(ConversionSource photo, PanoramaXmp panorama) {
    final folder = photo.folder;
    return ImmersiveSource(
      name: panorama.sourceName!,
      size: panorama.sourceSize!,
      sha1: panorama.sourceSha1!,
      path: folder == null ? null : p.join(folder, photo.name),
      bytes: folder == null ? Uint8List(0) : null,
    );
  }

  /// The version of the original of [job] of its kind with its settings, null when there is none or the engine cannot
  /// tell its key before the run. A search that fails (the index closed, a drive gone to sleep) finds none: the
  /// original is fine, so the photo is converted, never failed for it.
  ///
  /// A 3D version chained after its panorama ([parent], the packet of the panorama it reads) is the same only when it
  /// was made from that panorama: its key names the depth model and the turns, not the panorama, and the 3D version of
  /// another panorama of the photo would otherwise skip this one, or be replaced while its panorama stays.
  Future<ExistingVersion?> _sameSettings(
    ConversionTools tools,
    ConversionEngine kindEngine,
    ConversionJob job,
    ImmersiveSource source,
    ImmersiveSource original,
    ConversionTarget target, {
    PanoramaXmp? parent,
  }) async {
    try {
      final key = await kindEngine.settingsKey(source, job.quarterTurns);
      final panoramaId = parent?.derivativeId;
      if (key == null || (parent != null && panoramaId == null)) {
        return null;
      }
      final rule = DerivedRuleOriginal(
        name: original.name,
        size: original.size,
        folder: job.source.folder,
        sha1: original.sha1,
      );
      bool Function(ExistingVersion version)? where;
      if (parent != null) {
        where = (version) => switch (version.xmp) {
          StereoPanoramaXmp(:final parentDerivativeId) => parentDerivativeId == panoramaId,
          _ => false,
        };
      }
      final found = await tools.finder.withSettings(
        rule,
        key,
        folder: target.folder,
        onlyInFolder: job.existing == ExistingVersionChoice.replace,
        kind: job.kind.output,
        where: where,
      );
      if (found != null) {
        return found;
      }
      // The folder of the original on a share, for Skip: a 3D version waiting to be made from this panorama reads its
      // file on this computer, so a panorama followed by one is made again rather than skipped for one on the share
      final chained = state.jobs.any((other) => other.parentId == job.id);
      if (job.source case final RemoteVersionLookup photo when job.existing == ExistingVersionChoice.skip && !chained) {
        return await photo.versionWithSettings(rule, key, kind: job.kind.output, where: where);
      }
      return null;
    } catch (error, stack) {
      _log.warning('The versions of ${job.source.name} could not be looked up', error, stack);
      return null;
    }
  }

  /// The times of the steps this computer measured, read once
  Future<Map<String, Map<String, int>>> _measuredTimings(ConversionTools tools) async {
    final kept = _measured;
    if (kept != null) {
      return kept;
    }
    try {
      return _measured = (await tools.settings?.read())?.timings ?? const {};
    } catch (error) {
      _log.warning('The times of the steps could not be read: $error');
      return _measured = const {};
    }
  }

  /// Takes in the times of the steps of a job of [kind] that ended well
  Future<void> _keepTimings(
    ConversionTools tools,
    ConversionKind kind,
    Map<ImmersiveStage, Duration> stageTimes,
  ) async {
    final store = tools.settings;
    if (store == null || stageTimes.isEmpty) {
      return;
    }
    final times = {for (final MapEntry(key: stage, value: time) in stageTimes.entries) stage.name: time.inMilliseconds};
    try {
      final kept = await store.update(
        (settings) => settings.copyWith(timings: AiTimings.merged(settings.timings, kind.name, times)),
      );
      _measured = kept.timings;
    } catch (error) {
      _log.warning('The times of the steps could not be kept: $error');
    }
  }

  /// Ends a job that made no file: cancelled, or failed with [code]; a disk full pauses the queue
  void _end(String id, ImmersiveErrorCode code, [String? message]) {
    if (code == ImmersiveErrorCode.cancelled) {
      _set(id, (job) => job.copyWith(state: ConversionState.cancelled, remaining: () => null));
      return;
    }
    _set(
      id,
      (job) => job.copyWith(state: ConversionState.failed, error: code, message: message, remaining: () => null),
    );
    if (code == ImmersiveErrorCode.diskFull && !_disposed) {
      _diskFull.add(id);
      state = state.copyWith(isPaused: true);
    }
  }

  /// What the engine reports, never going back: the root isolate and the worker of the real engine may both tell the
  /// reading of a photo that is not a JPEG, and a step or a percentage shown again lower would look like a restart.
  /// The step of a long step and the time left come with it.
  void _progress(String id, ImmersiveProgress progress, AiTimings timings, DateTime Function() now) => _set(id, (job) {
    if (!job.state.isActive) {
      return job;
    }
    final reported = ConversionState.of(progress.stage);
    final moved = reported.index > job.state.index;
    final shown = moved ? reported : job.state;
    final at = now();
    if (moved) {
      _stepStarted[id] = at;
    }
    // Only the step shown tells its own count
    final current = reported == shown;
    final started = _stepStarted[id] ?? at;
    final stage = shown.stage!;
    return job.copyWith(
      state: shown,
      perMille: math.max(job.perMille, progress.perMille.clamp(0, 1000)),
      step: current ? () => progress.step : null,
      steps: current ? () => progress.steps : null,
      remaining: () => conversionTimeLeft(
        job.kind,
        stage,
        timings: timings,
        inStage: at.difference(started),
        stageLeft: current ? progress.remaining : null,
      ),
    );
  });

  void _set(String id, ConversionJob Function(ConversionJob job) change) {
    if (_disposed) {
      return;
    }
    state = state.copyWith(jobs: [for (final job in state.jobs) job.id == id ? change(job) : job]);
  }
}

/// The fields of the original with the Software of the app: the file is made by it, whatever made the original
/// ("Adobe Lightroom" would be wrong on it)
ImmersiveExif _withSoftware(ImmersiveExif exif, String? software) => software == null
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
