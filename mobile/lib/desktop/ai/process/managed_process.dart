// The programs the AI features start and stop: sd-cli of stable-diffusion.cpp for the 360° panoramas (lot P2), and any
// later engine that runs as a program of its own (design-final 2026-10-27, section 4.5, points 2 and 3), behind
// ProcessRunner of backends.dart, so that the generator is tested with the fake runner and the fake sd-cli. A program
// started here:
//  - never outlives the app: on Windows it goes into a job object that kills it when its handle closes, the exit or the
//    crash of the app included (process_job_object.dart); on Linux it is started through immuch360-run, the launcher
//    of its archive, which sets PR_SET_PDEATHSIG before it becomes the program; and in every case its id and path go to
//    a journal, so that a program still alive at that id and path when the next runner opens is stopped;
//  - runs at a lower priority when asked: "below normal" on Windows (the priority class of its job), nice 10 elsewhere
//    (set by the launcher on Linux before the program starts its threads, process_priority.dart otherwise);
//  - gives its output and its error output line by line, a line ending at \n, \r\n or \r (sd-cli redraws its progress
//    bar with \r), without its escape sequences, read from its start whoever listens, so that a full pipe never blocks
//    it;
//  - stops within a second when killed (TerminateProcess, SIGKILL).
// The work folders of the jobs are <temp>/immuch360-ai/<job>/: deleted at the end of a job by their owner, and when the
// runner opens if older than an hour.
//
// PR_SET_PDEATHSIG follows the thread that started the child, not the process: programs are started from the main
// isolate of the app (the generator, the upscale and the probe are asynchronous, backends.dart), whose thread lasts as
// long as the app.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/process/process_job_object.dart';
import 'package:immich_mobile/desktop/ai/process/process_priority.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ManagedProcess');

/// The name of the folder of the work folders and of the journal, under the temporary folder of the system
const aiWorkFolderName = 'immuch360-ai';

/// The name of the Linux launcher in the archive of an engine
const linuxLauncherName = 'immuch360-run';

/// Starts a program: [Process.start] for the app, a fake in the tests
typedef ProcessStarter =
    Future<io.Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

Future<io.Process> _startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => io.Process.start(executable, arguments, workingDirectory: workingDirectory, environment: environment);

/// The path of the program the process [pid] runs, null when no process runs at that id (a zombie neither)
String? processImageOf(int pid) {
  if (io.Platform.isWindows) {
    return windowsProcessImage(pid);
  }
  if (io.Platform.isLinux) {
    try {
      final stat = io.File('/proc/$pid/stat').readAsStringSync();
      if (stat.substring(stat.lastIndexOf(')') + 1).trim().startsWith('Z')) {
        return null;
      }
      return io.Link('/proc/$pid/exe').resolveSymbolicLinksSync();
    } on io.FileSystemException {
      return null;
    }
  }
  final result = io.Process.runSync('ps', ['-p', '$pid', '-o', 'comm=']);
  final path = '${result.stdout}'.trim();
  return result.exitCode == 0 && path.isNotEmpty ? path : null;
}

/// Whether two paths of a program name the same file (the case apart on Windows)
bool samePrograms(String a, String b) {
  final left = p.normalize(p.absolute(a));
  final right = p.normalize(p.absolute(b));
  return io.Platform.isWindows ? left.toLowerCase() == right.toLowerCase() : left == right;
}

/// The programs started and not yet ended, in a JSON file: their ids and paths
class ProcessJournal {
  ProcessJournal(this.file, {String? Function(int pid)? imageOf, bool Function(int pid)? kill})
    : _imageOf = imageOf ?? processImageOf,
      _kill = kill ?? ((pid) => io.Process.killPid(pid, io.ProcessSignal.sigkill));

  final io.File file;
  final String? Function(int pid) _imageOf;
  final bool Function(int pid) _kill;

  /// The entries: pid and the path of the program
  List<({int pid, String path})> read() {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! List) {
        return const [];
      }
      return [
        for (final entry in json)
          if (entry is Map && entry['pid'] is int && entry['path'] is String)
            (pid: entry['pid'] as int, path: entry['path'] as String),
      ];
    } on io.FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  void _write(List<({int pid, String path})> entries) {
    try {
      file.parent.createSync(recursive: true);
      final partial = io.File('${file.path}.part');
      partial.writeAsStringSync(
        jsonEncode([
          for (final entry in entries) {'pid': entry.pid, 'path': entry.path},
        ]),
      );
      partial.renameSync(file.path);
    } on io.FileSystemException catch (error) {
      _log.warning('The journal of the programs could not be written: $error');
    }
  }

  void add(int pid, String path) => _write([...read().where((entry) => entry.pid != pid), (pid: pid, path: path)]);

  void remove(int pid) => _write(read().where((entry) => entry.pid != pid).toList());

  /// Stops every program of the journal still running at its id with its path (a program the app could not stop
  /// before it ended), then empties the journal; returns the ids stopped
  List<int> reap() {
    final stopped = <int>[];
    for (final entry in read()) {
      final image = _imageOf(entry.pid);
      if (image != null && samePrograms(image, entry.path) && _kill(entry.pid)) {
        _log.warning('Stopped ${entry.path} (process ${entry.pid}), left running by an earlier session');
        stopped.add(entry.pid);
      }
    }
    _write(const []);
    return stopped;
  }
}

/// The work folders of the jobs of the AI features that run programs: one per job, under `<temp>/immuch360-ai/`
class AiWorkFolders {
  AiWorkFolders(this.root);

  /// Under the temporary folder of the system
  factory AiWorkFolders.system() => AiWorkFolders(io.Directory(p.join(io.Directory.systemTemp.path, aiWorkFolderName)));

  final io.Directory root;

  /// The empty work folder of the job [name] (letters, digits, - and _ kept, the rest made _)
  io.Directory create(String name) {
    final folder = io.Directory(p.join(root.path, name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')));
    if (folder.existsSync()) {
      folder.deleteSync(recursive: true);
    }
    return folder..createSync(recursive: true);
  }

  /// Deletes the work folder [folder]; false when something in it could not go (a file a program still holds)
  bool delete(io.Directory folder) {
    try {
      if (folder.existsSync()) {
        folder.deleteSync(recursive: true);
      }
      return true;
    } on io.FileSystemException catch (error) {
      _log.warning('The work folder ${folder.path} could not be deleted: $error');
      return false;
    }
  }

  /// Deletes the work folders not changed for [maxAge] (an hour), those of jobs an earlier session left, and the
  /// answers of the probe of the graphics cards (`gpu-probe-<pid>-<n>.json`) a probe stopped before it could delete them
  /// left; returns how many went
  int deleteOld({Duration maxAge = const Duration(hours: 1), DateTime? now}) {
    if (!root.existsSync()) {
      return 0;
    }
    final limit = (now ?? DateTime.now()).subtract(maxAge);
    var deleted = 0;
    for (final entry in root.listSync()) {
      if (!entry.statSync().modified.isBefore(limit)) {
        continue;
      }
      if (entry is io.Directory && delete(entry)) {
        deleted++;
      } else if (entry is io.File && _probeAnswer.hasMatch(p.basename(entry.path))) {
        try {
          entry.deleteSync();
          deleted++;
        } on io.FileSystemException catch (error) {
          _log.warning('${entry.path} could not be deleted: $error');
        }
      }
    }
    return deleted;
  }

  static final _probeAnswer = RegExp(r'^gpu-probe-\d+-\d+\.json$');
}

/// The programs of the AI features in one session of the app: the journal and the work folders, read once when the
/// session opens (the programs an earlier session left running stopped, its old work folders deleted), then a runner
/// for each engine that starts programs, all writing to the same journal. [ManagedProcessRunner.open] reaps at every
/// call, which would stop the generator of this very session if a second engine opened one meanwhile (review of lot
/// P2, point 3): the app opens one session, at its first job of the graphics card.
class AiProcessSession {
  factory AiProcessSession({AiWorkFolders? folders, ProcessJournal? journal}) {
    final work = folders ?? AiWorkFolders.system();
    return AiProcessSession._(work, journal ?? ProcessJournal(io.File(p.join(work.root.path, 'processes.json'))));
  }

  AiProcessSession._(this.folders, this.journal) {
    journal.reap();
    folders.deleteOld();
  }

  final AiWorkFolders folders;
  final ProcessJournal journal;

  /// A runner on the journal of this session; on Linux its programs are started through [linuxLauncher] when given
  ManagedProcessRunner runner({String? linuxLauncher}) =>
      ManagedProcessRunner(linuxLauncher: linuxLauncher, journal: journal);
}

/// The runner of the programs of the AI features
class ManagedProcessRunner implements ProcessRunner {
  ManagedProcessRunner({
    this.linuxLauncher,
    this.journal,
    ProcessStarter? start,
    ProcessJobObjects? jobObjects,
    ProcessPriority? priority,
    bool? isWindows,
    bool? isLinux,
    int? appPid,
  }) : _start = start ?? _startProcess,
       _jobObjects = jobObjects ?? windowsJobObject,
       _priority = priority ?? const SystemProcessPriority(),
       _isWindows = isWindows ?? io.Platform.isWindows,
       _isLinux = isLinux ?? io.Platform.isLinux,
       _appPid = appPid ?? io.pid;

  /// A runner that first stops the programs an earlier session left running and deletes the work folders it left: for
  /// a program that runs once (the measure of lot P2); the app opens an [AiProcessSession] instead
  factory ManagedProcessRunner.open({String? linuxLauncher, AiWorkFolders? folders}) {
    final work = folders ?? AiWorkFolders.system();
    final journal = ProcessJournal(io.File(p.join(work.root.path, 'processes.json')));
    journal.reap();
    work.deleteOld();
    return ManagedProcessRunner(linuxLauncher: linuxLauncher, journal: journal);
  }

  /// immuch360-run of the archive of the engine, for the programs started on Linux; without it a program is started
  /// directly, and only the journal stops it if the app dies first
  final String? linuxLauncher;
  final ProcessJournal? journal;
  final ProcessStarter _start;
  final ProcessJobObjects _jobObjects;
  final ProcessPriority _priority;
  final bool _isWindows;
  final bool _isLinux;
  final int _appPid;

  /// What is started for [launch]: the program itself, or on Linux the launcher with the id of the app, the nice value
  /// when the program runs low, and the program with its arguments
  (String, List<String>) commandOf(ProcessLaunch launch) {
    final launcher = linuxLauncher;
    if (!_isLinux || launcher == null) {
      return (launch.executable, launch.arguments);
    }
    return (
      launcher,
      [
        '--parent',
        '$_appPid',
        if (launch.lowPriority) ...['--nice', '$lowProcessNice'],
        '--',
        launch.executable,
        ...launch.arguments,
      ],
    );
  }

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final (executable, arguments) = commandOf(launch);
    final process = await _start(
      executable,
      arguments,
      workingDirectory: launch.workingDirectory,
      environment: launch.environment,
    );
    ProcessJobObject? job;
    var lowered = _isLinux && linuxLauncher != null;
    if (_isWindows) {
      job = _jobObjects(lowPriority: launch.lowPriority);
      if (job != null && !job.assign(process.pid)) {
        _log.warning('${p.basename(launch.executable)} (process ${process.pid}) could not join its job object');
        job.close();
        job = null;
      }
      lowered = job != null;
      if (job == null) {
        _log.warning(
          '${p.basename(launch.executable)} runs without a job object: the journal stops it if the app dies',
        );
      }
    }
    if (launch.lowPriority && !lowered && !_priority.lower(process.pid)) {
      _log.info('The priority of ${p.basename(launch.executable)} (process ${process.pid}) could not be lowered');
    }
    journal?.add(process.pid, launch.executable);
    return ManagedRunningProcess(process, job: job, onExit: () => journal?.remove(process.pid));
  }
}

final _escape = RegExp(r'\x1B\[[0-9;?]*[A-Za-z]');

/// A line of a program without its escape sequences (the colours, and the "erase to the end of the line" of a
/// progress bar)
String withoutEscapes(String line) => line.replaceAll(_escape, '');

/// A program started by [ManagedProcessRunner]
class ManagedRunningProcess implements RunningProcess {
  ManagedRunningProcess(this._process, {this._job, void Function()? onExit}) {
    _stdout = _lines(_process.stdout);
    _stderr = _lines(_process.stderr);
    _exit = _process.exitCode.then((code) {
      _closeJob();
      onExit?.call();
      return code;
    });
  }

  final io.Process _process;
  ProcessJobObject? _job;
  late final Stream<String> _stdout;
  late final Stream<String> _stderr;
  late final Future<int> _exit;

  @override
  int get pid => _process.pid;

  @override
  Stream<String> get stdoutLines => _stdout;

  @override
  Stream<String> get stderrLines => _stderr;

  @override
  Future<int> get exitCode => _exit;

  /// Read from now on, kept until someone listens: a pipe nobody reads would block the program once full
  static Stream<String> _lines(Stream<List<int>> bytes) {
    final lines = StreamController<String>();
    bytes
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .map(withoutEscapes)
        .listen(lines.add, onError: (Object _) {}, onDone: lines.close);
    return lines.stream;
  }

  void _closeJob() {
    _job?.close();
    _job = null;
  }

  @override
  void kill() {
    _process.kill(io.ProcessSignal.sigkill);
    _closeJob();
  }
}
