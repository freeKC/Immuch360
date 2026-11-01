// COLMAP 4.2.1 on the processor, the poses of the cameras of a splat scene (plan 2026-11-01, sections 2.2, 2.4 and 3, lot
// SP4; design engineering-first of 1 November 2026, sections 4.4 and 4.5; measure of 1 November 2026, section 3). Five
// commands, each one child process started through SidecarRun (process/sidecar_run.dart), in the work folder of the job
// (splat_work_folder.dart), given by an ASCII path:
//  - feature_extractor: SIFT on the processor, the images at 1 024 pixels at most (the same poses as the full
//    definition, 2.3 times faster in the measure), one camera per folder of photos (one folder per group of cameras,
//    lot SP5), one camera for the frames of a video; its threads chosen from the memory free now, (free - 1.5 GiB) /
//    307 MiB, from 2 to the processors less two: the measure saw it crash with 0xC0000005 at 24 threads and 2.9 GB free;
//  - exhaustive_matcher for photos (200 at most), sequential_matcher without loop detection for a video (the
//    vocabulary tree of COLMAP has no written licence), the processors less two;
//  - mapper into colmap/sparse, which must be there first, the processors less two; then the largest of its models
//    (colmap_model.dart), refused under SplatV1.minPlaced images or SplatV1.minPlacedShare of them (notEnoughOverlap,
//    "placed/all"), said partial under SplatV1.partialShare;
//  - model_orientation_aligner by IMAGE-ORIENTATION into dataset/sparse/0, the model upright (+y down), which Brush and
//    the headset read; then the model read whole, its floor found.
// Every argument is one the help of our build lists (the fixtures colmap_help/ of lot SP1), with --log_target stderr:
// the default, stderr_and_file, leaves a glog file per run in %TEMP% (112 of them after the measure of 1 November). A
// command that crashes for want of memory (0xC0000005 and the other NTSTATUS of a crash on Windows, SIGSEGV, SIGABRT,
// SIGBUS or SIGKILL elsewhere) starts again with half of its threads, 2 at least; one that crashes at 2 is outOfMemory.
// The extraction and the matching start again where they stopped (COLMAP skips what its database already holds); the
// mapper starts again from an empty sparse/. Its progress, read from glog on its error output as the measure logged it,
// never goes back: "Processed file [87/150]" (features), "Processing block [4/9, 2/9]" (blocks of the exhaustive
// matching), "Processing image [120/150]" (the sequential matching), "Registering image #66 (num_reg_frames=120)" (the
// image is the 121st placed; a second model starts again from 2, the count kept is the largest).

import 'dart:io';
import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/process/sidecar_run.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_model.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

/// The program of COLMAP in its folder (`engines/colmap-cpu-*/` of the AI components)
String colmapIn(String folder, {bool? windows}) =>
    p.join(folder, (windows ?? Platform.isWindows) ? 'colmap.exe' : 'colmap');

/// The texts of a memory too short that COLMAP may write before it ends (std::bad_alloc of libstdc++ and of the
/// runtime of Visual C++)
const colmapOutOfMemoryTexts = ['std::bad_alloc', 'bad allocation'];

/// COLMAP to its run
const colmapProgram = SidecarProgram(
  name: 'COLMAP',
  failed: ImmersiveErrorCode.posesFailed,
  stalled: ImmersiveErrorCode.posesStalled,
  outOfMemory: ImmersiveErrorCode.outOfMemory,
  outOfMemoryTexts: colmapOutOfMemoryTexts,
);

/// The exit codes of a crash for want of memory: on Windows the NTSTATUS of an access violation (0xC0000005, seen in
/// the measure), of a memory refused (0xC0000017, 0xC000012D), of a fail fast (0xC0000409, abort after an exception
/// nothing caught) and of a stack overflow (0xC00000FD); elsewhere SIGSEGV, SIGABRT, SIGBUS, and SIGKILL (the OOM
/// killer of Linux), as Dart gives a signal: negative
const colmapWindowsCrashCodes = {-1073741819, -1073741801, -1073741523, -1073740791, -1073741571};
const colmapPosixCrashCodes = {-11, -6, -7, -9};

/// Whether COLMAP ending with [code] crashed for want of memory
bool colmapCrashed(int code, {bool? windows}) =>
    ((windows ?? Platform.isWindows) ? colmapWindowsCrashCodes : colmapPosixCrashCodes).contains(code);

/// The threads of the extraction: (memory free - SplatV1.colmapMemoryReserve) / SplatV1.colmapMemoryPerThread, from
/// SplatV1.colmapMinThreads to the processors less two; the processors less two when the free memory is not known
int colmapThreadsFor({required int? available, required int processors}) {
  final most = math.max(SplatV1.colmapMinThreads, processors - 2);
  if (available == null) {
    return most;
  }
  final byMemory = (available - SplatV1.colmapMemoryReserve) ~/ SplatV1.colmapMemoryPerThread;
  return byMemory.clamp(SplatV1.colmapMinThreads, most);
}

/// The threads of the matching and of the mapper: the processors less two, 2 at least
int colmapCommonThreadsFor(int processors) => math.max(SplatV1.colmapMinThreads, processors - 2);

/// The threads after a crash at [threads]: half, 2 at least; null when it crashed at 2 already
int? colmapFewerThreads(int threads) =>
    threads <= SplatV1.colmapMinThreads ? null : math.max(SplatV1.colmapMinThreads, threads ~/ 2);

/// The arguments of the extraction, frozen
List<String> colmapExtractArguments({
  required String database,
  required String images,
  required int threads,
  required bool video,
  int maxImageSize = SplatV1.siftMaxImageSize,
}) => [
  'feature_extractor',
  '--database_path',
  database,
  '--image_path',
  images,
  '--ImageReader.camera_model',
  'SIMPLE_RADIAL',
  if (video) '--ImageReader.single_camera' else '--ImageReader.single_camera_per_folder',
  '1',
  '--FeatureExtraction.use_gpu',
  '0',
  '--FeatureExtraction.max_image_size',
  '$maxImageSize',
  '--FeatureExtraction.num_threads',
  '$threads',
  '--log_target',
  'stderr',
];

/// The arguments of the matching, frozen: exhaustive for photos, sequential without loop detection for a video
List<String> colmapMatchArguments({required String database, required int threads, required bool video}) => [
  if (video) 'sequential_matcher' else 'exhaustive_matcher',
  '--database_path',
  database,
  '--FeatureMatching.use_gpu',
  '0',
  '--FeatureMatching.num_threads',
  '$threads',
  if (video) ...['--SequentialMatching.loop_detection', '0'],
  '--log_target',
  'stderr',
];

/// The arguments of the mapper, frozen
List<String> colmapMapperArguments({
  required String database,
  required String images,
  required String output,
  required int threads,
}) => [
  'mapper',
  '--database_path',
  database,
  '--image_path',
  images,
  '--output_path',
  output,
  '--Mapper.num_threads',
  '$threads',
  '--log_target',
  'stderr',
];

/// The arguments of the alignment upright, frozen
List<String> colmapAlignArguments({required String images, required String input, required String output}) => [
  'model_orientation_aligner',
  '--image_path',
  images,
  '--input_path',
  input,
  '--output_path',
  output,
  '--method',
  'IMAGE-ORIENTATION',
  '--log_target',
  'stderr',
];

final _processedFile = RegExp(r'\] Processed file \[(\d+)/(\d+)\]');
final _block = RegExp(r'\] Processing block \[(\d+)/(\d+), (\d+)/(\d+)\]');
final _sequential = RegExp(r'\] Processing image \[(\d+)/(\d+)\]');
final _registered = RegExp(r'\] Registering image #\d+ \(num_reg_frames=(\d+)\)');
final _initialPair = RegExp(r'\] Registering initial image pair #\d+ and #\d+');

/// Where COLMAP is: the step, what is done of it and of how much
class ColmapProgress {
  const ColmapProgress(this.stage, this.done, this.total);

  /// features, matching or mapping
  final ImmersiveStage stage;
  final int done;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is ColmapProgress && other.stage == stage && other.done == done && other.total == total;

  @override
  int get hashCode => Object.hash(stage, done, total);

  @override
  String toString() => 'ColmapProgress(${stage.name} $done of $total)';
}

/// The lines of one command read into its progress, which never goes back
class ColmapLog {
  ColmapLog(this.stage, {required this.images});

  final ImmersiveStage stage;

  /// The images given to COLMAP: the total of the mapping
  final int images;

  var _done = 0;
  var _total = 0;

  /// The progress [line] brings, null when it brings none (another line, or a count already passed)
  ColmapProgress? read(String line) {
    final (done, total) = switch (stage) {
      ImmersiveStage.features => _pair(_processedFile.firstMatch(line)),
      ImmersiveStage.matching => _matching(line),
      ImmersiveStage.mapping => _mapping(line),
      _ => (null, null),
    };
    if (done == null || total == null || total <= 0) {
      return null;
    }
    if (done <= _done && total == _total) {
      return null;
    }
    _done = math.max(done, total == _total ? _done : 0);
    _total = total;
    return ColmapProgress(stage, math.min(_done, total), total);
  }

  (int?, int?) _pair(RegExpMatch? match) =>
      match == null ? (null, null) : (int.parse(match.group(1)!), int.parse(match.group(2)!));

  (int?, int?) _matching(String line) {
    final block = _block.firstMatch(line);
    if (block != null) {
      final b = int.parse(block.group(3)!);
      final blocks = int.parse(block.group(4)!);
      return ((int.parse(block.group(1)!) - 1) * blocks + b, int.parse(block.group(2)!) * blocks);
    }
    return _pair(_sequential.firstMatch(line));
  }

  (int?, int?) _mapping(String line) {
    final registered = _registered.firstMatch(line);
    if (registered != null) {
      return (int.parse(registered.group(1)!) + 1, images);
    }
    return _initialPair.hasMatch(line) ? (2, images) : (null, null);
  }
}

/// What COLMAP found: the images placed of those given, the model upright, its floor, and the time of each step
class ColmapPoses {
  const ColmapPoses({
    required this.images,
    required this.placed,
    required this.model,
    required this.floor,
    required this.times,
    required this.threads,
  });

  final int images;
  final int placed;

  /// The largest model, upright (dataset/sparse/0)
  final ColmapModel model;
  final ColmapFloor? floor;

  /// The time of each command: features, matching, mapping, align (restarts included)
  final Map<String, Duration> times;

  /// The threads of the extraction at the end (fewer after a crash)
  final int threads;

  /// Fewer than SplatV1.partialShare of the images placed: the scene says so
  bool get partial => placed < images * SplatV1.partialShare;
}

/// Whether [placed] images of [images] are enough: throws notEnoughOverlap ("placed/images") when they are fewer than
/// SplatV1.minPlaced or than SplatV1.minPlacedShare of them
void checkPlaced(int placed, int images) {
  if (placed < SplatV1.minPlaced || placed < images * SplatV1.minPlacedShare) {
    throw BackendException(ImmersiveErrorCode.notEnoughOverlap, splatCountsMessage(placed, images));
  }
}

/// The poses of the cameras of a splat scene by COLMAP (see the top of this file)
class ColmapRunner {
  ColmapRunner({
    required this.runner,
    required this.colmap,
    MemoryProbe? memory,
    int? processors,
    this.stallTimeout = SplatV1.colmapSilence,
    this.pollInterval = const Duration(milliseconds: 200),
    this.environment = const {},
    this.maxImageSize = SplatV1.siftMaxImageSize,
    bool? windows,
    Duration Function()? elapsed,
  }) : memory = memory ?? const SystemMemoryProbe(),
       processors = processors ?? Platform.numberOfProcessors,
       _windows = windows ?? Platform.isWindows,
       _elapsed = elapsed ?? sidecarStopwatch();

  final ProcessRunner runner;

  /// colmap.exe, or colmap on Linux
  final String colmap;
  final MemoryProbe memory;
  final int processors;
  final Duration stallTimeout;
  final Duration pollInterval;
  final Map<String, String> environment;
  final int maxImageSize;
  final bool _windows;
  final Duration Function() _elapsed;

  /// The poses of the [images] images in the work folder [work] (photos, or the frames of a [video]); throws a
  /// BackendException: cancelled, posesFailed, posesStalled, outOfMemory, notEnoughOverlap
  Future<ColmapPoses> poses(
    SplatWorkFolder work, {
    required int images,
    required bool video,
    required NativeCancelFlag cancel,
    void Function(ColmapProgress progress)? onProgress,
  }) async {
    final root = asciiPathOf(work.root, isWindows: _windows);
    if (root == null) {
      throw BackendException(
        ImmersiveErrorCode.posesFailed,
        'The work folder ${work.root.path} has no path COLMAP can read (not ASCII, no short name)',
      );
    }
    final at = SplatWorkFolder(Directory(root));
    for (final folder in [at.sparse, at.aligned]) {
      if (folder.existsSync()) {
        folder.deleteSync(recursive: true);
      }
    }
    if (at.database.existsSync()) {
      at.database.deleteSync();
    }
    at.colmap.createSync(recursive: true);
    at.logs.createSync(recursive: true);
    final times = <String, Duration>{};
    var threads = colmapThreadsFor(available: memory.read().available, processors: processors);
    final common = colmapCommonThreadsFor(processors);

    threads = await _command(
      ImmersiveStage.features,
      'features',
      threads,
      (count) => colmapExtractArguments(
        database: at.database.path,
        images: at.images.path,
        threads: count,
        video: video,
        maxImageSize: maxImageSize,
      ),
      at,
      images: images,
      cancel: cancel,
      onProgress: onProgress,
      times: times,
    );
    await _command(
      ImmersiveStage.matching,
      'matching',
      common,
      (count) => colmapMatchArguments(database: at.database.path, threads: count, video: video),
      at,
      images: images,
      cancel: cancel,
      onProgress: onProgress,
      times: times,
    );
    try {
      await _command(
        ImmersiveStage.mapping,
        'mapping',
        common,
        (count) {
          if (at.sparse.existsSync()) {
            at.sparse.deleteSync(recursive: true);
          }
          at.sparse.createSync(recursive: true);
          return colmapMapperArguments(
            database: at.database.path,
            images: at.images.path,
            output: at.sparse.path,
            threads: count,
          );
        },
        at,
        images: images,
        cancel: cancel,
        onProgress: onProgress,
        times: times,
      );
    } on SidecarFailure catch (failure) {
      // No initial pair, no model: no two photos could be matched
      if (failure.code == ImmersiveErrorCode.posesFailed && largestColmapModel(at.sparse) == null) {
        throw BackendException(ImmersiveErrorCode.notEnoughOverlap, splatCountsMessage(0, images));
      }
      rethrow;
    }
    final largest = largestColmapModel(at.sparse);
    final placed = largest?.placed ?? 0;
    checkPlaced(placed, images);
    at.aligned.createSync(recursive: true);
    await _command(
      null,
      'align',
      1,
      (_) => colmapAlignArguments(images: at.images.path, input: largest!.folder.path, output: at.aligned.path),
      at,
      images: images,
      cancel: cancel,
      times: times,
    );
    final ColmapModel model;
    try {
      model = ColmapModel.read(at.aligned);
    } on FormatException catch (error) {
      throw BackendException(
        ImmersiveErrorCode.posesFailed,
        'The model COLMAP aligned does not read: ${error.message}',
      );
    }
    return ColmapPoses(
      images: images,
      placed: model.images.length,
      model: model,
      floor: model.floor(),
      times: times,
      threads: threads,
    );
  }

  /// Runs one command to its end, again with fewer threads after a crash; returns the threads it ended with
  Future<int> _command(
    ImmersiveStage? stage,
    String name,
    int threads,
    List<String> Function(int threads) arguments,
    SplatWorkFolder at, {
    required int images,
    required NativeCancelFlag cancel,
    required Map<String, Duration> times,
    void Function(ColmapProgress progress)? onProgress,
  }) async {
    final started = _elapsed();
    final log = stage == null ? null : ColmapLog(stage, images: images);
    var count = threads;
    while (true) {
      final run = SidecarRun(
        runner: runner,
        program: colmapProgram,
        launch: ProcessLaunch(
          executable: colmap,
          arguments: arguments(count),
          workingDirectory: at.colmap.path,
          environment: environment,
        ),
        cancel: cancel,
        elapsed: _elapsed,
        stallTimeout: stallTimeout,
        pollInterval: pollInterval,
        log: at.logOf('colmap-$name'),
        onLine: (line, {required isError}) {
          final progress = log?.read(line);
          if (progress != null) {
            onProgress?.call(progress);
          }
          return null;
        },
      );
      try {
        await run.run();
        times[name] = _elapsed() - started;
        return count;
      } on SidecarFailure catch (failure) {
        final code = failure.exitCode;
        if (code == null || !colmapCrashed(code, windows: _windows)) {
          rethrow;
        }
        final fewer = colmapFewerThreads(count);
        if (fewer == null) {
          throw BackendException(
            ImmersiveErrorCode.outOfMemory,
            'COLMAP ($name) crashed with $code at $count threads: ${run.tail}',
          );
        }
        count = fewer;
      }
    }
  }
}
