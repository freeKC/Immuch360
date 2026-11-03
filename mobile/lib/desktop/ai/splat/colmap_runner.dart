// COLMAP 4.2.1 on the processor, the poses of the cameras of a splat scene (plan 2026-11-01, sections 2.2, 2.4 and 3, lot
// SP4; design engineering-first of 1 November 2026, sections 4.4 and 4.5; measure of 1 November 2026, section 3). Five
// commands, each one child process started through SidecarRun (process/sidecar_run.dart), in the work folder of the job
// (splat_work_folder.dart), given by an ASCII path:
//  - feature_extractor: SIFT on the processor, the images at 1 024 pixels at most (the same poses as the full
//    definition, 2.3 times faster in the measure), one camera per folder of photos (one folder per group of cameras,
//    lot SP5), one camera for the frames of a video; its threads chosen from the memory free now, (free - 1.5 GiB) /
//    307 MiB, from 2 to the processors less two: the measure saw it crash with 0xC0000005 at 24 threads and 2.9 GB free;
//  - exhaustive_matcher for photos (200 at most) and for a video of up to SplatV1.maxExhaustiveFrames frames; a longer
//    video by matches_importer, the list of its pairs written to colmap/pairs.txt first ([colmapVideoPairs]); the
//    processors less two. Until lot SPF1 a video was matched by sequential_matcher without loop detection (the
//    vocabulary tree of COLMAP has no written licence), which tries the frames 1, 2, 4 ... 128 apart and never ties two
//    turns around an object together: 68 of FreeKC's 139 frames placed on 3 November, 129 now (diag-2026-11-03.md);
//  - mapper into colmap/sparse, which must be there first, the processors less two, an image placed from
//    SplatV1.absPoseMinInliers inliers; then the largest of its models (colmap_model.dart), refused under
//    SplatV1.minPlaced images or SplatV1.minPlacedShare of them (notEnoughOverlap, "placed/all"), said incomplete
//    under SplatV1.incompleteShare and partial under SplatV1.partialShare;
//  - model_orientation_aligner by IMAGE-ORIENTATION into dataset/sparse/0, the model upright (+y down), which Brush and
//    the headset read; then the model read whole, the centres of its cameras for the scale (splat_scale.dart, lot SP3,
//    which finds the floor).
// Every argument is one the help of our build lists (the fixtures colmap_help/ of lot SP1), with --log_target stderr:
// the default, stderr_and_file, leaves a glog file per run in %TEMP% (112 of them after the measure of 1 November).
// Every message of a failure names the command of COLMAP that failed and carries the end of its output: "COLMAP
// (exhaustive_matcher) wrote nothing for 600 s and was stopped; its last lines: ..." (the first test build lost the
// step of a silence of 600 s, 2 November). How a command that did not end with 0 ended ([colmapEndOf]):
//  - a crash for want of memory (an access violation, measured at 24 threads, or a memory refused on Windows; SIGSEGV,
//    SIGBUS, or SIGKILL from the OOM killer elsewhere) starts again with half of its threads, 2 at least; one that
//    crashes at 2 is outOfMemory;
//  - an exception nothing caught: COLMAP throws on a check that fails (THROW_CHECK and its kin: a folder missing, a
//    database it cannot read), and on a memory refused (std::bad_alloc). Our build then ends with 0xC0000409 and not a
//    word on Windows (measured on 1 November: the aligner writing into a folder that is not there, 4.1 s), with
//    SIGABRT after "terminate called after throwing an instance of '...'" of libstdc++ elsewhere. It counts as a want
//    of memory only after a line said std::bad_alloc; otherwise it is posesFailed with the end of the output, after one
//    more try with half the threads on Windows alone, where a std::bad_alloc says nothing either;
//  - anything else is posesFailed with the end of the output, at once.
// The alignment, on one thread, is never started again. The extraction and the matching start again where they
// stopped (COLMAP skips what its database already holds); the mapper starts again from an empty sparse/. A file of the
// work folder that cannot be made or removed is posesFailed (diskFull when the disk is full). The progress, read from
// glog on the error output as the measure logged it, never goes back: "Processed file [87/150]" (features), "Processing
// block [4/9, 2/9]" (blocks of the exhaustive matching), "Processing block [2/3]" (blocks of 1 225 pairs of a list),
// "Registering image #66 (num_reg_frames=120)" (the image is the 121st placed; a second model starts again from 2, the
// count kept is the largest).

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
/// the measure at 24 threads) and of a memory refused (0xC0000017, 0xC000012D); elsewhere SIGSEGV, SIGBUS and SIGKILL
/// (the OOM killer of Linux), as Dart gives a signal: negative
const colmapWindowsMemoryCodes = {-1073741819, -1073741801, -1073741523};
const colmapPosixMemoryCodes = {-11, -7, -9};

/// The exit codes of an exception nothing caught: the fail fast of the runtime of Visual C++ after abort()
/// (0xC0000409, our build on a check that failed, measured on 1 November), SIGABRT elsewhere
const colmapWindowsAbortCodes = {-1073740791};
const colmapPosixAbortCodes = {-6};

/// How a run of COLMAP that did not end with 0 ended (see the top of this file)
enum ColmapEnd {
  /// An error of its own, or one that is no want of memory: posesFailed
  failed,

  /// A crash for want of memory: again with half the threads
  memory,

  /// An exception nothing caught, with no word of memory
  abort,
}

/// How COLMAP ending with [code] ended; [saidOutOfMemory] when a line of its output said std::bad_alloc
ColmapEnd colmapEndOf(int code, {required bool saidOutOfMemory, bool? windows}) {
  final onWindows = windows ?? Platform.isWindows;
  if ((onWindows ? colmapWindowsMemoryCodes : colmapPosixMemoryCodes).contains(code)) {
    return ColmapEnd.memory;
  }
  if ((onWindows ? colmapWindowsAbortCodes : colmapPosixAbortCodes).contains(code)) {
    return saidOutOfMemory ? ColmapEnd.memory : ColmapEnd.abort;
  }
  return ColmapEnd.failed;
}

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

/// How the images of a job are matched (see the top of this file)
enum ColmapMatching {
  /// Every pair: exhaustive_matcher
  exhaustive,

  /// The pairs of a list ([colmapVideoPairs]): matches_importer
  pairs,
}

/// How [images] images are matched: every pair, but for a video of more than SplatV1.maxExhaustiveFrames frames
ColmapMatching colmapMatchingOf(int images, {required bool video}) =>
    video && images > SplatV1.maxExhaustiveFrames ? ColmapMatching.pairs : ColmapMatching.exhaustive;

/// The pairs of [frames] frames of a video matched by a list, by their indexes in the order of time from 0, the first
/// below the second, sorted: each frame with the 1st, 2nd, 4th ... 512th frame after it (what sequential_matcher tries
/// by default), and every frame with each SplatV1.keyFrameStep-th frame from the first (0, 10, 20...), which ties the
/// turns around an object together (q-r2 of diag-2026-11-03.md: 2 526 pairs of 139 frames)
List<(int, int)> colmapVideoPairs(int frames) {
  final pairs = <(int, int)>{};
  for (var i = 0; i < frames; i++) {
    for (var gap = 1; gap <= 512 && i + gap < frames; gap *= 2) {
      pairs.add((i, i + gap));
    }
  }
  for (var key = 0; key < frames; key += SplatV1.keyFrameStep) {
    for (var other = 0; other < frames; other++) {
      if (other != key) {
        pairs.add(other < key ? (other, key) : (key, other));
      }
    }
  }
  return pairs.toList()..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
}

/// The pairs the matching of [images] images tries ([colmapMatchingOf])
int colmapPairsOf(int images, {required bool video}) => switch (colmapMatchingOf(images, video: video)) {
  ColmapMatching.exhaustive => images * (images - 1) ~/ 2,
  ColmapMatching.pairs => colmapVideoPairs(images).length,
};

/// The images under [images] as COLMAP names them: their paths from it with "/" between folders, sorted (the frames of
/// a video in the order of time)
List<String> colmapImageNames(Directory images) {
  final root = images.absolute.path;
  return [
    for (final entity in images.absolute.listSync(recursive: true))
      if (entity is File && RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(entity.path))
        p.relative(entity.path, from: root).replaceAll(r'\', '/'),
  ]..sort();
}

/// The arguments of the matching, frozen: every pair, or the pairs of the list in the file [pairs]
List<String> colmapMatchArguments({required String database, required int threads, String? pairs}) => [
  if (pairs == null) 'exhaustive_matcher' else 'matches_importer',
  '--database_path',
  database,
  if (pairs != null) ...['--match_list_path', pairs, '--match_type', 'pairs'],
  '--FeatureMatching.use_gpu',
  '0',
  '--FeatureMatching.num_threads',
  '$threads',
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
  '--Mapper.abs_pose_min_num_inliers',
  '${SplatV1.absPoseMinInliers}',
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
final _listBlock = RegExp(r'\] Processing block \[(\d+)/(\d+)\]');
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
    return _pair(_listBlock.firstMatch(line));
  }

  (int?, int?) _mapping(String line) {
    final registered = _registered.firstMatch(line);
    if (registered != null) {
      return (int.parse(registered.group(1)!) + 1, images);
    }
    return _initialPair.hasMatch(line) ? (2, images) : (null, null);
  }
}

/// What COLMAP found: the images placed of those given, the model upright, and the time of each step
class ColmapPoses {
  const ColmapPoses({
    required this.images,
    required this.placed,
    required this.model,
    required this.times,
    required this.threads,
  });

  final int images;
  final int placed;

  /// The largest model, upright (dataset/sparse/0): the centres of its cameras ([ColmapModel.centres]) go to the scale
  /// of lot SP3 (splatScaleOf), which finds the floor
  final ColmapModel model;

  /// The time of each command: features, matching, mapping, align (restarts included)
  final Map<String, Duration> times;

  /// The threads of the extraction at the end (fewer after a crash)
  final int threads;

  /// Fewer than SplatV1.partialShare of the images placed: the scene says so
  bool get partial => placed < images * SplatV1.partialShare;

  /// Fewer than SplatV1.incompleteShare of them: the scene is made all the same, said maybe incomplete
  bool get incomplete => placed < images * SplatV1.incompleteShare;
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
  /// BackendException: cancelled, posesFailed, posesStalled, outOfMemory, notEnoughOverlap, diskFull
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
    _files(() {
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
    });
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
    // A long video by the list of its pairs, by the names of its frames
    final listed = colmapMatchingOf(images, video: video) == ColmapMatching.pairs;
    if (listed) {
      _files(() {
        final names = colmapImageNames(at.images);
        at.pairs.writeAsStringSync(
          [for (final (i, j) in colmapVideoPairs(names.length)) '${names[i]} ${names[j]}\n'].join(),
          flush: true,
        );
      });
    } else {
      _files(() {
        if (at.pairs.existsSync()) {
          at.pairs.deleteSync();
        }
      });
    }
    await _command(
      ImmersiveStage.matching,
      'matching',
      common,
      (count) => colmapMatchArguments(database: at.database.path, threads: count, pairs: listed ? at.pairs.path : null),
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
          _files(() {
            if (at.sparse.existsSync()) {
              at.sparse.deleteSync(recursive: true);
            }
            at.sparse.createSync(recursive: true);
          });
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
      if (failure.code == ImmersiveErrorCode.posesFailed && _files(() => largestColmapModel(at.sparse)) == null) {
        throw BackendException(ImmersiveErrorCode.notEnoughOverlap, splatCountsMessage(0, images));
      }
      rethrow;
    }
    final largest = _files(() => largestColmapModel(at.sparse));
    final placed = largest?.placed ?? 0;
    checkPlaced(placed, images);
    _files(() => at.aligned.createSync(recursive: true));
    await _command(
      null,
      'align',
      1,
      (_) => colmapAlignArguments(images: at.images.path, input: largest!.folder.path, output: at.aligned.path),
      at,
      images: images,
      cancel: cancel,
      times: times,
      again: false,
    );
    final ColmapModel model;
    try {
      model = _files(() => ColmapModel.read(at.aligned));
    } on FormatException catch (error) {
      throw BackendException(
        ImmersiveErrorCode.posesFailed,
        'The model COLMAP aligned does not read: ${error.message}',
      );
    }
    return ColmapPoses(images: images, placed: model.images.length, model: model, times: times, threads: threads);
  }

  /// [action] on the files of the work folder; a file that cannot be made, read or removed is posesFailed, or diskFull
  T _files<T>(T Function() action) {
    try {
      return action();
    } on FileSystemException catch (error) {
      throw splatFileFailure(error, 'COLMAP', ImmersiveErrorCode.posesFailed, windows: _windows);
    }
  }

  /// Runs one command to its end, again with fewer threads after a crash for want of memory unless [again] is false
  /// (see the top of this file); returns the threads it ended with
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
    bool again = true,
  }) async {
    final started = _elapsed();
    final log = stage == null ? null : ColmapLog(stage, images: images);
    var count = threads;
    var abortedOnce = false;
    while (true) {
      final launched = arguments(count);
      // The command in the messages: "COLMAP (exhaustive_matcher) ended with 1: ..."
      final label = 'COLMAP (${launched.first})';
      final run = SidecarRun(
        runner: runner,
        program: colmapProgram,
        label: label,
        launch: ProcessLaunch(
          executable: colmap,
          arguments: launched,
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
        if (code == null) {
          rethrow;
        }
        final end = colmapEndOf(
          code,
          saidOutOfMemory: failure.code == ImmersiveErrorCode.outOfMemory,
          windows: _windows,
        );
        final fewer = again ? colmapFewerThreads(count) : null;
        // Our build may end before its first line (a name outside the code page of Windows, 2 November)
        final tail = run.tail.isEmpty ? 'no output' : run.tail;
        switch (end) {
          case ColmapEnd.failed:
            rethrow;
          case ColmapEnd.memory:
            if (fewer == null) {
              throw BackendException(
                ImmersiveErrorCode.outOfMemory,
                '$label crashed with $code at $count thread${count == 1 ? '' : 's'}: $tail',
              );
            }
          case ColmapEnd.abort:
            if (fewer == null || abortedOnce || !_windows) {
              throw BackendException(ImmersiveErrorCode.posesFailed, '$label aborted with $code: $tail');
            }
            abortedOnce = true;
        }
        count = fewer;
      }
    }
  }
}
