// The run of one program of the AI features to its end, read as it goes (plan 2026-11-01, section 2.4; design
// engineering-first of 1 November 2026, section 4.4): sd-cli of stable-diffusion.cpp for the 360° panoramas (lot P2),
// COLMAP and Brush for the splat scenes (lot SP4). It was _SdCppRun of gen/sdcpp_runner.dart, moved here as it was, so
// that the three programs share one watch, tested once:
//  - the program is started by a ProcessRunner (managed_process.dart in the app: a job object on Windows, immuch360-run
//    on Linux, so that no program outlives the app), at a low priority, in the folder it is given;
//  - each line of either output goes to the caller, which may stop the run with a failure of its own (another graphics
//    card or a panic for Brush; sd-cli cutting its graph into segments goes on since lot 13c), and is remembered for
//    the message of a failure: the last lines of the error output, or of the output when the error output said nothing;
//  - the cancel flag and the silence are looked at every 200 ms: cancelled, the program is killed within a second;
//    silent for longer than its program allows (180 s for sd-cli, 600 s for COLMAP, 300 s for Brush), it is killed and
//    the run fails as stalled, with the last lines it wrote; the caller may look too at each tick (Brush, held by
//    Windows Error Reporting after a panic, is killed without waiting for its end);
//  - an exit code other than 0 is named: out of memory when a line said so, otherwise failed with the end of the
//    output, the code kept on the failure (SidecarFailure), so that COLMAP can start again with fewer threads after a
//    crash for want of memory;
//  - each line is written to a log file when one is given (the logs a splat scene keeps in its work folder);
//  - the messages name the program by its label: its name, or the command of it that runs ("COLMAP (mapper)"), so
//    that a failure says which of a program's commands went wrong.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';

/// What a program is to its run: its name in the messages, the failures it is named by, the texts of its output that
/// mean the memory was short, and which of its lines a failure may carry
class SidecarProgram {
  const SidecarProgram({
    required this.name,
    required this.failed,
    required this.stalled,
    this.outOfMemory = ImmersiveErrorCode.gpuOutOfMemory,
    this.outOfMemoryTexts = const [],
    this.tailLines = 20,
    this.inTail,
  });

  /// "sd-cli", "COLMAP", "Brush"
  final String name;

  /// An exit code other than 0, and a program that could not start
  final ImmersiveErrorCode failed;

  /// Silent for longer than the run allows
  final ImmersiveErrorCode stalled;

  /// An exit code other than 0 after a line holding one of [outOfMemoryTexts]
  final ImmersiveErrorCode outOfMemory;
  final List<String> outOfMemoryTexts;

  /// The most lines of the end of the output a failure carries in its message
  final int tailLines;

  /// Whether a line may be in that end; every line that is not empty when null (sd-cli leaves its bars out)
  final bool Function(String line)? inTail;
}

/// A run that ended with an exit code other than 0, the code kept ([exitCode]); null when the program never started
class SidecarFailure extends BackendException {
  const SidecarFailure(super.code, super.message, {this.exitCode});

  final int? exitCode;
}

/// A clock for the silence of a program: the time since it was made
Duration Function() sidecarStopwatch() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

/// One run of a program to its end, read as it goes (see the top of this file)
class SidecarRun {
  SidecarRun({
    required this.runner,
    required this.program,
    required this.launch,
    required this.cancel,
    required this.elapsed,
    required this.onLine,
    this.stallTimeout = const Duration(seconds: 180),
    this.pollInterval = const Duration(milliseconds: 200),
    this.onTick,
    this.onStarted,
    this.log,
    String? label,
  }) : label = label ?? program.name;

  final ProcessRunner runner;
  final SidecarProgram program;
  final ProcessLaunch launch;
  final NativeCancelFlag cancel;
  final Duration Function() elapsed;

  /// Each line of either output; returns a failure to stop the run with, or null to go on
  final BackendException? Function(String line, {required bool isError}) onLine;

  /// Stopped and named [SidecarProgram.stalled] after this long without a line on either output
  final Duration stallTimeout;

  /// How often the cancel flag and the silence are looked at
  final Duration pollInterval;

  /// At each look; returns a failure to stop the run with, or null to go on
  final BackendException? Function()? onTick;

  /// Once the program runs, with its process id
  final void Function(int pid)? onStarted;

  /// Where each line is written as it comes, when given (appended)
  final File? log;

  /// The program in the messages: its name by default, "COLMAP (exhaustive_matcher)" for a command of COLMAP
  final String label;

  final _errorTail = <String>[];
  final _outputTail = <String>[];
  var _outOfMemory = false;
  BackendException? _stop;

  /// The end of the error output, or of the output when the error output said nothing
  String get tail => (_errorTail.isNotEmpty ? _errorTail : _outputTail).join('\n');

  void _remember(List<String> tail, String line) {
    final keep = program.inTail;
    if (line.trim().isEmpty || (keep != null && !keep(line))) {
      return;
    }
    tail.add(line);
    if (tail.length > program.tailLines) {
      tail.removeAt(0);
    }
  }

  Future<void> run() async {
    final name = label;
    if (cancel.isCancelled) {
      throw BackendException(ImmersiveErrorCode.cancelled, 'Cancelled before $name started');
    }
    final RunningProcess process;
    try {
      process = await runner.start(launch);
    } on ProcessException catch (error) {
      throw SidecarFailure(program.failed, '$name could not start: ${error.message}');
    }
    onStarted?.call(process.pid);
    RandomAccessFile? logFile;
    try {
      logFile = log?.openSync(mode: FileMode.append);
    } on FileSystemException {
      // The run goes on without its log
    }
    var lastLine = elapsed();
    void stop(BackendException reason) {
      if (_stop == null) {
        _stop = reason;
        process.kill();
      }
    }

    void read(String line, {required bool isError}) {
      try {
        logFile?.writeStringSync('$line\n');
      } on FileSystemException {
        logFile = null;
      }
      // Once stopped, what was still in the pipes says nothing more: no progress after a refusal
      if (_stop != null) {
        return;
      }
      lastLine = elapsed();
      _remember(isError ? _errorTail : _outputTail, line);
      if (program.outOfMemoryTexts.any(line.contains)) {
        _outOfMemory = true;
      }
      final failure = onLine(line, isError: isError);
      if (failure != null) {
        stop(failure);
      }
    }

    final outputs = [
      process.stdoutLines.listen((line) => read(line, isError: false)).asFuture<void>(),
      process.stderrLines.listen((line) => read(line, isError: true)).asFuture<void>(),
    ];
    final watch = Timer.periodic(pollInterval, (_) {
      if (cancel.isCancelled) {
        stop(const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled'));
      } else if (elapsed() - lastLine > stallTimeout) {
        final said = tail;
        stop(
          BackendException(
            program.stalled,
            '$name wrote nothing for ${stallTimeout.inSeconds} s and was stopped'
            '${said.isEmpty ? '' : '; its last lines:\n$said'}',
          ),
        );
      } else if (_stop == null) {
        final failure = onTick?.call();
        if (failure != null) {
          stop(failure);
        }
      }
    });
    final int code;
    try {
      code = await process.exitCode;
      await Future.wait(outputs).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    } finally {
      watch.cancel();
      try {
        logFile?.closeSync();
      } on FileSystemException {
        // Nothing more to write
      }
    }
    final stopped = _stop;
    if (stopped != null) {
      throw stopped;
    }
    if (code != 0) {
      throw _outOfMemory
          ? SidecarFailure(program.outOfMemory, tail, exitCode: code)
          : SidecarFailure(program.failed, '$name ended with $code: $tail', exitCode: code);
    }
  }
}
