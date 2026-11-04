// A fake COLMAP 4.2.1, compiled into a real program by `dart compile exe` (the test and windows jobs of the desktop
// workflow, or by hand) and given to the tests by IMMUCH360_FAKE_COLMAP, so that the runner of the splat scenes (lot
// SP4) and the launcher (managed_process.dart) are tested against a real child process, with no photo to place. Its
// lines are those of the real COLMAP as the measure of 1 November 2026 logged them (glog on the error output: "Processed
// file [87/150]", "Processing block [4/9, 2/9]", "Processing image [120/150]", "Registering image #66
// (num_reg_frames=120)", "Elapsed time: 1.559 [minutes]"), and it writes what the real one writes: a database (here a
// small JSON file, which only this fake reads), then a model in sparse/<n> as COLMAP writes it (cameras.bin, images.bin,
// points3D.bin, the names of the images in UTF-8), aligned and analysed. Its commands, with the options of COLMAP 4.2.1:
//   feature_extractor --database_path D --image_path I [--ImageReader.single_camera 1]
//       [--ImageReader.single_camera_per_folder 1] [--FeatureExtraction.num_threads N] ...
//   exhaustive_matcher --database_path D ...    blocks of --ExhaustiveMatching.block_size images (50)
//   sequential_matcher --database_path D ...    image after image
//   matches_importer --database_path D --match_list_path L --match_type pairs ...    the pairs of the list L ("a.jpg
//       b.jpg" a line), blocks of 1 225 pairs; a name the database does not hold said ("Image nope.jpg does not
//       exist.") and its pair skipped, as the real one does (lot SPF1, measured on 3 November); a list that is not
//       there ends with 9 and nothing more, as measured too
//   mapper --database_path D --image_path I --output_path S ...    S must be there, as for the real one
//   model_orientation_aligner --image_path I --input_path M --output_path O --method IMAGE-ORIENTATION
//   model_analyzer --path M
// As the real one, it takes only the options of each command (those of the help of our build, frozen by lot SP1:
// fake_colmap_options.dart), "--name value" or "--name=value", and refuses any other with exit code 1 ("Failed to
// parse options - unrecognised option '--SiftExtraction.use_gpu'.", base_option_manager.cc:265), as it refuses a
// value or an option the command needs that is missing. The mapper refuses an output folder that is not there
// ("`output_path` is not a directory.", sfm.cc:363); the aligner stops on it when it writes, as the real one throws
// there (THROW_CHECK_DIR_EXISTS of Reconstruction::WriteBinary), an exception nothing catches: on Windows our build ends
// with 0xC0000409 and not a word (measured on 1 November, lot SP4 review); elsewhere libstdc++ writes "terminate called
// after throwing an instance of 'std::invalid_argument'" and its what(), then SIGABRT (read in the sources of COLMAP and
// libstdc++, not measured).
// IMMUCH360_FAKE_COLMAP_MODE says how it goes:
//   ok        every image placed, in sparse/0 (the default)
//   split     two models, as the measure saw once: sparse/0 with the 4 last images, sparse/1 with the others
//   partial   one model with 7 images of 10 placed (between half and 90 %: the scene says so)
//   incomplete  one model with two images of five placed (between 30 % and half: made, said maybe incomplete)
//   few       one model with a fifth of the images (under 30 %: refused)
//   nomodel   no initial pair found, no model, "failed to create sparse model" and exit 1 (words of the sources of
//             COLMAP, not seen in the measure)
//   memory    the extraction ends as on a memory too short when it runs more threads than IMMUCH360_FAKE_COLMAP_THREADS
//             (4 by default): 0xC0000005 on Windows (seen at 24 threads), elsewhere a std::bad_alloc nothing caught,
//             named by libstdc++, then SIGABRT, as a program of C++ ends when an allocation fails (not measured)
//   abort     the extraction stops on a check that fails a third of the way (its words made up), and ends as the
//             aligner on a folder missing
//   fail      an error line, then exit 1 (made up)
//   silent    the first lines of the command, then nothing until killed
//   slow      as ok, half a second between two lines of progress (IMMUCH360_FAKE_COLMAP_STEP_MS sets it otherwise,
//             1 ms)
// IMMUCH360_FAKE_COLMAP_MODE_AT, when it names a command ("exhaustive_matcher"), gives the mode to that command alone,
// the others going as ok: a job that goes silent at the matching, after an extraction that went well.
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
import 'fake_colmap_options.dart';

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
  final modeAt = Platform.environment['IMMUCH360_FAKE_COLMAP_MODE_AT'] ?? '';
  _mode = modeAt.isEmpty || (arguments.isNotEmpty && arguments.first == modeAt)
      ? Platform.environment['IMMUCH360_FAKE_COLMAP_MODE'] ?? 'ok'
      : 'ok';
  _stepMs = int.tryParse(Platform.environment['IMMUCH360_FAKE_COLMAP_STEP_MS'] ?? '') ?? (_mode == 'slow' ? 500 : 1);
  if (arguments.isEmpty || arguments.first == '-h' || arguments.first == '--help' || arguments.first == 'help') {
    stdout.write('COLMAP 4.2.1 (fake of Immuch360)\n\nUsage:\n  colmap [command] [options]\n');
    return;
  }
  final command = arguments.first;
  final options = <String, String>{};
  final known = fakeColmapOptions[command];
  if (known != null) {
    final problem = _parse(arguments.sublist(1), known, fakeColmapRequired[command]!, options);
    if (problem != null) {
      _log('base_option_manager.cc:265', 'Failed to parse options - $problem.', severity: 'E');
      await _flush();
      exit(1);
    }
  }
  final started = DateTime.now();
  final code = switch (command) {
    'feature_extractor' => await _extract(options),
    'exhaustive_matcher' || 'sequential_matcher' => await _match(options, sequential: command == 'sequential_matcher'),
    'matches_importer' => await _import(options),
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

/// Reads [arguments] into [options] as boost::program_options does for COLMAP: the words of what is wrong, null when
/// nothing is
String? _parse(List<String> arguments, Set<String> known, List<String> required, Map<String, String> options) {
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (!argument.startsWith('--')) {
      return "too many positional options have been specified on the command line";
    }
    final equals = argument.indexOf('=');
    final name = argument.substring(2, equals < 0 ? argument.length : equals);
    if (!known.contains(name)) {
      return "unrecognised option '--$name'";
    }
    if (equals >= 0) {
      options[name] = argument.substring(equals + 1);
    } else if (i + 1 < arguments.length && !arguments[i + 1].startsWith('--')) {
      options[name] = arguments[++i];
    } else {
      return "the required argument for option '--$name' is missing";
    }
  }
  for (final name in required) {
    if (!options.containsKey(name)) {
      return "the option '--$name' is required but missing";
    }
  }
  return null;
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

/// Ends as COLMAP does on an exception of [type] that nothing caught, [what] its message: on Windows 0xC0000409 and not
/// a word (the runtime of Visual C++, measured on 1 November with our build); elsewhere the words of libstdc++, then
/// SIGABRT
Future<int> _uncaught(String type, String what) async {
  if (Platform.isWindows) {
    await _flush();
    exit(-1073740791);
  }
  stderr.write("terminate called after throwing an instance of '$type'\n  what():  $what\n");
  await _flush();
  Process.killPid(pid, ProcessSignal.sigabrt);
  return _silent();
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
  final database = options['database_path']!;
  final images = options['image_path']!;
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
      if (Platform.isWindows) {
        await _flush();
        exit(-1073741819);
      }
      return _uncaught('std::bad_alloc', 'std::bad_alloc');
    }
    if (_mode == 'abort' && i >= names.length ~/ 3) {
      return _uncaught(
        'std::invalid_argument',
        '[feature_extraction.cc:331] Check failed: ExistsDir(image_path) Image path does not exist',
      );
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
  final size = int.tryParse(options['ExhaustiveMatching.block_size'] ?? '') ?? 50;
  final blocks = (count + size - 1) ~/ (size < 2 ? 2 : size);
  for (var a = 1; a <= blocks; a++) {
    for (var b = 1; b <= blocks; b++) {
      _log('pairing.cc:214', 'Processing block [$a/$blocks, $b/$blocks]', thread: 18264);
      await _step();
      _log('feature_matching.cc:218', 'in ${(20 + (a * b) % 9).toStringAsFixed(3)}s', thread: 18264);
    }
  }
  return 0;
}

/// The pairs of a list a block, as matches_importer counts them (1 225: the blocks of 2 887 pairs were 3, measured)
const _importBlock = 1225;

Future<int> _import(Map<String, String> options) async {
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
  _log('pairing.cc:905', 'Importing image pairs...', thread: 18264);
  final list = File(options['match_list_path']!);
  if (!list.existsSync()) {
    await _flush();
    return 9;
  }
  if (_mode == 'silent') {
    return _silent();
  }
  final known = {for (final name in database['images']! as List) name as String};
  var pairs = 0;
  for (final line in list.readAsLinesSync()) {
    final names = line.trim().split(RegExp(r'\s+'));
    final first = names.isEmpty ? '' : names[0];
    final second = names.length < 2 ? '' : names[1];
    if (!known.contains(first)) {
      _log('pairing.cc:78', 'Image $first does not exist.', severity: 'E', thread: 18264);
      continue;
    }
    if (!known.contains(second)) {
      _log('pairing.cc:82', 'Image $second does not exist.', severity: 'E', thread: 18264);
      continue;
    }
    pairs++;
  }
  final blocks = pairs == 0 ? 1 : (pairs + _importBlock - 1) ~/ _importBlock;
  for (var b = 1; b <= blocks; b++) {
    _log('pairing.cc:938', 'Processing block [$b/$blocks]', thread: 18264);
    await _step();
    _log('feature_matching.cc:218', 'in ${(20 + b % 3).toStringAsFixed(3)}s', thread: 18264);
  }
  return 0;
}

Future<int> _map(Map<String, String> options) async {
  final output = options['output_path']!;
  if (!Directory(output).existsSync()) {
    _log('sfm.cc:363', '`output_path` is not a directory.', severity: 'E', thread: 31136);
    return 1;
  }
  _log('incremental_pipeline.cc:353', 'Loading database', thread: 31136);
  final database = _database(options);
  if (database == null) {
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
    'incomplete' => [
      [for (var i = 0; i < (n * 2 ~/ 5 < 2 ? 2 : n * 2 ~/ 5); i++) i],
    ],
    'few' => [
      [for (var i = 0; i < (n ~/ 5 < 2 ? 2 : n ~/ 5); i++) i],
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
        // The images placed before this one: the third is logged at 2 (logs/c2-map.err of the measure)
        'Registering image #${model[k] + 1} (num_reg_frames=$k)',
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
  final input = options['input_path']!;
  final output = options['output_path']!;
  _log('model.cc:847', '=== Aligning Reconstruction ===', thread: 24084);
  final model = FakeColmapModel.readFrom(Directory(input));
  if (model == null) {
    _log('reconstruction.cc:910', 'Failed to read the model in $input', severity: 'E', thread: 24084);
    return 1;
  }
  if (_mode == 'fail') {
    return _fail('model.cc:860');
  }
  _log('model.cc:881', 'Using the rotation matrix:', thread: 24084);
  _log('model.cc:882', ' 0.990996  0.123359 0.0520441\n-0.123359  0.690162  0.713063\n0.0520441 -0.713063  0.699166');
  _log('model.cc:886', 'Writing aligned reconstruction...', thread: 24084);
  if (!Directory(output).existsSync()) {
    // THROW_CHECK_DIR_EXISTS of Reconstruction::WriteBinary, an exception nothing catches
    return _uncaught(
      'std::invalid_argument',
      '[reconstruction.cc:1053] Check failed: colmap::ExistsDir(path_val) Directory "$output" does not exist.',
    );
  }
  model.writeTo(Directory(output), create: false);
  return 0;
}

Future<int> _analyze(Map<String, String> options) async {
  final path = options['path']!;
  final model = FakeColmapModel.readFrom(Directory(path));
  if (model == null) {
    _log('reconstruction.cc:910', 'Failed to read the model in $path', severity: 'E', thread: 29976);
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
