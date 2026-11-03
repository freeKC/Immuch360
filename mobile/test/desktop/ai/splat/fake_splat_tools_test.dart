// The fake COLMAP and the fake Brush of the splat scenes (test/desktop/ai/fakes/fake_colmap.dart and fake_brush.dart,
// lot SP0), compiled by `dart compile exe` in the test and windows jobs of the desktop workflow, which give their paths
// in IMMUCH360_FAKE_COLMAP and IMMUCH360_FAKE_BRUSH: what the runners of lot SP4 will read from them. The lines of the
// measure of 1 November 2026, the files the real programs write (a model of COLMAP, an export of Brush in its
// alphabetical order), each mode of failure, and a host killed that takes its child with it. Skipped without them.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../fakes/fake_colmap_model.dart';
import '../fakes/fake_colmap_options.dart';

final _colmap = Platform.environment['IMMUCH360_FAKE_COLMAP'];
final _brush = Platform.environment['IMMUCH360_FAKE_BRUSH'];
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];
final Object _skipColmap = _colmap == null || _colmap!.isEmpty ? 'IMMUCH360_FAKE_COLMAP names no fake COLMAP' : false;
final Object _skipBrush = _brush == null || _brush!.isEmpty ? 'IMMUCH360_FAKE_BRUSH names no fake Brush' : false;

/// The host test needs immuch360-run on Linux, the job object does it on Windows
Object _skipHost(Object skip) => skip != false
    ? skip
    : (!Platform.isWindows && _launcher == null ? 'IMMUCH360_RUN_LAUNCHER names no immuch360-run' : false);

const _rustLog = 'brush_cli=info,brush_process=info,cubecl_wgpu=info';

/// The help of the commands of our COLMAP, frozen by lot SP1 (matches_importer by lot SPF1)
final _colmapHelp = p.join('test', 'fixtures', 'ai_immersive', 'colmap_help');

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('fake-splat-tools-'));
  tearDown(() => folder.deleteSync(recursive: true));

  /// [count] photos of 64 x 48 in [folders] folders of images/
  void photos(int count, {int folders = 1}) {
    final picture = img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(120, 90, 70)));
    for (var k = 1; k <= count; k++) {
      File(p.join(folder.path, 'images', 'cam${k % folders}', '${'$k'.padLeft(4, '0')}.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(picture);
    }
  }

  ProcessResult colmap(List<String> arguments, {String mode = 'ok', Map<String, String> environment = const {}}) =>
      Process.runSync(
        _colmap!,
        arguments,
        environment: {'IMMUCH360_FAKE_COLMAP_MODE': mode, 'IMMUCH360_FAKE_COLMAP_STEP_MS': '0', ...environment},
      );

  String path(String name) => p.join(folder.path, name);

  List<String> extract({int threads = 2}) => [
    'feature_extractor',
    '--database_path',
    path('database.db'),
    '--image_path',
    path('images'),
    '--ImageReader.single_camera_per_folder',
    '1',
    '--FeatureExtraction.use_gpu',
    '0',
    '--FeatureExtraction.num_threads',
    '$threads',
  ];

  /// The mapper into sparse/, which the runner makes first: the real one refuses an output folder that is not there
  List<String> map() {
    Directory(path('sparse')).createSync(recursive: true);
    return [
      'mapper',
      '--database_path',
      path('database.db'),
      '--image_path',
      path('images'),
      '--output_path',
      path('sparse'),
    ];
  }

  group('the fake COLMAP', () {
    test('finds the points of each image, matches them in blocks, places them, aligns and analyses the model', () {
      photos(60, folders: 2);
      final extracted = colmap(extract());
      expect(extracted.exitCode, 0, reason: '${extracted.stderr}');
      final lines = LineSplitter.split('${extracted.stderr}').toList();
      expect(
        lines.first,
        matches(RegExp(r'^I\d{8} \d\d:\d\d:\d\d\.\d{6} +\d+ feature_extraction\.cc:498\] === Feature extraction ===$')),
      );
      expect(lines.where((line) => line.endsWith('Creating SIFT CPU feature extractor')), hasLength(2));
      expect(lines.where((line) => line.contains('] Processed file [')), hasLength(60));
      expect(lines, contains(endsWith('Processed file [60/60]')));
      expect(lines, contains(endsWith('  Dimensions:      64 x 48')));
      expect(lines.last, matches(RegExp(r'timer\.cc:90\] Elapsed time: \d+\.\d{3} \[minutes\]$')));

      final matched = colmap(['exhaustive_matcher', '--database_path', path('database.db')]);
      expect(matched.exitCode, 0, reason: '${matched.stderr}');
      expect('${matched.stderr}', contains('pairing.cc:181] Generating exhaustive image pairs...'));
      expect(
        RegExp(r'Processing block \[(\d)/(\d), (\d)/(\d)\]').allMatches('${matched.stderr}').map((m) => m.group(0)),
        [
          for (var a = 1; a <= 2; a++)
            for (var b = 1; b <= 2; b++) 'Processing block [$a/2, $b/2]',
        ],
      );

      final mapped = colmap(map());
      expect(mapped.exitCode, 0, reason: '${mapped.stderr}');
      expect('${mapped.stderr}', contains('Registering initial image pair #1 and #2'));
      // num_reg_frames counts the images placed before this one, as the real one logs it (logs/c2-map.err of the
      // measure: the third image at 2, the 150th at 149)
      expect('${mapped.stderr}', contains('Registering image #3 (num_reg_frames=2)'));
      expect('${mapped.stderr}', contains('Registering image #60 (num_reg_frames=59)'));
      expect('${mapped.stderr}', isNot(contains('(num_reg_frames=60)')));
      expect('${mapped.stderr}', contains('Keeping successful reconstruction'));
      final model = FakeColmapModel.readFrom(Directory(path('sparse/0')))!;
      expect(model.images, hasLength(60));
      expect(model.cameras.map((camera) => (camera.id, camera.width, camera.height)), [(1, 64, 48), (2, 64, 48)]);
      expect(model.images.first.name, 'cam0/0002.jpg');
      expect(model.points, isNotEmpty);
      expect(Directory(path('sparse/1')).existsSync(), isFalse);

      Directory(path('dataset/sparse/0')).createSync(recursive: true);
      final aligned = colmap([
        'model_orientation_aligner',
        '--image_path',
        path('images'),
        '--input_path',
        path('sparse/0'),
        '--output_path',
        path('dataset/sparse/0'),
        '--method',
        'IMAGE-ORIENTATION',
      ]);
      expect(aligned.exitCode, 0, reason: '${aligned.stderr}');
      expect('${aligned.stderr}', contains('=== Aligning Reconstruction ==='));
      expect(FakeColmapModel.readFrom(Directory(path('dataset/sparse/0')))!.images, hasLength(60));

      final analysed = colmap(['model_analyzer', '--path', path('dataset/sparse/0')]);
      expect('${analysed.stderr}', contains('model.cc:440] Registered images: 60'));
      expect('${analysed.stderr}', contains('Mean reprojection error: 0.662430px'));
    }, skip: _skipColmap);

    test('the names of the images are written in UTF-8 in images.bin, as COLMAP writes them', () {
      final picture = img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(120, 90, 70)));
      const names = ['Łódź/photo é 1.jpg', 'Łódź/photo é 2.jpg', 'Łódź/photo é 3.jpg'];
      for (final name in names) {
        File(p.join(folder.path, 'images', name))
          ..createSync(recursive: true)
          ..writeAsBytesSync(picture);
      }
      expect(colmap(extract()).exitCode, 0);
      expect(colmap(['exhaustive_matcher', '--database_path', path('database.db')]).exitCode, 0);
      expect(colmap(map()).exitCode, 0);

      final model = FakeColmapModel.readFrom(Directory(path('sparse/0')))!;
      expect(model.images.map((image) => image.name).toSet(), names.toSet());
      final bytes = File(path('sparse/0/images.bin')).readAsBytesSync();
      final encoded = [...utf8.encode(names.first), 0];
      final at = [for (var k = 0; k + encoded.length <= bytes.length; k++) k].where((k) {
        for (var j = 0; j < encoded.length; j++) {
          if (bytes[k + j] != encoded[j]) {
            return false;
          }
        }
        return true;
      });
      expect(at, hasLength(1), reason: 'the UTF-8 bytes of the name, then its 0');
    }, skip: _skipColmap);

    test('an option COLMAP 4.2.1 does not have, a missing value or a missing option: refused, exit code 1', () {
      photos(3);
      // The name of COLMAP 3, renamed FeatureExtraction.use_gpu in 4
      final old = colmap([...extract(), '--SiftExtraction.use_gpu', '0']);
      expect(old.exitCode, 1);
      expect(
        '${old.stderr}',
        contains(
          RegExp(
            r"^E\d{8} [\d:.]+ +\d+ base_option_manager\.cc:265\] Failed to parse options - unrecognised option "
            r"'--SiftExtraction\.use_gpu'\.$",
            multiLine: true,
          ),
        ),
      );
      expect('${old.stderr}', isNot(contains('Processed file')));
      expect(File(path('database.db')).existsSync(), isFalse);
      // An option of another command
      final other = colmap([...map(), '--FeatureExtraction.num_threads', '2']);
      expect(other.exitCode, 1);
      expect('${other.stderr}', contains("unrecognised option '--FeatureExtraction.num_threads'"));
      // A value that is not there, an option the command needs
      final cut = colmap([...extract(), '--FeatureExtraction.max_image_size']);
      expect(cut.exitCode, 1);
      expect(
        '${cut.stderr}',
        contains("the required argument for option '--FeatureExtraction.max_image_size' is missing"),
      );
      final none = colmap(['exhaustive_matcher']);
      expect(none.exitCode, 1);
      expect(
        '${none.stderr}',
        contains("Failed to parse options - the option '--database_path' is required but missing."),
      );
      // The form --name=value is read as well, and the size of the blocks of the exhaustive matching
      expect(colmap([...extract(), '--FeatureExtraction.max_image_size=1024']).exitCode, 0);
      final blocks = colmap([
        'exhaustive_matcher',
        '--database_path',
        path('database.db'),
        '--ExhaustiveMatching.block_size',
        '2',
      ]);
      expect(blocks.exitCode, 0);
      expect('${blocks.stderr}', contains('Processing block [2/2, 2/2]'));
    }, skip: _skipColmap);

    test('the options it takes are those of the help of our build (lot SP1), once it is in the tree', () {
      for (final command in fakeColmapOptions.keys) {
        final help = File(p.join(_colmapHelp, '$command.txt')).readAsLinesSync();
        final options = {
          for (final line in help)
            if (RegExp(r'^\s+--([A-Za-z0-9_.]+)\s+arg\b').firstMatch(line) case final match?) match.group(1)!,
        };
        expect(fakeColmapOptions[command], options, reason: command);
        expect(options, containsAll(fakeColmapRequired[command]!), reason: command);
      }
    }, skip: Directory(_colmapHelp).existsSync() ? false : 'the help of COLMAP of lot SP1 is not in this tree yet');

    test('the mapper refuses an output folder that is not there; the aligner stops on it', () {
      photos(3);
      expect(colmap(extract()).exitCode, 0);
      final mapped = colmap([
        'mapper',
        '--database_path',
        path('database.db'),
        '--image_path',
        path('images'),
        '--output_path',
        path('missing'),
      ]);
      expect(mapped.exitCode, 1);
      expect(
        '${mapped.stderr}',
        contains(RegExp(r'^E\d{8} .* sfm\.cc:363\] `output_path` is not a directory\.$', multiLine: true)),
      );
      expect('${mapped.stderr}', isNot(contains('Loading database')));
      expect(Directory(path('missing')).existsSync(), isFalse);

      expect(colmap(map()).exitCode, 0);
      final aligned = colmap([
        'model_orientation_aligner',
        '--image_path',
        path('images'),
        '--input_path',
        path('sparse/0'),
        '--output_path',
        path('dataset/sparse/0'),
        '--method',
        'IMAGE-ORIENTATION',
      ]);
      // An exception nothing caught: on Windows 0xC0000409 and not a word, as our build was measured on 1 November;
      // elsewhere libstdc++ names it, then SIGABRT
      expect(aligned.exitCode, Platform.isWindows ? -1073740791 : -ProcessSignal.sigabrt.signalNumber);
      expect('${aligned.stderr}', contains('] Writing aligned reconstruction...'));
      if (Platform.isWindows) {
        expect(LineSplitter.split('${aligned.stderr}').last, endsWith('] Writing aligned reconstruction...'));
      } else {
        expect('${aligned.stderr}', contains("terminate called after throwing an instance of 'std::invalid_argument'"));
        expect('${aligned.stderr}', contains('Check failed: colmap::ExistsDir(path_val)'));
      }
      expect(Directory(path('dataset/sparse/0')).existsSync(), isFalse);
    }, skip: _skipColmap);

    test('a video is matched image after image', () {
      photos(5);
      expect(colmap(extract()).exitCode, 0);
      final matched = colmap(['sequential_matcher', '--database_path', path('database.db')]);

      expect(matched.exitCode, 0);
      expect('${matched.stderr}', contains('pairing.cc:438] Generating sequential image pairs...'));
      expect(RegExp(r'Processing image \[\d+/5\]').allMatches('${matched.stderr}'), hasLength(5));
    }, skip: _skipColmap);

    test(
      'a long video is matched by its list of pairs: blocks of 1 225, a name the database does not hold skipped',
      () {
        photos(5);
        expect(colmap(extract()).exitCode, 0);
        File(path('pairs.txt')).writeAsStringSync(
          [
            for (var i = 1; i <= 50; i++)
              for (var j = i + 1; j <= 51; j++) 'cam0/${'${(i - 1) % 5 + 1}'.padLeft(4, '0')}.jpg cam0/0002.jpg',
            'cam0/nope.jpg cam0/0001.jpg',
            'cam0/0001.jpg',
          ].join('\n'),
        );
        List<String> imported(String list) => [
          'matches_importer',
          '--database_path',
          path('database.db'),
          '--match_list_path',
          path(list),
          '--match_type',
          'pairs',
          '--FeatureMatching.use_gpu',
          '0',
          '--FeatureMatching.num_threads',
          '2',
        ];
        final matched = colmap(imported('pairs.txt'));

        expect(matched.exitCode, 0, reason: '${matched.stderr}');
        expect('${matched.stderr}', contains('pairing.cc:905] Importing image pairs...'));
        expect('${matched.stderr}', contains('pairing.cc:78] Image cam0/nope.jpg does not exist.'));
        expect('${matched.stderr}', contains('pairing.cc:82] Image  does not exist.'));
        // 1 275 pairs of names it holds: two blocks
        expect(RegExp(r'Processing block \[\d/\d\]').allMatches('${matched.stderr}').map((m) => m.group(0)), [
          'Processing block [1/2]',
          'Processing block [2/2]',
        ]);
        // A list that is not there: 9 and nothing more, as measured on our build
        final missing = colmap(imported('missing.txt'));
        expect(missing.exitCode, 9);
        expect('${missing.stderr}', isNot(contains('Processing block')));
      },
      skip: _skipColmap,
    );

    test('two models, part of the images, a third of them, none: the counts the runner will judge', () {
      photos(30);
      expect(colmap(extract()).exitCode, 0);
      int placed(String model) => FakeColmapModel.readFrom(Directory(path('sparse/$model')))!.images.length;

      expect(colmap(map(), mode: 'split').exitCode, 0);
      expect((placed('0'), placed('1')), (4, 26));
      Directory(path('sparse')).deleteSync(recursive: true);
      expect(colmap(map(), mode: 'partial').exitCode, 0);
      expect(placed('0'), 21);
      Directory(path('sparse')).deleteSync(recursive: true);
      expect(colmap(map(), mode: 'few').exitCode, 0);
      expect(placed('0'), 10);
      Directory(path('sparse')).deleteSync(recursive: true);
      final none = colmap(map(), mode: 'nomodel');
      expect(none.exitCode, 1);
      expect('${none.stderr}', contains('No good initial image pair found.'));
      expect('${none.stderr}', contains(RegExp(r'^E\d{8} .*\] failed to create sparse model$', multiLine: true)));
      expect(Directory(path('sparse/0')).existsSync(), isFalse);
    }, skip: _skipColmap);

    test('more threads than the memory holds end as a crash; half of them pass', () {
      photos(12);
      final crashed = colmap(extract(threads: 8), mode: 'memory');

      // On Windows an access violation, as measured at 24 threads; elsewhere a std::bad_alloc nothing caught, which
      // libstdc++ names before its SIGABRT
      expect(crashed.exitCode, Platform.isWindows ? -1073741819 : -ProcessSignal.sigabrt.signalNumber);
      expect('${crashed.stderr}', contains('Processed file [1/12]'));
      expect('${crashed.stderr}', isNot(contains('Processed file [12/12]')));
      if (!Platform.isWindows) {
        expect('${crashed.stderr}', contains("terminate called after throwing an instance of 'std::bad_alloc'"));
      }
      expect(colmap(extract(threads: 4), mode: 'memory').exitCode, 0);
    }, skip: _skipColmap);

    test('a check that fails ends as an exception nothing caught: 0xC0000409 with no word on Windows', () {
      photos(12);
      final aborted = colmap(extract(), mode: 'abort');

      expect(aborted.exitCode, Platform.isWindows ? -1073740791 : -ProcessSignal.sigabrt.signalNumber);
      expect('${aborted.stderr}', contains('Processed file [1/12]'));
      expect('${aborted.stderr}', isNot(contains('Processed file [12/12]')));
      if (Platform.isWindows) {
        expect('${aborted.stderr}', isNot(contains('Check failed')));
        expect('${aborted.stderr}', isNot(contains('terminate called')));
      } else {
        expect('${aborted.stderr}', contains("terminate called after throwing an instance of 'std::invalid_argument'"));
        expect('${aborted.stderr}', contains('Check failed'));
        expect('${aborted.stderr}', isNot(contains('bad_alloc')));
      }
      expect(File(path('database.db')).existsSync(), isFalse);
    }, skip: _skipColmap);

    test('a failure, a missing folder, and its process id', () {
      final failed = colmap(extract(), mode: 'fail', environment: {'IMMUCH360_FAKE_COLMAP_PID': path('colmap.pid')});
      expect(failed.exitCode, 1);
      expect('${failed.stderr}', contains('Image path does not exist'));
      photos(3);
      final broken = colmap(extract(), mode: 'fail');
      expect(broken.exitCode, 1);
      expect('${broken.stderr}', contains(RegExp(r'^E\d{8} ', multiLine: true)));
      expect(int.parse(File(path('colmap.pid')).readAsStringSync()), greaterThan(0));
      expect(colmap(['stereo_fusion']).exitCode, 1);
    }, skip: _skipColmap);

    test(
      'silent until killed',
      () async {
        photos(3);
        final silent = await Process.start(_colmap!, extract(), environment: {'IMMUCH360_FAKE_COLMAP_MODE': 'silent'});
        final err = silent.stderr.transform(utf8.decoder).join();
        await Future<void>.delayed(const Duration(seconds: 2));
        silent.kill(ProcessSignal.sigkill);
        await silent.exitCode;
        expect(await err, contains('Creating SIFT CPU feature extractor'));
        expect(await err, isNot(contains('Processed file')));
      },
      skip: _skipColmap,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test('gone with its host', () => _hostTakesItsChild(_colmap!, path('child.pid')), skip: _skipHost(_skipColmap));
  });

  group('the fake Brush', () {
    /// A dataset as COLMAP leaves it for Brush: sparse/0 of [count] images
    void dataset(int count) {
      final names = [for (var k = 1; k <= count; k++) 'cam0/${'$k'.padLeft(4, '0')}.jpg'];
      FakeColmapModel.circle(
        names: names,
        ids: [for (var k = 1; k <= count; k++) k],
        cameras: const [
          FakeColmapCamera(id: 1, width: 64, height: 48, params: [76.8, 32, 24, 0]),
        ],
        cameraOf: (_) => 1,
      ).writeTo(Directory(path('dataset/sparse/0')));
    }

    /// Brush run in the work folder [workIn] (under the folder of the test), where it keeps its autotune cache
    ProcessResult brush(
      List<String> arguments, {
      String mode = 'ok',
      String rustLog = _rustLog,
      Map<String, String> environment = const {},
      String workIn = 'work',
    }) => Process.runSync(
      _brush!,
      [path('dataset'), ...arguments],
      workingDirectory: (Directory(path(workIn))..createSync(recursive: true)).path,
      environment: {
        'IMMUCH360_FAKE_BRUSH_MODE': mode,
        'IMMUCH360_FAKE_BRUSH_STEP_MS': '0',
        'RUST_LOG': rustLog,
        ...environment,
      },
    );

    /// The folder of the autotune cache of cubecl 0.7.0 under the work folder [workIn], as Brush 0.3.0 writes it
    /// (target\autotune\0.7.0\device-4-0-wgpu_wgsl_, lot SP2): the same key for every card
    Directory autotuneIn(String workIn) =>
        Directory(p.join(path(workIn), 'target', 'autotune', '0.7.0', 'device-4-0-wgpu_wgsl_'));

    const discrete = {'CUBECL_WGPU_DEFAULT_DEVICE': 'DiscreteGpu(0)'};
    const integrated = {'CUBECL_WGPU_DEFAULT_DEVICE': 'IntegratedGpu(0)'};
    final aborted = Platform.isWindows ? -1073740791 : -ProcessSignal.sigabrt.signalNumber;

    const train = [
      '--total-steps',
      '2000',
      '--max-splats',
      '1500',
      '--sh-degree',
      '3',
      '--max-resolution',
      '1024',
      '--export-every',
      '2000',
    ];

    test('trains with the lines of the measure and exports in the alphabetical order of Brush 0.3.0', () {
      dataset(24);
      final run = brush([...train, '--export-path', path('export')], environment: discrete);

      expect(run.exitCode, 0, reason: '${run.stderr}');
      final lines = LineSplitter.split('${run.stdout}').toList();
      expect(
        lines.first,
        matches(
          RegExp(
            r'^\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ INFO  cubecl_wgpu::runtime\] Using adapter AdapterInfo \{ name: "NVIDIA',
          ),
        ),
      );
      expect(lines.first, contains('device_type: DiscreteGpu'));
      expect(lines, contains(endsWith('INFO  brush_cli] Loaded dataset with 24 training, 0 eval views')));
      expect(lines.where((line) => line.contains('] Refine iter ')), hasLength(9));
      expect(lines, contains(endsWith('Refine iter 201, ${(1500 * 1201 / 16000).round()} splats.')));
      expect(lines.last, matches(RegExp(r'brush_cli\] Done training! Took FormattedDuration\(\d+s\)\.$')));
      final export = File(path('export/export_2000.ply')).readAsBytesSync();
      final end = latin1.decode(export.sublist(0, 4000)).indexOf('end_header\n') + 'end_header\n'.length;
      final header = latin1.decode(export.sublist(0, end)).split('\n');
      expect(header.take(6), [
        'ply',
        'format binary_little_endian 1.0',
        'comment Exported from Brush',
        'comment Vertical axis: y',
        'comment SH degree: 3',
        'element vertex 1500',
      ]);
      final properties = [
        for (final line in header)
          if (line.startsWith('property float ')) line.substring(15),
      ];
      expect(properties, hasLength(59));
      expect(properties.take(5), ['f_dc_0', 'f_dc_1', 'f_dc_2', 'f_rest_0', 'f_rest_1']);
      expect(properties[5], 'f_rest_10');
      expect(properties.skip(47), [
        'f_rest_9',
        'opacity',
        'rot_0',
        'rot_1',
        'rot_2',
        'rot_3',
        'scale_0',
        'scale_1',
        'scale_2',
        'x',
        'y',
        'z', //
      ]);
      expect(export.length, end + 1500 * 59 * 4);
    }, skip: _skipBrush);

    test('says only what RUST_LOG asks for, and the views kept for the evaluation', () {
      dataset(19);
      final quiet = brush([...train, '--export-path', path('export')], rustLog: '');
      expect('${quiet.stdout}', isEmpty);
      final cli = brush([
        ...train,
        '--export-path',
        path('export'),
        '--eval-split-every',
        '8',
        '--eval-every',
        '1000',
      ], rustLog: 'brush_cli=info');
      expect('${cli.stdout}', isNot(contains('Using adapter')));
      expect('${cli.stdout}', contains('Loaded dataset with 16 training, 3 eval views'));
      expect(RegExp(r'Eval iter (1000|2000): PSNR \d+\.\d+, ssim').allMatches('${cli.stdout}'), hasLength(2));
    }, skip: _skipBrush);

    test('refuses an option Brush 0.3.0 does not have, as clap', () {
      dataset(4);
      final run = brush(['--steps', '2000']);

      expect(run.exitCode, 2);
      expect('${run.stderr}', contains("error: unexpected argument '--steps' found"));
    }, skip: _skipBrush);

    test('the Intel graphics train in a work folder of their own, and keep their autotune cache there', () {
      // SP2, 1 November 2026: with its own cache the Intel UHD trains (1 000 steps in 107 s, exit 0), some ten times
      // slower than the RTX (fixture brush_igpu_fresh_cache_stdout.txt)
      dataset(6);
      final intel = brush([...train, '--export-path', path('export')], environment: integrated, workIn: 'igpu');

      expect(intel.exitCode, 0, reason: '${intel.stderr}');
      expect('${intel.stdout}', contains('device_type: IntegratedGpu'));
      expect('${intel.stdout}', contains('Start training loop.'));
      expect('${intel.stdout}', contains('Done training!'));
      expect(File(path('export/export_2000.ply')).existsSync(), isTrue);
      expect(autotuneIn('igpu').listSync(), isNotEmpty);
      // Its own cache again: it trains again
      expect(brush(train, environment: integrated, workIn: 'igpu').exitCode, 0);
      // The RTX in a folder of its own trains as well, beside it
      expect(brush(train, environment: discrete, workIn: 'rtx').exitCode, 0);
      expect(autotuneIn('rtx').listSync(), isNotEmpty);
    }, skip: _skipBrush);

    test('the cache another card left in the same work folder ends in the panic of the measure', () {
      // SP2 (sp2-igpu-stale-cache, 17h07): the cache the RTX left, its kernels picked for the RTX, makes the Intel UHD
      // panic at its first kernel, before "Start training loop." (fixtures brush_igpu_plane_failure_*.txt)
      dataset(6);
      expect(brush(train, environment: discrete, workIn: 'shared').exitCode, 0);
      final intel = brush(train, environment: integrated, workIn: 'shared');

      expect(intel.exitCode, aborted);
      expect('${intel.stdout}', contains('device_type: IntegratedGpu'));
      expect(LineSplitter.split('${intel.stdout}').last, endsWith('brush_cli] Completed loading.'));
      expect('${intel.stdout}', isNot(contains('Start training loop.')));
      expect('${intel.stderr}', contains("thread 'main' panicked at "));
      expect(
        '${intel.stderr}',
        contains(
          'Trying to launch a kernel using plane instructions, but the min and max plane dimensions are different.',
        ),
      );
      // A work folder of its own, and the same Intel trains
      expect(brush(train, environment: integrated, workIn: 'igpu').exitCode, 0);
      // The planes mode panics whatever the cache, on any card
      expect(brush(train, mode: 'planes', environment: discrete, workIn: 'rtx').exitCode, aborted);
    }, skip: _skipBrush);

    test(
      'after its panic it may stay a while, as Windows Error Reporting held it 80 s: the runner kills it on the line',
      () async {
        dataset(6);
        final stopwatch = Stopwatch()..start();
        final held = await Process.start(
          _brush!,
          [path('dataset'), ...train],
          workingDirectory: (Directory(path('held'))..createSync()).path,
          environment: {
            'IMMUCH360_FAKE_BRUSH_MODE': 'planes',
            'IMMUCH360_FAKE_BRUSH_PANIC_HOLD_MS': '60000',
            'RUST_LOG': _rustLog,
          },
        );
        unawaited(held.stdout.drain<void>());
        final panicked = Completer<void>();
        held.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
          if (line.contains('panicked at') && !panicked.isCompleted) {
            panicked.complete();
          }
        });
        await panicked.future.timeout(const Duration(seconds: 30));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(await held.exitCode.timeout(Duration.zero, onTimeout: () => 999), 999, reason: 'still held');
        held.kill(ProcessSignal.sigkill);
        await held.exitCode;
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));
      },
      skip: _skipBrush,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test('a short memory and a dataset it cannot read fail', () {
      dataset(6);
      final oom = brush(train, mode: 'oom');
      expect(oom.exitCode, 101);
      expect('${oom.stderr}', contains('ErrorOutOfDeviceMemory'));
      expect('${oom.stderr}', contains('failed to reserve'));

      final failed = brush(train, mode: 'fail', environment: {'IMMUCH360_FAKE_BRUSH_PID': path('brush.pid')});
      expect(failed.exitCode, 1);
      expect('${failed.stderr}', contains('Failed to load dataset'));
      expect(int.parse(File(path('brush.pid')).readAsStringSync()), greaterThan(0));
    }, skip: _skipBrush);

    test(
      'silent until killed',
      () async {
        dataset(4);
        final silent = await Process.start(
          _brush!,
          [path('dataset'), ...train],
          workingDirectory: folder.path,
          environment: {'IMMUCH360_FAKE_BRUSH_MODE': 'silent', 'RUST_LOG': _rustLog},
        );
        final out = silent.stdout.transform(utf8.decoder).join();
        await Future<void>.delayed(const Duration(seconds: 2));
        silent.kill(ProcessSignal.sigkill);
        await silent.exitCode;
        expect(await out, contains('Start training loop.'));
        expect(await out, isNot(contains('Refine iter')));
      },
      skip: _skipBrush,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test('gone with its host', () => _hostTakesItsChild(_brush!, path('child.pid')), skip: _skipHost(_skipBrush));
  });
}

/// The fake started as `host PIDFILE`: its silent child is gone once the host is killed
Future<void> _hostTakesItsChild(String fake, String pidFile) async {
  final host = await Process.start(fake, ['host', pidFile], environment: {'IMMUCH360_RUN_LAUNCHER': ?_launcher});
  unawaited(host.stdout.drain<void>());
  unawaited(host.stderr.drain<void>());
  final file = File(pidFile);
  for (var k = 0; k < 100 && !(file.existsSync() && file.readAsStringSync().isNotEmpty); k++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final child = int.parse(file.readAsStringSync());
  expect(_alive(child), isTrue);
  host.kill(ProcessSignal.sigkill);
  await host.exitCode;
  for (var k = 0; k < 50 && _alive(child); k++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(_alive(child), isFalse, reason: 'the child of a killed host goes with it');
}

/// Whether the process [id] still runs
bool _alive(int id) {
  if (Platform.isWindows) {
    final list = Process.runSync('tasklist', ['/FI', 'PID eq $id', '/NH']);
    return '${list.stdout}'.contains(' $id ');
  }
  final status = File('/proc/$id/status');
  return status.existsSync() && !status.readAsStringSync().contains(RegExp(r'State:\s+Z'));
}
