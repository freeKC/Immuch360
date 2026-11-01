// A fake COLMAP 4.2.1, compiled into a real program by `dart compile exe` (the test and windows jobs of the desktop
// workflow, or by hand) and given to the tests by IMMUCH360_FAKE_COLMAP, so that the runner of the splat scenes (lot
// SP4) and the launcher (managed_process.dart) are tested against a real child process, with no photo to place. Its
// lines are those of the real COLMAP as the measure of 1 November 2026 logged them (glog on the error output: "Processed
// file [87/150]", "Processing block [4/9, 2/9]", "Processing image [120/150]", "Registering image #66
// (num_reg_frames=120)", "Elapsed time: 1.559 [minutes]"), and it writes what the real one writes: a database (here a
// small JSON file, which only this fake reads), then a model in sparse/<n> as COLMAP writes it (cameras.bin, images.bin,
// points3D.bin), aligned and analysed. Its commands, with the options of COLMAP 4.2.1:
//   feature_extractor --database_path D --image_path I [--ImageReader.single_camera 1]
//       [--ImageReader.single_camera_per_folder 1] [--FeatureExtraction.num_threads N] ...
//   exhaustive_matcher --database_path D ...    blocks of 50 images
//   sequential_matcher --database_path D ...    image after image
//   mapper --database_path D --image_path I --output_path S ...
//   model_orientation_aligner --image_path I --input_path M --output_path O --method IMAGE-ORIENTATION
//   model_analyzer --path M
// IMMUCH360_FAKE_COLMAP_MODE says how it goes:
//   ok        every image placed, in sparse/0 (the default)
//   split     two models, as the measure saw once: sparse/0 with the 4 last images, sparse/1 with the others
//   partial   one model with 7 images of 10 placed (between half and 90 %: the scene says so)
//   few       one model with a third of the images (under half: refused)
//   nomodel   no initial pair found, no model, "failed to create sparse model" and exit 1 (words of the sources of
//             COLMAP, not seen in the measure)
//   memory    the extraction ends as on a memory too short when it runs more threads than IMMUCH360_FAKE_COLMAP_THREADS
//             (4 by default): 0xC0000005 on Windows (seen at 24 threads), elsewhere a SIGABRT, as a program of C++
//             ends when an allocation fails (not measured)
//   fail      an error line, then exit 1 (made up)
//   silent    the first lines of the command, then nothing until killed
//   slow      as ok, half a second between two lines of progress (IMMUCH360_FAKE_COLMAP_STEP_MS sets it otherwise,
//             1 ms)
// It writes its process id to the file IMMUCH360_FAKE_COLMAP_PID names, when it does.
//
//   fake_colmap host PIDFILE
// starts this same program in the silent mode through ManagedProcessRunner (on Linux through the launcher
// IMMUCH360_RUN_LAUNCHER names), writes the id of that child to PIDFILE, and waits to be killed: the test kills the host
// and the child must go with it (the job object on Windows, PR_SET_PDEATHSIG on Linux).
//
// Pure Dart, with no Flutter: compiled outside of any test.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';

import 'fake_colmap_model.dart';

late final String _mode;
late final int _stepMs;
var _thread = 24228;

Future<void> main(List<String> arguments) async {
  if (arguments.length == 2 && arguments.first == 'host') {
    await _host(arguments[1]);
    return;
  }
  final pidFile = Platform.environment['IMMUCH360_FAKE_COLMAP_PID'];
  if (pidFile != null && pidFile.isNotEmpty) {
    File(pidFile).writeAsStringSync('$pid');
  }
  _mode = Platform.environment['IMMUCH360_FAKE_COLMAP_MODE'] ?? 'ok';
  _stepMs = int.tryParse(Platform.environment['IMMUCH360_FAKE_COLMAP_STEP_MS'] ?? '') ?? (_mode == 'slow' ? 500 : 1);
  if (arguments.isEmpty || arguments.first == '-h' || arguments.first == '--help' || arguments.first == 'help') {
    stdout.write('COLMAP 4.2.1 (fake of Immuch360)\n\nUsage:\n  colmap [command] [options]\n');
    return;
  }
  final command = arguments.first;
  final options = <String, String>{};
  for (var i = 1; i < arguments.length - 1; i += 2) {
    options[arguments[i].replaceFirst(RegExp('^--'), '')] = arguments[i + 1];
  }
  final started = DateTime.now();
  final code = switch (command) {
    'feature_extractor' => await _extract(options),
    'exhaustive_matcher' || 'sequential_matcher' => await _match(options, sequential: command == 'sequential_matcher'),
    'mapper' => await _map(options),
    'model_orientation_aligner' => await _align(options),
    'model_analyzer' => await _analyze(options),
    _ => -1,
  };
  if (code == -1) {
    stderr.write('Unknown command: $command\n');
    await _flush();
    exit(1);
  }
  if (code == 0) {
    final minutes = DateTime.now().difference(started).inMilliseconds / 60000;
    _log('timer.cc:90', 'Elapsed time: ${minutes.toStringAsFixed(3)} [minutes]');
  }
  await _flush();
  exit(code);
}

/// A line of glog as COLMAP writes it on its error output: "I20261101 12:36:09.514663 24228 file.cc:270] message"
void _log(String where, String message, {String severity = 'I', int? thread}) {
  final now = DateTime.now();
  String two(int value) => '$value'.padLeft(2, '0');
  final date = '${now.year}${two(now.month)}${two(now.day)}';
  final time =
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${'${now.microsecond + now.millisecond * 1000}'.padLeft(6, '0')}';
  stderr.write('$severity$date $time ${'${thread ?? _thread}'.padLeft(5)} $where] $message\n');
}

Future<void> _flush() => Future.wait([stdout.flush(), stderr.flush()]);

Future<void> _step() async {
  await stderr.flush();
  if (_stepMs > 0) {
    await Future<void>.delayed(Duration(milliseconds: _stepMs));
  }
}

/// Waits to be killed, as COLMAP does when it stops writing
Future<Never> _silent() async {
  await _flush();
  await Future<void>.delayed(const Duration(hours: 1));
  exit(0);
}

Future<int> _fail(String where) async {
  _log(where, 'Failed to read the database: database disk image is malformed (fake failure)', severity: 'E');
  return 1;
}

/// The images under [folder], their paths with "/" between folders, sorted as COLMAP reads them
List<String> _images(Directory folder) {
  final names = [
    for (final entity in folder.listSync(recursive: true))
      if (entity is File && RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(entity.path))
        entity.path.substring(folder.path.length + 1).replaceAll(r'\', '/'),
  ]..sort();
  return names;
}

Future<int> _extract(Map<String, String> options) async {
  final database = options['database_path'];
  final images = options['image_path'];
  if (database == null || images == null) {
    _log(
      'option_manager.cc:1209',
      'Failed to parse options: --database_path and --image_path are needed',
      severity: 'E',
    );
    return 1;
  }
  if (!Directory(images).existsSync()) {
    _log('feature_extraction.cc:520', 'Image path does not exist', severity: 'E');
    return 1;
  }
  _log('feature_extraction.cc:498', '=== Feature extraction ===', thread: 7448);
  if (_mode == 'fail') {
    return _fail('feature_extraction.cc:510');
  }
  final asked = int.tryParse(options['FeatureExtraction.num_threads'] ?? '-1') ?? -1;
  final threads = asked <= 0 ? Platform.numberOfProcessors : asked;
  for (var k = 0; k < threads; k++) {
    _log('sift.cc:764', 'Creating SIFT CPU feature extractor', thread: 20000 + k);
  }
  if (_mode == 'silent') {
    return _silent();
  }
  final names = _images(Directory(images));
  final single = options['ImageReader.single_camera'] == '1';
  final perFolder = options['ImageReader.single_camera_per_folder'] == '1';
  final cameras = <String, int>{};
  final sizes = <String, List<int>>{};
  for (var i = 0; i < names.length; i++) {
    final name = names[i];
    final folder = name.contains('/') ? name.substring(0, name.lastIndexOf('/')) : '';
    final key = single ? '' : (perFolder ? folder : name);
    final camera = cameras.putIfAbsent(key, () => cameras.length + 1);
    final bytes = File('$images/$name').readAsBytesSync();
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    final width = info?.width ?? 0;
    final height = info?.height ?? 0;
    sizes['$camera'] = [width, height];
    if (_mode == 'memory' &&
        threads > (int.tryParse(Platform.environment['IMMUCH360_FAKE_COLMAP_THREADS'] ?? '') ?? 4) &&
        i >= names.length ~/ 3) {
      await _flush();
      if (Platform.isWindows) {
        exit(-1073741819);
      }
      Process.killPid(pid, ProcessSignal.sigabrt);
      return _silent();
    }
    _log('feature_extraction.cc:270', 'Processed file [${i + 1}/${names.length}]');
    _log('feature_extraction.cc:273', '  Name:            ${name.split('/').last}');
    _log('feature_extraction.cc:282', '  Dimensions:      $width x $height');
    _log('feature_extraction.cc:285', '  Camera:          #$camera - SIMPLE_RADIAL');
    _log(
      'feature_extraction.cc:289',
      '  Focal Length:    ${(1.2 * (width > height ? width : height)).toStringAsFixed(2)}px',
    );
    _log('feature_extraction.cc:294', '  Features:        ${2000 + (i * 37) % 600} (SIFT)');
    await _step();
  }
  File(database).writeAsStringSync(
    jsonEncode({
      'fake': 'colmap',
      'images': names,
      'cameras': {for (final MapEntry(:key, :value) in cameras.entries) key: value},
      'sizes': sizes,
      'single': single,
      'perFolder': perFolder,
    }),
  );
  return 0;
}

Map<String, Object?>? _database(Map<String, String> options) {
  final path = options['database_path'];
  if (path == null || !File(path).existsSync()) {
    return null;
  }
  return jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
}

Future<int> _match(Map<String, String> options, {required bool sequential}) async {
  _log('feature_matching.cc:196', '=== Feature matching & geometric verification ===', thread: 18264);
  final database = _database(options);
  if (database == null) {
    _log('database.cc:300', 'Failed to open the database', severity: 'E');
    return 1;
  }
  if (_mode == 'fail') {
    return _fail('feature_matching.cc:205');
  }
  final asked = int.tryParse(options['FeatureMatching.num_threads'] ?? '-1') ?? -1;
  for (var k = 0; k < (asked <= 0 ? Platform.numberOfProcessors : asked); k++) {
    _log('sift.cc:1685', 'Creating SIFT CPU feature matcher', thread: 30000 + k);
  }
  final count = (database['images']! as List).length;
  if (sequential) {
    _log('pairing.cc:438', 'Generating sequential image pairs...', thread: 18264);
    if (_mode == 'silent') {
      return _silent();
    }
    for (var i = 1; i <= count; i++) {
      _log('pairing.cc:562', 'Processing image [$i/$count]', thread: 18264);
      await _step();
      _log('feature_matching.cc:218', 'in ${(1.1 + i % 7 / 10).toStringAsFixed(3)}s', thread: 18264);
    }
    return 0;
  }
  _log('pairing.cc:181', 'Generating exhaustive image pairs...', thread: 18264);
  if (_mode == 'silent') {
    return _silent();
  }
  final blocks = (count + 49) ~/ 50;
  for (var a = 1; a <= blocks; a++) {
    for (var b = 1; b <= blocks; b++) {
      _log('pairing.cc:214', 'Processing block [$a/$blocks, $b/$blocks]', thread: 18264);
      await _step();
      _log('feature_matching.cc:218', 'in ${(20 + (a * b) % 9).toStringAsFixed(3)}s', thread: 18264);
    }
  }
  return 0;
}

Future<int> _map(Map<String, String> options) async {
  _log('incremental_pipeline.cc:353', 'Loading database', thread: 31136);
  final database = _database(options);
  final output = options['output_path'];
  if (database == null || output == null) {
    _log('database.cc:300', 'Failed to open the database', severity: 'E');
    return 1;
  }
  if (_mode == 'fail') {
    return _fail('incremental_pipeline.cc:360');
  }
  final names = [for (final name in database['images']! as List) name as String];
  final cameraIds = {
    for (final MapEntry(:key, :value) in (database['cameras']! as Map).entries) key as String: value as int,
  };
  final sizes = database['sizes']! as Map;
  _log('database_cache.cc:126', 'Loading frames...', thread: 31136);
  _log('database_cache.cc:136', ' ${names.length} in 0.001s', thread: 31136);
  _log('incremental_pipeline.cc:465', 'Finding good initial image pair', thread: 31136);
  if (_mode == 'silent') {
    return _silent();
  }
  if (_mode == 'nomodel' || names.length < 2) {
    _log('incremental_pipeline.cc:477', '=> No good initial image pair found.', thread: 31136);
    _log('sfm.cc:242', 'failed to create sparse model', severity: 'E', thread: 31136);
    return 1;
  }
  // The models, each a list of the indices of its images
  final n = names.length;
  final models = switch (_mode) {
    'split' when n > 6 => [
      [for (var i = n - 4; i < n; i++) i],
      [for (var i = 0; i < n - 4; i++) i],
    ],
    'partial' => [
      [for (var i = 0; i < (n * 7 + 9) ~/ 10; i++) i],
    ],
    'few' => [
      [for (var i = 0; i < (n ~/ 3 < 2 ? 2 : n ~/ 3); i++) i],
    ],
    _ => [
      [for (var i = 0; i < n; i++) i],
    ],
  };
  int cameraOf(String name) {
    final folder = name.contains('/') ? name.substring(0, name.lastIndexOf('/')) : '';
    if (database['single'] == true) {
      return cameraIds['']!;
    }
    return cameraIds[database['perFolder'] == true ? folder : name]!;
  }

  for (var m = 0; m < models.length; m++) {
    final model = models[m];
    if (m > 0) {
      _log('incremental_pipeline.cc:465', 'Finding good initial image pair', thread: 31136);
    }
    _log(
      'incremental_pipeline.cc:492',
      'Registering initial image pair #${model[0] + 1} and #${model[1] + 1}',
      thread: 31136,
    );
    _log('incremental_pipeline.cc:510', 'Global bundle adjustment', thread: 31136);
    for (var k = 2; k < model.length; k++) {
      _log(
        'incremental_pipeline.cc:620',
        'Registering image #${model[k] + 1} (num_reg_frames=${k + 1})',
        thread: 31136,
      );
      _log('incremental_pipeline.cc:623', '=> Image sees ${300 + k * 7} / ${900 + k * 11} points', thread: 31136);
      await _step();
    }
    _log('incremental_pipeline.cc:88', 'Retriangulation and Global bundle adjustment', thread: 31136);
    _log('incremental_pipeline.cc:826', 'Keeping successful reconstruction', thread: 31136);
    final used = {for (final i in model) cameraOf(names[i])};
    FakeColmapModel.circle(
      names: [for (final i in model) names[i]],
      ids: [for (final i in model) i + 1],
      cameras: [
        for (final id in used)
          () {
            final size = sizes['$id']! as List;
            final width = size[0] as int;
            final height = size[1] as int;
            return FakeColmapCamera(
              id: id,
              width: width,
              height: height,
              params: [1.2 * (width > height ? width : height), width / 2, height / 2, 0],
            );
          }(),
      ],
      cameraOf: cameraOf,
    ).writeTo(Directory('$output/$m'));
  }
  return 0;
}

Future<int> _align(Map<String, String> options) async {
  final input = options['input_path'];
  final output = options['output_path'];
  _log('model.cc:847', '=== Aligning Reconstruction ===', thread: 24084);
  final model = input == null ? null : FakeColmapModel.readFrom(Directory(input));
  if (model == null || output == null) {
    _log('reconstruction.cc:910', 'Failed to read the model in ${input ?? '(none)'}', severity: 'E', thread: 24084);
    return 1;
  }
  if (_mode == 'fail') {
    return _fail('model.cc:860');
  }
  _log('model.cc:881', 'Using the rotation matrix:', thread: 24084);
  _log('model.cc:882', ' 0.990996  0.123359 0.0520441\n-0.123359  0.690162  0.713063\n0.0520441 -0.713063  0.699166');
  _log('model.cc:886', 'Writing aligned reconstruction...', thread: 24084);
  model.writeTo(Directory(output));
  return 0;
}

Future<int> _analyze(Map<String, String> options) async {
  final path = options['path'];
  final model = path == null ? null : FakeColmapModel.readFrom(Directory(path));
  if (model == null) {
    _log('reconstruction.cc:910', 'Failed to read the model in ${path ?? '(none)'}', severity: 'E', thread: 29976);
    return 1;
  }
  final observations = model.points.fold<int>(0, (sum, point) => sum + point.track.length);
  _log('model.cc:434', 'Rigs: ${model.cameras.length}', thread: 29976);
  _log('model.cc:435', 'Cameras: ${model.cameras.length}', thread: 29976);
  _log('model.cc:436', 'Frames: ${model.images.length}', thread: 29976);
  _log('model.cc:437', 'Registered frames: ${model.images.length}', thread: 29976);
  _log('model.cc:439', 'Images: ${model.images.length}', thread: 29976);
  _log('model.cc:440', 'Registered images: ${model.images.length}', thread: 29976);
  _log('model.cc:442', 'Points: ${model.points.length}', thread: 29976);
  _log('model.cc:443', 'Observations: $observations', thread: 29976);
  _log('model.cc:445', 'Mean track length: ${(observations / model.points.length).toStringAsFixed(6)}', thread: 29976);
  _log('model.cc:450', 'Mean reprojection error: 0.662430px', thread: 29976);
  return 0;
}

/// The host of the test of a program that never outlives the app
Future<void> _host(String pidFile) async {
  final launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];
  final runner = ManagedProcessRunner(linuxLauncher: launcher);
  final folder = Directory.systemTemp.createTempSync('fake-colmap-host-');
  final child = await runner.start(
    ProcessLaunch(
      executable: Platform.resolvedExecutable,
      arguments: ['feature_extractor', '--database_path', '${folder.path}/database.db', '--image_path', folder.path],
      environment: const {'IMMUCH360_FAKE_COLMAP_MODE': 'silent', 'IMMUCH360_FAKE_COLMAP_PID': ''},
    ),
  );
  unawaited(child.stdoutLines.drain<void>());
  unawaited(child.stderrLines.drain<void>());
  File(pidFile).writeAsStringSync('${child.pid}');
  await Future<void>.delayed(const Duration(hours: 1));
}
