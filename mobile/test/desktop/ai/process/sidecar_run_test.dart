// The run of a program shared by sd-cli, COLMAP and Brush (lib/desktop/ai/process/sidecar_run.dart, lot SP4), with the
// fake runner: each line given with its output, a failure of the caller that stops the program, the silence on a fake
// clock, the cancel flag, the end of the output a failure carries, the exit code kept, the texts of a memory too short,
// the look at each tick, the process id, the log file. The tests of sd-cli (test/desktop/ai/gen) are those of before
// the move, unchanged.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/process/sidecar_run.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_process_runner.dart';

const _program = SidecarProgram(
  name: 'COLMAP',
  failed: ImmersiveErrorCode.posesFailed,
  stalled: ImmersiveErrorCode.posesStalled,
  outOfMemory: ImmersiveErrorCode.outOfMemory,
  outOfMemoryTexts: ['std::bad_alloc'],
  tailLines: 3,
);

class _FailingRunner implements ProcessRunner {
  @override
  Future<RunningProcess> start(ProcessLaunch launch) async => throw const ProcessException('colmap', [], 'not found');
}

void main() {
  late NativeCancelFlag cancel;

  setUp(() => cancel = NativeCancelFlag());
  tearDown(() => cancel.free());

  SidecarRun run(
    ProcessRunner runner, {
    BackendException? Function(String line, {required bool isError})? onLine,
    BackendException? Function()? onTick,
    Duration Function()? elapsed,
    SidecarProgram program = _program,
    void Function(int pid)? onStarted,
    File? log,
  }) => SidecarRun(
    runner: runner,
    program: program,
    launch: const ProcessLaunch(executable: 'colmap', arguments: ['mapper'], workingDirectory: '/work'),
    cancel: cancel,
    elapsed: elapsed ?? sidecarStopwatch(),
    onLine: onLine ?? (line, {required isError}) => null,
    onTick: onTick,
    onStarted: onStarted,
    stallTimeout: const Duration(seconds: 600),
    log: log,
  );

  test('gives each line with its output and ends quietly on 0; the launch is the one it was given', () async {
    final runner = FakeProcessRunner([
      const FakeProcessScript(lines: [('out 1', isError: false), ('err 1', isError: true), ('out 2', isError: false)]),
    ]);
    final lines = <(String, bool)>[];
    int? started;
    await run(
      runner,
      onLine: (line, {required isError}) {
        lines.add((line, isError));
        return null;
      },
      onStarted: (pid) => started = pid,
    ).run();
    expect(lines, [('out 1', false), ('err 1', true), ('out 2', false)]);
    expect(started, runner.processes.single.pid);
    final launch = runner.launches.single;
    expect((launch.executable, launch.workingDirectory, launch.lowPriority), ('colmap', '/work', true));
    expect(launch.arguments, ['mapper']);
  });

  test('a failure of the caller kills the program and is what the run throws; nothing more is read', () async {
    final runner = FakeProcessRunner([
      const FakeProcessScript(
        lines: [('a', isError: false), ('stop', isError: false), ('b', isError: false)],
        hangs: true,
      ),
    ]);
    final seen = <String>[];
    await expectLater(
      run(
        runner,
        onLine: (line, {required isError}) {
          seen.add(line);
          return line == 'stop' ? const BackendException(ImmersiveErrorCode.gpuUnavailable, 'another card') : null;
        },
      ).run(),
      throwsA(
        isA<BackendException>()
            .having((e) => e.code, 'code', ImmersiveErrorCode.gpuUnavailable)
            .having((e) => e.message, 'message', 'another card'),
      ),
    );
    expect(runner.processes.single.killed, isTrue);
    expect(seen, ['a', 'stop']);
  });

  test(
    'an exit code other than 0 is the failure of the program, with the end of the error output and the code',
    () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: [
            ('progress', isError: false),
            for (var k = 1; k <= 5; k++) ('error $k', isError: true),
            ('', isError: true),
          ],
          exitCode: 1,
        ),
      ]);
      await expectLater(
        run(runner).run(),
        throwsA(
          isA<SidecarFailure>()
              .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
              .having((e) => e.exitCode, 'exitCode', 1)
              .having((e) => e.message, 'message', 'COLMAP ended with 1: error 3\nerror 4\nerror 5'),
        ),
      );
    },
  );

  test('without an error output, the end of the output; the lines the program leaves out are not in it', () async {
    final runner = FakeProcessRunner([
      const FakeProcessScript(
        lines: [('one', isError: false), ('|== 3/9 bar', isError: false), ('two', isError: false)],
        exitCode: -1073741819,
      ),
    ]);
    const program = SidecarProgram(
      name: 'sd-cli',
      failed: ImmersiveErrorCode.generatorFailed,
      stalled: ImmersiveErrorCode.generatorStalled,
      inTail: _noBar,
    );
    await expectLater(
      run(runner, program: program).run(),
      throwsA(
        isA<SidecarFailure>()
            .having((e) => e.exitCode, 'exitCode', -1073741819)
            .having((e) => e.message, 'message', 'sd-cli ended with -1073741819: one\ntwo'),
      ),
    );
  });

  test('a text of a memory too short, then an exit code other than 0: out of memory, the code kept', () async {
    final runner = FakeProcessRunner([
      const FakeProcessScript(
        lines: [
          ('Processed file [3/9]', isError: true),
          ("terminate called after throwing an instance of 'std::bad_alloc'", isError: true),
        ],
        exitCode: -6,
      ),
    ]);
    await expectLater(
      run(runner).run(),
      throwsA(
        isA<SidecarFailure>()
            .having((e) => e.code, 'code', ImmersiveErrorCode.outOfMemory)
            .having((e) => e.exitCode, 'exitCode', -6)
            .having((e) => e.message, 'message', contains('std::bad_alloc')),
      ),
    );
  });

  test('a program that cannot start fails as its program does, with no exit code', () async {
    await expectLater(
      run(_FailingRunner()).run(),
      throwsA(
        isA<SidecarFailure>()
            .having((e) => e.code, 'code', ImmersiveErrorCode.posesFailed)
            .having((e) => e.exitCode, 'exitCode', isNull)
            .having((e) => e.message, 'message', 'COLMAP could not start: not found'),
      ),
    );
  });

  test('silent for its time on the clock, it is stopped as stalled; a second less is not enough', () {
    fakeAsync((async) {
      final runner = FakeProcessRunner([
        const FakeProcessScript(lines: [('start', isError: true)], hangs: true),
      ]);
      Object? failure;
      unawaited(
        run(runner, elapsed: () => async.elapsed).run().then<void>((_) {}, onError: (Object error) => failure = error),
      );
      async.elapse(const Duration(seconds: 599));
      expect(failure, isNull);
      expect(runner.processes.single.killed, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(runner.processes.single.killed, isTrue);
      expect(
        failure,
        isA<BackendException>()
            .having((e) => e.code, 'code', ImmersiveErrorCode.posesStalled)
            .having((e) => e.message, 'message', 'COLMAP wrote nothing for 600 s and was stopped'),
      );
    });
  });

  test('cancelled, it is stopped within the interval of the watch; cancelled before, nothing starts', () async {
    fakeAsync((async) {
      final runner = FakeProcessRunner([const FakeProcessScript(hangs: true)]);
      Object? failure;
      unawaited(run(runner).run().then<void>((_) {}, onError: (Object error) => failure = error));
      async.elapse(const Duration(seconds: 3));
      cancel.cancel();
      async.elapse(const Duration(milliseconds: 250));
      expect(runner.processes.single.killed, isTrue);
      expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled));
    });
    final runner = FakeProcessRunner([const FakeProcessScript()]);
    await expectLater(
      run(runner).run(),
      throwsA(
        isA<BackendException>()
            .having((e) => e.code, 'code', ImmersiveErrorCode.cancelled)
            .having((e) => e.message, 'message', 'Cancelled before COLMAP started'),
      ),
    );
    expect(runner.launches, isEmpty);
  });

  test('a failure the caller finds at a tick stops the program within the interval', () {
    fakeAsync((async) {
      final runner = FakeProcessRunner([
        const FakeProcessScript(lines: [('panicked at', isError: true)], hangs: true),
      ]);
      var panicked = false;
      Object? failure;
      unawaited(
        run(
          runner,
          onLine: (line, {required isError}) {
            panicked = true;
            return null;
          },
          onTick: () => panicked ? const BackendException(ImmersiveErrorCode.trainingFailed, 'panic') : null,
        ).run().then<void>((_) {}, onError: (Object error) => failure = error),
      );
      async.elapse(const Duration(milliseconds: 250));
      expect(runner.processes.single.killed, isTrue);
      expect(failure, isA<BackendException>().having((e) => e.message, 'message', 'panic'));
    });
  });

  test('every line goes to the log file, appended, the lines after a stop too', () async {
    final folder = Directory.systemTemp.createTempSync('sidecar-log-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final log = File(p.join(folder.path, 'colmap-mapping.log'))..writeAsStringSync('before\n');
    final runner = FakeProcessRunner([
      const FakeProcessScript(lines: [('é 1', isError: true), ('stop', isError: false), ('after', isError: true)]),
    ]);
    await expectLater(
      run(
        runner,
        log: log,
        onLine: (line, {required isError}) =>
            line == 'stop' ? const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled') : null,
      ).run(),
      throwsA(isA<BackendException>()),
    );
    expect(log.readAsStringSync(), startsWith('before\né 1\nstop\n'));
  });
}

bool _noBar(String line) => !line.contains('bar');
