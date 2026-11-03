// The runner of COLMAP (lib/desktop/ai/splat/colmap_runner.dart, lot SP4) with the fake runner: its frozen arguments
// against the help of our build (fixtures colmap_help/ of lot SP1, matches_importer.txt added by lot SPF1 from the
// colmap.exe of the test build T1), the matching of a video (every pair up to 200 frames, a list of pairs beyond: lot
// SPF1, after the 68 of 139 frames of 3 November), the threads chosen from the memory free, the crash
// for want of memory and the start again with half the threads, a check of COLMAP that fails (an exception nothing
// caught: 0xC0000409 with no word on Windows, SIGABRT after the words of libstdc++ elsewhere) told from a crash for want
// of memory, the alignment never started again, the progress read from the logs of the measure of 1 November (fixtures
// splat/logs/), the five commands of a job in order, the largest model, the thresholds of the poses, the failures, the
// silence of 600 s, the cancel flag, a work folder whose path is not ASCII, and one that refuses its files. The same
// runner against the compiled fake COLMAP is splat_runners_real_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_colmap_model.dart';
import '../fakes/fake_process_runner.dart';

const _gib = 1024 * 1024 * 1024;

class _Memory implements MemoryProbe {
  const _Memory(this.available);

  final int? available;

  @override
  MemoryFacts read() => MemoryFacts(physical: 16 * _gib, available: available);
}

/// The options the help of our build lists for [command], with "--"
Set<String> _helpOptions(String command) {
  final text = File(p.join('test', 'fixtures', 'ai_immersive', 'colmap_help', '$command.txt')).readAsLinesSync();
  return {
    for (final line in text)
      for (final match in RegExp(r'^\s+(--[A-Za-z_.0-9]+)').allMatches(line)) match.group(1)!,
  };
}

/// A log of the measure, its lines on the error output as glog writes them
List<(String, {bool isError})> _measured(String name) => [
  for (final line in File(p.join('test', 'fixtures', 'splat', 'logs', name)).readAsLinesSync()) (line, isError: true),
];

/// What libstdc++ writes when an exception of [type] that nothing caught ends a program, before its SIGABRT
List<(String, {bool isError})> _terminate(String type, String what) => [
  ("terminate called after throwing an instance of '$type'", isError: true),
  ('  what():  $what', isError: true),
];

/// The threads each launch of [command] was given
List<String> _threadsOf(List<ProcessLaunch> launches, String command, String option) => [
  for (final launch in launches.where((l) => l.arguments.first == command))
    launch.arguments[launch.arguments.indexOf(option) + 1],
];

/// glog lines of the mapper placing [placed] images, its first pair then one by one
List<(String, {bool isError})> _mapping(int placed) => [
  ('I20261101 12:39:37.126542 31136 incremental_pipeline.cc:465] Finding good initial image pair', isError: true),
  (
    'I20261101 12:39:37.316517 31136 incremental_pipeline.cc:492] Registering initial image pair #4 and #7',
    isError: true,
  ),
  for (var k = 2; k < placed; k++)
    (
      'I20261101 12:39:37.375357 31136 incremental_pipeline.cc:620] Registering image #${k + 1} (num_reg_frames=$k)',
      isError: true,
    ),
];

/// The fake runner, writing what COLMAP writes: the models of the mapper ([models], their sizes) when it ends well,
/// and the aligned model
class _ColmapRunner implements ProcessRunner {
  _ColmapRunner(this.scripts, {this.models = const [150]});

  /// The scripts of each command, in turn, the last one again
  final Map<String, List<FakeProcessScript>> scripts;
  final List<int> models;
  final launches = <ProcessLaunch>[];
  final processes = <FakeRunningProcess>[];
  var _pid = 7000;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    launches.add(launch);
    final command = launch.arguments.first;
    final list = scripts[command] ?? [const FakeProcessScript()];
    final script = list.length > 1 ? list.removeAt(0) : list.single;
    String option(String name) => launch.arguments[launch.arguments.indexOf('--$name') + 1];
    if (command == 'mapper' && script.exitCode < 0) {
      // A crashed mapper may leave a model half written
      File(p.join(option('output_path'), '0', 'leftover'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    if (script.exitCode == 0 && !script.hangs) {
      if (command == 'mapper') {
        for (var m = 0; m < models.length; m++) {
          _model(models[m]).writeTo(Directory(p.join(option('output_path'), '$m')));
        }
      } else if (command == 'model_orientation_aligner') {
        final input = Directory(option('input_path'));
        for (final file in input.listSync().whereType<File>()) {
          file.copySync(p.join(option('output_path'), p.basename(file.path)));
        }
      }
    }
    final process = FakeRunningProcess(++_pid, launch, script);
    processes.add(process);
    return process;
  }

  static FakeColmapModel _model(int count) => FakeColmapModel.circle(
    names: [for (var k = 1; k <= count; k++) 'cam0/${'$k'.padLeft(6, '0')}.jpg'],
    ids: [for (var k = 1; k <= count; k++) k],
    cameras: const [
      FakeColmapCamera(id: 1, width: 1024, height: 768, params: [1228, 512, 384, 0]),
    ],
    cameraOf: (_) => 1,
  );
}

void main() {
  late Directory folder;
  late SplatWorkFolder work;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('colmap-runner-');
    work = SplatWorkFolder(folder);
    work.images.createSync(recursive: true);
    cancel = NativeCancelFlag();
  });
  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  ColmapRunner colmap(
    ProcessRunner runner, {
    int? available = 4 * _gib,
    int processors = 16,
    bool windows = false,
    Duration Function()? elapsed,
  }) => ColmapRunner(
    runner: runner,
    colmap: '/engines/colmap-cpu-linux-x64/colmap',
    memory: _Memory(available),
    processors: processors,
    windows: windows,
    elapsed: elapsed,
  );

  group('the arguments', () {
    test('are frozen: every option is one the help of our build lists for its command, with its value', () {
      final commands = {
        'feature_extractor': colmapExtractArguments(database: 'D', images: 'I', threads: 7, video: false),
        'feature_extractor (video)': colmapExtractArguments(database: 'D', images: 'I', threads: 7, video: true),
        'exhaustive_matcher': colmapMatchArguments(database: 'D', threads: 14),
        'matches_importer': colmapMatchArguments(database: 'D', threads: 14, pairs: 'P'),
        'mapper': colmapMapperArguments(database: 'D', images: 'I', output: 'S', threads: 14),
        'model_orientation_aligner': colmapAlignArguments(images: 'I', input: 'S/0', output: 'A'),
      };
      for (final MapEntry(key: name, value: arguments) in commands.entries) {
        final command = arguments.first;
        expect(name, startsWith(command));
        final listed = _helpOptions(command);
        expect(listed, isNotEmpty, reason: command);
        for (final argument in arguments.skip(1).where((a) => a.startsWith('--'))) {
          expect(listed, contains(argument), reason: '$argument of $command');
        }
        // Every option has its value, and the logs go to the error output only, never to a file of %TEMP%
        expect(arguments.skip(1).length.isEven, isTrue, reason: name);
        expect(arguments.sublist(arguments.length - 2), ['--log_target', 'stderr']);
      }
      expect(commands['feature_extractor'], [
        'feature_extractor',
        '--database_path',
        'D',
        '--image_path',
        'I',
        '--ImageReader.camera_model',
        'SIMPLE_RADIAL',
        '--ImageReader.single_camera_per_folder',
        '1',
        '--FeatureExtraction.use_gpu',
        '0',
        '--FeatureExtraction.max_image_size',
        '1024',
        '--FeatureExtraction.num_threads',
        '7',
        '--log_target',
        'stderr',
      ]);
      expect(commands['feature_extractor (video)'], containsAllInOrder(['--ImageReader.single_camera', '1']));
      expect(commands['feature_extractor (video)'], isNot(contains('--ImageReader.single_camera_per_folder')));
      expect(commands['exhaustive_matcher'], [
        'exhaustive_matcher',
        '--database_path',
        'D',
        '--FeatureMatching.use_gpu',
        '0',
        '--FeatureMatching.num_threads',
        '14',
        '--log_target',
        'stderr',
      ]);
      // A list of pairs, never the vocabulary tree of sequential_matcher, which has no written licence
      expect(commands['matches_importer'], [
        'matches_importer',
        '--database_path',
        'D',
        '--match_list_path',
        'P',
        '--match_type',
        'pairs',
        '--FeatureMatching.use_gpu',
        '0',
        '--FeatureMatching.num_threads',
        '14',
        '--log_target',
        'stderr',
      ]);
      // An image placed from 15 inliers of its pose, not COLMAP's 30 (the diagnosis of 3 November: 123 to 129 of 139)
      expect(
        commands['mapper'],
        containsAllInOrder([
          '--output_path',
          'S',
          '--Mapper.num_threads',
          '14',
          '--Mapper.abs_pose_min_num_inliers',
          '15',
        ]),
      );
      expect(commands['model_orientation_aligner'], containsAllInOrder(['--method', 'IMAGE-ORIENTATION']));
      expect(colmapIn('/e', windows: true), p.join('/e', 'colmap.exe'));
      expect(colmapIn('/e', windows: false), p.join('/e', 'colmap'));
    });

    test('a video is matched pair by pair up to 200 frames; beyond, by its list: the 2 526 pairs of the diagnosis', () {
      expect(colmapMatchingOf(150, video: false), ColmapMatching.exhaustive);
      expect(colmapMatchingOf(200, video: false), ColmapMatching.exhaustive);
      expect(colmapMatchingOf(139, video: true), ColmapMatching.exhaustive);
      expect(colmapMatchingOf(200, video: true), ColmapMatching.exhaustive);
      expect(colmapMatchingOf(201, video: true), ColmapMatching.pairs);
      expect(colmapMatchingOf(250, video: true), ColmapMatching.pairs);
      expect(SplatV1.maxExhaustiveFrames, 200);

      // The pairs q-r2 of the diagnosis (pairs-r2.txt): 125 of 139 frames placed with the mapper at 15 inliers
      final pairs = colmapVideoPairs(139);
      expect(pairs, hasLength(2526));
      expect(pairs.toSet(), hasLength(2526));
      expect(pairs.every((pair) => pair.$1 < pair.$2 && pair.$2 < 139), isTrue);
      expect(pairs, orderedEquals([...pairs]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2)));
      // Each frame with the 1st, 2nd, 4th ... 128th after it
      expect(pairs, containsAll([(0, 1), (0, 2), (0, 4), (0, 128), (5, 6), (5, 7), (5, 9), (5, 69), (137, 138)]));
      // Every frame with the key frames 0, 10, 20 ... 130: the turns around an object tied together
      expect(pairs, containsAll([(0, 3), (3, 10), (10, 137), (1, 130), (130, 138), (57, 60)]));
      // Neither a power of two apart nor a key frame
      expect(pairs, isNot(contains((1, 4))));
      expect(pairs, isNot(contains((11, 17))));
      expect(colmapVideoPairs(250), hasLength(7322));
      expect(colmapVideoPairs(2), [(0, 1)]);
      expect(colmapVideoPairs(1), isEmpty);

      expect(colmapPairsOf(150, video: false), 11175);
      expect(colmapPairsOf(200, video: false), 19900);
      expect(colmapPairsOf(150, video: true), 11175);
      expect(colmapPairsOf(200, video: true), 19900);
      expect(colmapPairsOf(201, video: true), 5067);
      expect(colmapPairsOf(250, video: true), 7322);
    });

    test('the extraction takes (free - 1.5 GiB) / 307 MiB threads, from 2 to the processors less two', () {
      // The crash of the measure: 24 threads with 2.9 GB free; the rule gives 4
      expect(colmapThreadsFor(available: 2900000000, processors: 24), 4);
      expect(colmapThreadsFor(available: 4 * _gib, processors: 24), 8);
      expect(colmapThreadsFor(available: 16 * _gib, processors: 24), 22);
      expect(colmapThreadsFor(available: _gib, processors: 24), 2);
      expect(colmapThreadsFor(available: null, processors: 24), 22);
      expect(colmapThreadsFor(available: 16 * _gib, processors: 2), 2);
      expect(colmapCommonThreadsFor(24), 22);
      expect(colmapCommonThreadsFor(3), 2);
    });

    test('a crash for want of memory is known by its code, an abort only by a word of memory; the threads halve', () {
      // An access violation (measured at 24 threads), a memory refused; SIGSEGV, SIGBUS, the OOM killer of Linux
      for (final code in [-1073741819, -1073741801, -1073741523]) {
        expect(colmapEndOf(code, saidOutOfMemory: false, windows: true), ColmapEnd.memory, reason: '$code');
        expect(colmapEndOf(code, saidOutOfMemory: false, windows: false), ColmapEnd.failed, reason: '$code');
      }
      for (final code in [-11, -7, -9]) {
        expect(colmapEndOf(code, saidOutOfMemory: false, windows: false), ColmapEnd.memory, reason: '$code');
      }
      // An exception nothing caught: 0xC0000409 on Windows (a check of our build that failed, measured 1 November: no
      // word), SIGABRT elsewhere; memory only when a line said std::bad_alloc
      expect(colmapEndOf(-1073740791, saidOutOfMemory: false, windows: true), ColmapEnd.abort);
      expect(colmapEndOf(-1073740791, saidOutOfMemory: true, windows: true), ColmapEnd.memory);
      expect(colmapEndOf(-6, saidOutOfMemory: false, windows: false), ColmapEnd.abort);
      expect(colmapEndOf(-6, saidOutOfMemory: true, windows: false), ColmapEnd.memory);
      // A stack overflow, and the codes COLMAP ends with itself, are its failures
      for (final code in [-1073741571, 0, 1, 2, 3, 127]) {
        expect(colmapEndOf(code, saidOutOfMemory: false, windows: true), ColmapEnd.failed, reason: '$code');
        expect(colmapEndOf(code, saidOutOfMemory: false, windows: false), ColmapEnd.failed, reason: '$code');
      }
      final steps = [24];
      for (var next = colmapFewerThreads(24); next != null; next = colmapFewerThreads(next)) {
        steps.add(next);
      }
      expect(steps, [24, 12, 6, 3, 2]);
    });
  });

  group('the lines of the measure', () {
    List<ColmapProgress> read(ImmersiveStage stage, String log, {int images = 150}) {
      final reader = ColmapLog(stage, images: images);
      return [for (final (line, isError: _) in _measured(log)) ?reader.read(line)];
    }

    test('the extraction of the 150 photos of the room: each file, to 150 of 150', () {
      expect(read(ImmersiveStage.features, 'c2s-extract.err').map((x) => x.done), [1, 2, 3, 148, 149, 150]);
      expect(
        read(ImmersiveStage.features, 'c2s-extract.err').last,
        const ColmapProgress(ImmersiveStage.features, 150, 150),
      );
    });

    test('the exhaustive matching of the room: the 9 blocks of 50 images, in their order', () {
      final blocks = read(ImmersiveStage.matching, 'c2s-match.err');
      expect(blocks.map((x) => (x.done, x.total)), [for (var k = 1; k <= 9; k++) (k, 9)]);
    });

    test('the matching of the video by its list of pairs: its blocks, in their order', () {
      final blocks = read(ImmersiveStage.matching, 'vlh-pairs-match.err');
      expect(blocks.map((x) => (x.done, x.total)), [(1, 3), (2, 3), (3, 3)]);
    });

    test('the mapping of the video: 144 placed in the first model; the second one, from 2 again, never lowers it', () {
      final placed = read(ImmersiveStage.mapping, 'vlh-map.err');
      expect(placed.first, const ColmapProgress(ImmersiveStage.mapping, 2, 150));
      expect(placed.map((x) => x.done), [2, 3, 4, 5, 6, 141, 142, 143, 144]);
      expect(placed.map((x) => x.done), orderedEquals([...placed.map((x) => x.done)]..sort()));
    });
  });

  group('the poses of a job', () {
    Map<String, List<FakeProcessScript>> scripts({int placed = 150}) => {
      'feature_extractor': [FakeProcessScript(lines: _measured('c2s-extract.err'))],
      'exhaustive_matcher': [FakeProcessScript(lines: _measured('c2s-match.err'))],
      'matches_importer': [FakeProcessScript(lines: _measured('vlh-pairs-match.err'))],
      'mapper': [FakeProcessScript(lines: _mapping(placed))],
    };

    test('150 photos: the five commands in order in the work folder, their progress, the model upright', () async {
      final runner = _ColmapRunner(scripts());
      final progress = <ColmapProgress>[];
      final poses = await colmap(
        runner,
      ).poses(work, images: 150, video: false, cancel: cancel, onProgress: progress.add);
      expect(runner.launches.map((launch) => launch.arguments.first), [
        'feature_extractor',
        'exhaustive_matcher',
        'mapper',
        'model_orientation_aligner',
      ]);
      for (final launch in runner.launches) {
        expect(launch.executable, '/engines/colmap-cpu-linux-x64/colmap');
        expect(launch.workingDirectory, work.colmap.path);
        expect(launch.lowPriority, isTrue);
      }
      final extract = runner.launches[0].arguments;
      expect(extract, containsAllInOrder(['--database_path', work.database.path, '--image_path', work.images.path]));
      // 4 GiB free: (4 - 1.5) GiB / 307 MiB = 8 threads; the matching and the mapper the processors less two
      expect(extract, containsAllInOrder(['--FeatureExtraction.num_threads', '8']));
      expect(runner.launches[1].arguments, containsAllInOrder(['--FeatureMatching.num_threads', '14']));
      expect(runner.launches[2].arguments, containsAllInOrder(['--output_path', work.sparse.path]));
      expect(
        runner.launches[3].arguments,
        containsAllInOrder(['--input_path', p.join(work.sparse.path, '0'), '--output_path', work.aligned.path]),
      );
      expect(progress.where((x) => x.stage == ImmersiveStage.features).map((x) => x.done), [1, 2, 3, 148, 149, 150]);
      expect(progress.where((x) => x.stage == ImmersiveStage.matching).map((x) => x.done), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(progress.where((x) => x.stage == ImmersiveStage.mapping).map((x) => x.done), [
        for (var k = 2; k <= 150; k++) k,
      ]);
      expect(progress.map((x) => x.stage).toSet().toList(), [
        ImmersiveStage.features,
        ImmersiveStage.matching,
        ImmersiveStage.mapping,
      ]);
      expect((poses.images, poses.placed, poses.partial, poses.threads), (150, 150, false, 8));
      expect(poses.model.images, hasLength(150));
      expect(poses.times.keys, ['features', 'matching', 'mapping', 'align']);
      expect(File(p.join(work.aligned.path, 'images.bin')).existsSync(), isTrue);
      // Every line of each command in its log, kept with the folder
      expect(work.logOf('colmap-features').readAsLinesSync(), hasLength(_measured('c2s-extract.err').length));
      expect(work.logOf('colmap-matching').readAsStringSync(), contains('Processing block [3/3, 3/3]'));
      expect(work.logOf('colmap-mapping').readAsStringSync(), contains('(num_reg_frames=149)'));
    });

    test('a video of up to 200 frames: one camera for all its frames, every pair matched, block after block', () async {
      final runner = _ColmapRunner(scripts());
      final progress = <ColmapProgress>[];
      await colmap(runner).poses(work, images: 150, video: true, cancel: cancel, onProgress: progress.add);
      expect(runner.launches[0].arguments, containsAllInOrder(['--ImageReader.single_camera', '1']));
      expect(runner.launches[1].arguments, colmapMatchArguments(database: work.database.path, threads: 14));
      expect(progress.where((x) => x.stage == ImmersiveStage.matching).map((x) => x.done), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(work.pairs.existsSync(), isFalse);
      expect(runner.launches[2].arguments, containsAllInOrder(['--Mapper.abs_pose_min_num_inliers', '15']));
    });

    test(
      'a video of 250 frames: the list of its pairs by the names of its frames, matched by matches_importer',
      () async {
        // The frames as the app writes them, one folder, numbered in the order of time
        for (var k = 1; k <= 250; k++) {
          File(p.join(work.images.path, 'video', '${'$k'.padLeft(5, '0')}.jpg')).createSync(recursive: true);
        }
        final runner = _ColmapRunner(scripts());
        final progress = <ColmapProgress>[];
        final poses = await colmap(
          runner,
        ).poses(work, images: 250, video: true, cancel: cancel, onProgress: progress.add);
        expect(runner.launches.map((launch) => launch.arguments.first), [
          'feature_extractor',
          'matches_importer',
          'mapper',
          'model_orientation_aligner',
        ]);
        expect(work.pairs.path, p.join(work.colmap.path, 'pairs.txt'));
        expect(
          runner.launches[1].arguments,
          colmapMatchArguments(database: work.database.path, threads: 14, pairs: work.pairs.path),
        );
        final lines = work.pairs.readAsLinesSync();
        expect(lines, hasLength(7322));
        expect(lines.first, 'video/00001.jpg video/00002.jpg');
        expect(lines, contains('video/00011.jpg video/00250.jpg'));
        expect(lines, contains('video/00249.jpg video/00250.jpg'));
        expect(lines.toSet(), hasLength(7322));
        expect(progress.where((x) => x.stage == ImmersiveStage.matching).map((x) => (x.done, x.total)), [
          (1, 3),
          (2, 3),
          (3, 3),
        ]);
        expect((poses.images, poses.placed), (250, 150));
      },
    );

    test('the extraction crashed at 10 threads starts again at 5, then 2; at 2 it is outOfMemory', () async {
      // 4.5 GiB free: 10 threads; a std::bad_alloc nothing caught, which libstdc++ names before its SIGABRT
      final crash = FakeProcessScript(
        lines: [..._measured('c2s-extract.err').take(20), ..._terminate('std::bad_alloc', 'std::bad_alloc')],
        exitCode: -6,
      );
      final runner = _ColmapRunner({
        ...scripts(),
        'feature_extractor': [crash, crash, FakeProcessScript(lines: _measured('c2s-extract.err'))],
      });
      final progress = <ColmapProgress>[];
      final poses = await colmap(
        runner,
        available: 4 * _gib + _gib ~/ 2,
      ).poses(work, images: 150, video: false, cancel: cancel, onProgress: progress.add);
      final threads = [
        for (final launch in runner.launches.where((l) => l.arguments.first == 'feature_extractor'))
          launch.arguments[launch.arguments.indexOf('--FeatureExtraction.num_threads') + 1],
      ];
      expect(threads, ['10', '5', '2']);
      expect(poses.threads, 2);
      // The progress of the extraction never went back across the restarts
      final features = progress.where((x) => x.stage == ImmersiveStage.features).map((x) => x.done).toList();
      expect(features, orderedEquals([...features]..sort()));
      expect(features.last, 150);

      final always = _ColmapRunner({
        ...scripts(),
        'feature_extractor': [crash],
      });
      await expectLater(
        colmap(always, available: 4 * _gib + _gib ~/ 2).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.outOfMemory)
              .having(
                (e) => e.message,
                'message',
                startsWith('COLMAP (feature_extractor) crashed with -6 at 2 threads'),
              ),
        ),
      );
      expect(always.launches.map((l) => l.arguments.first), everyElement('feature_extractor'));
      expect(always.launches, hasLength(3));
    });

    test('a check of COLMAP that fails is posesFailed with the end of its output, never outOfMemory', () async {
      // Windows: 0xC0000409 and not a word, as our build ended on a check that failed (measured 1 November); once more
      // with half the threads, since a std::bad_alloc nothing caught says nothing there either, then posesFailed
      final check = FakeProcessScript(lines: _measured('c2s-extract.err').take(20).toList(), exitCode: -1073740791);
      final windows = _ColmapRunner({
        ...scripts(),
        'feature_extractor': [check],
      });
      await expectLater(
        colmap(
          windows,
          available: 4 * _gib + _gib ~/ 2,
          windows: true,
        ).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.message, 'message', startsWith('COLMAP (feature_extractor) aborted with -1073740791: '))
              .having((e) => e.message, 'message', contains('Processed file [2/150]')),
        ),
      );
      expect(_threadsOf(windows.launches, 'feature_extractor', '--FeatureExtraction.num_threads'), ['10', '5']);
      expect(windows.launches.map((l) => l.arguments.first), everyElement('feature_extractor'));
      // Our build on a folder named outside the code page of the PC (2 November): 0xC0000409 before its first line
      final silent = _ColmapRunner({
        ...scripts(),
        'feature_extractor': [const FakeProcessScript(exitCode: -1073740791)],
      });
      await expectLater(
        colmap(silent, windows: true).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.message, 'message', 'COLMAP (feature_extractor) aborted with -1073740791: no output'),
        ),
      );

      // Elsewhere libstdc++ names the exception before its SIGABRT: a check that failed fails again, no second try
      final linux = _ColmapRunner({
        ...scripts(),
        'exhaustive_matcher': [
          FakeProcessScript(
            lines: [
              ..._measured('c2s-match.err').take(4),
              ..._terminate('std::invalid_argument', '[database.cc:1530] Check failed: ExistsImage(image_id)'),
            ],
            exitCode: -6,
          ),
        ],
      });
      await expectLater(
        colmap(linux).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.message, 'message', startsWith('COLMAP (exhaustive_matcher) aborted with -6: '))
              .having((e) => e.message, 'message', contains('Check failed: ExistsImage(image_id)')),
        ),
      );
      expect(linux.launches.map((l) => l.arguments.first), ['feature_extractor', 'exhaustive_matcher']);

      // The mapper aborted before any model: an error of COLMAP, not photos that do not overlap
      final mapper = _ColmapRunner({
        ...scripts(),
        'mapper': [
          FakeProcessScript(
            lines: [..._mapping(12), ..._terminate('std::invalid_argument', '[mapper.cc:80] Check failed: x')],
            exitCode: -6,
          ),
        ],
      }, models: const []);
      await expectLater(
        colmap(mapper).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.message, 'message', startsWith('COLMAP (mapper) aborted with -6: ')),
        ),
      );
      expect(mapper.launches.where((l) => l.arguments.first == 'mapper'), hasLength(1));
    });

    test('the alignment is never started again: an abort is posesFailed, a crash outOfMemory, each at once', () async {
      // The case measured on 1 November: the aligner writing into a folder that is not there
      const writing = 'I20261101 23:33:12.402114 24084 model.cc:886] Writing aligned reconstruction...';
      final aborted = _ColmapRunner({
        ...scripts(),
        'model_orientation_aligner': [
          const FakeProcessScript(lines: [(writing, isError: true)], exitCode: -1073740791),
        ],
      });
      await expectLater(
        colmap(aborted, windows: true).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having(
                (e) => e.message,
                'message',
                'COLMAP (model_orientation_aligner) aborted with -1073740791: $writing',
              ),
        ),
      );
      expect(aborted.launches.where((l) => l.arguments.first == 'model_orientation_aligner'), hasLength(1));

      final crashed = _ColmapRunner({
        ...scripts(),
        'model_orientation_aligner': [
          const FakeProcessScript(lines: [(writing, isError: true)], exitCode: -1073741819),
        ],
      });
      await expectLater(
        colmap(crashed, windows: true).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.outOfMemory)
              .having(
                (e) => e.message,
                'message',
                startsWith('COLMAP (model_orientation_aligner) crashed with -1073741819 at 1 thread: '),
              ),
        ),
      );
      expect(crashed.launches.where((l) => l.arguments.first == 'model_orientation_aligner'), hasLength(1));
    });

    test('the mapper crashed starts again from an empty sparse folder, with half its threads', () async {
      final runner = _ColmapRunner({
        ...scripts(),
        'mapper': [FakeProcessScript(lines: _mapping(40), exitCode: -11), FakeProcessScript(lines: _mapping(150))],
      });
      final poses = await colmap(runner).poses(work, images: 150, video: false, cancel: cancel);
      final mappers = runner.launches.where((l) => l.arguments.first == 'mapper').toList();
      expect(mappers.map((l) => l.arguments[l.arguments.indexOf('--Mapper.num_threads') + 1]), ['14', '7']);
      expect(File(p.join(work.sparse.path, '0', 'leftover')).existsSync(), isFalse);
      expect(poses.placed, 150);
    });

    test('no model: notEnoughOverlap of none placed; the largest of two; under 30 %: refused; under half: incomplete; '
        'under 90 %: partial', () async {
      final none = _ColmapRunner({
        ...scripts(),
        'mapper': [
          const FakeProcessScript(
            lines: [
              ('I20261101 incremental_pipeline.cc:477] => No good initial image pair found.', isError: true),
              ('E20261101 sfm.cc:242] failed to create sparse model', isError: true),
            ],
            exitCode: 1,
          ),
        ],
      }, models: const []);
      await expectLater(
        colmap(none).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.notEnoughOverlap)
              .having((e) => e.message, 'message', '0/150'),
        ),
      );
      expect(none.launches.map((l) => l.arguments.first), isNot(contains('model_orientation_aligner')));

      final split = _ColmapRunner(scripts(), models: const [26, 144]);
      final poses = await colmap(split).poses(work, images: 150, video: true, cancel: cancel);
      expect(split.launches.last.arguments, containsAllInOrder(['--input_path', p.join(work.sparse.path, '1')]));
      expect((poses.placed, poses.incomplete, poses.partial), (144, false, false));

      final few = _ColmapRunner(scripts(), models: const [44]);
      await expectLater(
        colmap(few).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.notEnoughOverlap)
              .having((e) => e.message, 'message', '44/150'),
        ),
      );
      expect(few.launches.map((l) => l.arguments.first), isNot(contains('model_orientation_aligner')));

      // Refused until 3 November (74 of 150, under half): made now, said maybe incomplete
      final incomplete = await colmap(
        _ColmapRunner(scripts(), models: const [74]),
      ).poses(work, images: 150, video: false, cancel: cancel);
      expect((incomplete.placed, incomplete.incomplete, incomplete.partial), (74, true, true));

      final partial = await colmap(
        _ColmapRunner(scripts(), models: const [112]),
      ).poses(work, images: 150, video: false, cancel: cancel);
      expect((partial.placed, partial.incomplete, partial.partial), (112, false, true));
    });

    test('the thresholds of the poses: 20 images and 30 % of them at least, half for a scene not incomplete, 90 % for '
        'a whole scene', () {
      void refused(int placed, int images) => expect(
        () => checkPlaced(placed, images),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.notEnoughOverlap)
              .having((e) => e.message, 'message', '$placed/$images'),
        ),
        reason: '$placed/$images',
      );
      refused(19, 20);
      refused(19, 30);
      refused(20, 67);
      refused(44, 150);
      checkPlaced(20, 20);
      checkPlaced(20, 66);
      checkPlaced(45, 150);
      // FreeKC's object of 3 November, refused then
      checkPlaced(68, 139);
      checkPlaced(74, 150);
      expect(SplatV1.minPlaced, 20);
      expect(SplatV1.minPlacedShare, 0.3);
      expect(SplatV1.incompleteShare, 0.5);
      expect(SplatV1.partialShare, 0.9);
    });

    test('another failure is posesFailed with the end of the error output, the next commands never started', () async {
      final runner = _ColmapRunner({
        ...scripts(),
        'exhaustive_matcher': [
          const FakeProcessScript(
            lines: [('E20261101 database.cc:300] Failed to open the database', isError: true)],
            exitCode: 1,
          ),
        ],
      });
      await expectLater(
        colmap(runner).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having(
                (e) => e.message,
                'message',
                contains('COLMAP (exhaustive_matcher) ended with 1: E20261101 database.cc:300]'),
              ),
        ),
      );
      expect(runner.launches.map((l) => l.arguments.first), ['feature_extractor', 'exhaustive_matcher']);
    });

    test('silent for 600 s, COLMAP is stopped as posesStalled; cancelled, it is stopped as cancelled', () {
      fakeAsync((async) {
        final runner = _ColmapRunner({
          ...scripts(),
          'exhaustive_matcher': [FakeProcessScript(lines: _measured('c2s-match.err').take(10).toList(), hangs: true)],
        });
        Object? failure;
        unawaited(
          colmap(runner, elapsed: () => async.elapsed)
              .poses(work, images: 150, video: false, cancel: cancel)
              .then<void>((_) {}, onError: (Object error) => failure = error),
        );
        async.elapse(const Duration(seconds: 599));
        expect(failure, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(runner.processes.last.killed, isTrue);
        // The command that went silent and what it said last: the first test build lost both (2 November)
        expect(
          failure,
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesStalled)
              .having(
                (e) => e.message,
                'message',
                startsWith('COLMAP (exhaustive_matcher) wrote nothing for 600 s and was stopped; its last lines:\n'),
              )
              .having((e) => e.message, 'message', endsWith(_measured('c2s-match.err')[9].$1)),
        );
      });
      fakeAsync((async) {
        final runner = _ColmapRunner({
          ...scripts(),
          'mapper': [FakeProcessScript(lines: _mapping(30), hangs: true)],
        });
        Object? failure;
        unawaited(
          colmap(runner, elapsed: () => async.elapsed)
              .poses(work, images: 150, video: false, cancel: cancel)
              .then<void>((_) {}, onError: (Object error) => failure = error),
        );
        async.elapse(const Duration(seconds: 5));
        cancel.cancel();
        async.elapse(const Duration(milliseconds: 250));
        expect(runner.processes.last.killed, isTrue);
        expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled));
      });
    });

    test('a work folder that refuses its files is posesFailed; a disk full is diskFull', () async {
      // A file where the folder of COLMAP goes: the folder cannot be made
      File(work.colmap.path).writeAsStringSync('in the way');
      final runner = _ColmapRunner(scripts());
      await expectLater(
        colmap(runner).poses(work, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.message, 'message', startsWith('The work folder of COLMAP refused a file: ')),
        ),
      );
      expect(runner.launches, isEmpty);
      // ENOSPC on Linux, ERROR_DISK_FULL and ERROR_HANDLE_DISK_FULL on Windows; anything else the failure of the step
      FileSystemException error(int code) => FileSystemException('Cannot write', '/w/x', OSError('error $code', code));
      expect(
        splatFileFailure(error(28), 'COLMAP', ImmersiveErrorCode.posesFailed, windows: false).code,
        ImmersiveErrorCode.diskFull,
      );
      expect(
        splatFileFailure(error(112), 'Brush', ImmersiveErrorCode.trainingFailed, windows: true).code,
        ImmersiveErrorCode.diskFull,
      );
      expect(
        splatFileFailure(error(39), 'Brush', ImmersiveErrorCode.trainingFailed, windows: true).code,
        ImmersiveErrorCode.diskFull,
      );
      expect(
        splatFileFailure(error(28), 'COLMAP', ImmersiveErrorCode.posesFailed, windows: true).code,
        ImmersiveErrorCode.posesFailed,
      );
      expect(
        splatFileFailure(error(5), 'COLMAP', ImmersiveErrorCode.posesFailed, windows: true).code,
        ImmersiveErrorCode.posesFailed,
      );
      expect(
        splatFileFailure(error(13), 'Brush', ImmersiveErrorCode.trainingFailed, windows: false).message,
        startsWith('The work folder of Brush refused a file: Cannot write'),
      );
    });

    test('a work folder with no ASCII path is refused before COLMAP starts', () async {
      final accented = SplatWorkFolder(Directory(p.join(folder.path, 'Frédéric')))..images.createSync(recursive: true);
      final runner = _ColmapRunner(scripts());
      await expectLater(
        colmap(runner).poses(accented, images: 150, video: false, cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.message, 'message', contains('no path COLMAP can read')),
        ),
      );
      expect(runner.launches, isEmpty);
    });
  });
}
