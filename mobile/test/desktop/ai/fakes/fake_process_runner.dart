// Programs started without starting any (the seam ProcessRunner of lib/desktop/ai/engine/backends.dart), for the
// tests of the generator and of the probe (lots P2, C6, P3): each launch is recorded, and the process it gives plays
// the lines its script holds on its output and its error output, then exits with its code; or stays silent until the
// test kills it, as a stalled generator. A real executable is tested with the compiled fake sd-cli (lot P2).

import 'dart:async';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';

/// What a fake process does: its lines in order (stdout, or stderr with [isError]), its exit code, and whether it
/// stays silent after its lines until killed
class FakeProcessScript {
  const FakeProcessScript({this.lines = const [], this.exitCode = 0, this.hangs = false});

  final List<(String, {bool isError})> lines;
  final int exitCode;
  final bool hangs;
}

/// A process of the fake runner
class FakeRunningProcess implements RunningProcess {
  FakeRunningProcess(this.pid, this.launch, this.script) {
    scheduleMicrotask(_play);
  }

  @override
  final int pid;
  final ProcessLaunch launch;
  final FakeProcessScript script;
  final _out = StreamController<String>();
  final _err = StreamController<String>();
  final _exit = Completer<int>();
  bool killed = false;

  /// The exit code of a killed process, as SIGKILL leaves it
  static const killedCode = -9;

  @override
  Stream<String> get stdoutLines => _out.stream;

  @override
  Stream<String> get stderrLines => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  Future<void> _play() async {
    for (final (line, :isError) in script.lines) {
      if (killed) {
        return;
      }
      (isError ? _err : _out).add(line);
      await Future<void>.delayed(Duration.zero);
    }
    if (!script.hangs && !killed) {
      await _end(script.exitCode);
    }
  }

  Future<void> _end(int code) async {
    if (_exit.isCompleted) {
      return;
    }
    // Not awaited: a stream nobody listens to finishes closing only once listened to
    unawaited(_out.close());
    unawaited(_err.close());
    _exit.complete(code);
  }

  /// Writes [line] on the output (or the error output with [isError]) of a process still running, as a long job does
  /// now and then
  void emit(String line, {bool isError = false}) {
    if (!_exit.isCompleted) {
      (isError ? _err : _out).add(line);
    }
  }

  @override
  void kill() {
    killed = true;
    unawaited(_end(killedCode));
  }
}

/// Starts fake processes: [scripts] in turn, the last one again after them
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner(List<FakeProcessScript> scripts) : _scripts = List.of(scripts);

  final List<FakeProcessScript> _scripts;

  /// Every launch and every process, in order
  final launches = <ProcessLaunch>[];
  final processes = <FakeRunningProcess>[];
  var _pid = 4000;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    launches.add(launch);
    final script = _scripts.length > 1 ? _scripts.removeAt(0) : _scripts.single;
    final process = FakeRunningProcess(++_pid, launch, script);
    processes.add(process);
    return process;
  }
}
