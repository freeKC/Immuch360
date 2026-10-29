// The launcher of the programs of the AI features (lot P2): the command it starts (the Linux launcher with the id of the
// app and the nice value), the job object on Windows, the priority, the journal and its reaping, the work folders, and
// the lines it reads (a progress bar redrawn with \r, the escapes). With real processes: a program killed within a
// second, and the compiled fake sd-cli (IMMUCH360_FAKE_SD_CLI) started by a host that is killed: its child must die
// with it, by the job object on Windows and by immuch360-run (IMMUCH360_RUN_LAUNCHER) on Linux.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/process/process_job_object.dart';
import 'package:immich_mobile/desktop/ai/process/process_priority.dart';
import 'package:path/path.dart' as p;

/// A process that writes what it is given and ends when told
class _FakeProcess implements Process {
  _FakeProcess(this.pid);

  @override
  final int pid;
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  final _exit = Completer<int>();
  final signals = <ProcessSignal>[];

  void end(int code) {
    unawaited(out.close());
    unawaited(err.close());
    if (!_exit.isCompleted) {
      _exit.complete(code);
    }
  }

  @override
  Stream<List<int>> get stdout => out.stream;

  @override
  Stream<List<int>> get stderr => err.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    end(-9);
    return true;
  }
}

class _FakeJob implements ProcessJobObject {
  _FakeJob({required this.lowPriority, this.accepts = true});

  final bool lowPriority;
  final bool accepts;
  final assigned = <int>[];
  var closed = 0;

  @override
  bool assign(int pid) {
    assigned.add(pid);
    return accepts;
  }

  @override
  void close() => closed++;
}

class _FakePriority implements ProcessPriority {
  final lowered = <int>[];

  @override
  bool lower(int pid) {
    lowered.add(pid);
    return true;
  }
}

/// The compiled fake sd-cli, and the Linux launcher, when the CI or the owner gave them
final _fakeSdCli = Platform.environment['IMMUCH360_FAKE_SD_CLI'];
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('managed-process-'));
  tearDown(() => folder.deleteSync(recursive: true));

  group('the command', () {
    const launch = ProcessLaunch(executable: '/engines/sd/sd-cli', arguments: ['-o', 'out.png']);

    test('on Linux with the launcher: the id of the app, nice 10 when low, then the program and its arguments', () {
      final runner = ManagedProcessRunner(linuxLauncher: '/engines/sd/immuch360-run', isLinux: true, appPid: 4242);
      final (executable, arguments) = runner.commandOf(launch);
      expect(executable, '/engines/sd/immuch360-run');
      expect(arguments, ['--parent', '4242', '--nice', '10', '--', '/engines/sd/sd-cli', '-o', 'out.png']);
      expect(runner.commandOf(const ProcessLaunch(executable: 'sd-cli', lowPriority: false)).$2, [
        '--parent',
        '4242',
        '--',
        'sd-cli',
      ]);
    });

    test('elsewhere, or without a launcher: the program itself', () {
      for (final runner in [
        ManagedProcessRunner(isLinux: true),
        ManagedProcessRunner(linuxLauncher: '/engines/sd/immuch360-run', isLinux: false),
      ]) {
        final (executable, arguments) = runner.commandOf(launch);
        expect(executable, '/engines/sd/sd-cli');
        expect(arguments, ['-o', 'out.png']);
      }
    });
  });

  group('a start', () {
    late List<_FakeProcess> started;
    late List<_FakeJob> jobs;
    late _FakePriority priority;
    late ProcessJournal journal;

    ManagedProcessRunner runner({required bool windows, bool linux = false, String? launcher, bool accepts = true}) {
      started = [];
      jobs = [];
      priority = _FakePriority();
      journal = ProcessJournal(File(p.join(folder.path, 'processes.json')));
      return ManagedProcessRunner(
        linuxLauncher: launcher,
        journal: journal,
        isWindows: windows,
        isLinux: linux,
        appPid: 1,
        priority: priority,
        jobObjects: ({required bool lowPriority}) {
          final job = _FakeJob(lowPriority: lowPriority, accepts: accepts);
          jobs.add(job);
          return job;
        },
        start: (executable, arguments, {workingDirectory, environment}) async {
          final process = _FakeProcess(5000 + started.length);
          started.add(process);
          return process;
        },
      );
    }

    test(
      'on Windows: the program joins a job of its own, low through the job, the journal holds it until it ends',
      () async {
        final process = await runner(windows: true).start(const ProcessLaunch(executable: r'C:\e\sd-cli.exe'));
        expect(jobs.single.assigned, [5000]);
        expect(jobs.single.lowPriority, isTrue);
        expect(priority.lowered, isEmpty);
        expect(journal.read(), [(pid: 5000, path: r'C:\e\sd-cli.exe')]);
        started.single.end(0);
        expect(await process.exitCode, 0);
        expect(jobs.single.closed, 1);
        expect(journal.read(), isEmpty);
      },
    );

    test('on Windows, refused by the job: the job is closed, the priority lowered another way', () async {
      await runner(windows: true, accepts: false).start(const ProcessLaunch(executable: 'sd-cli.exe'));
      expect(jobs.single.closed, 1);
      expect(priority.lowered, [5000]);
    });

    test('killed: the signal, then the job closed; a program not low is not lowered', () async {
      final process = await runner(windows: true).start(const ProcessLaunch(executable: 'a.exe', lowPriority: false));
      expect(jobs.single.lowPriority, isFalse);
      process.kill();
      expect(started.single.signals, [ProcessSignal.sigkill]);
      expect(jobs.single.closed, greaterThanOrEqualTo(1));
      expect(await process.exitCode, -9);
    });

    test('on Linux through the launcher, which lowers it; without the launcher, lowered after its start', () async {
      await runner(
        windows: false,
        linux: true,
        launcher: '/e/immuch360-run',
      ).start(const ProcessLaunch(executable: 'x'));
      expect(jobs, isEmpty);
      expect(priority.lowered, isEmpty);
      await runner(windows: false, linux: true).start(const ProcessLaunch(executable: 'x'));
      expect(priority.lowered, [5000]);
    });

    test(
      'its lines: a bar redrawn with \\r gives one line a step, without its escapes; read before anyone listens',
      () async {
        final process = await runner(windows: false).start(const ProcessLaunch(executable: 'x'));
        final fake = started.single;
        fake.out.add(utf8.encode('[I] loading\n\r  |=>   |  1/20 - 8.33s/it - ETA 03:41\x1B[K\r  |==>  |  2/'));
        fake.out.add(utf8.encode('20 - 8.39s/it\x1B[K\r  |===| 20/20 - 8.50s/it\x1B[K\n\x1B[34;1m[I]\x1B[0m done\r\n'));
        fake.err.add([...utf8.encode('[E] caf'), 0xC3, 0xA9, 0x20, 0xFF, 0x0A]);
        fake.end(0);
        await Future<void>.delayed(Duration.zero);
        expect(await process.stdoutLines.toList(), [
          '[I] loading',
          // The line end of the log line, then the \r of the first redraw: an empty line between them, as sd-cli writes
          '',
          '  |=>   |  1/20 - 8.33s/it - ETA 03:41',
          '  |==>  |  2/20 - 8.39s/it',
          '  |===| 20/20 - 8.50s/it',
          '[I] done',
        ]);
        expect(await process.stderrLines.toList(), ['[E] café \uFFFD']);
      },
    );
  });

  group('the journal', () {
    test('stops a program still running at its id with its path, then forgets everything', () {
      final killed = <int>[];
      final images = {10: '/e/sd-cli', 11: '/usr/bin/other', 12: null};
      final journal = ProcessJournal(
        File(p.join(folder.path, 'j', 'processes.json')),
        imageOf: (pid) => images[pid],
        kill: (pid) {
          killed.add(pid);
          return true;
        },
      );
      journal.add(10, '/e/sd-cli');
      journal.add(11, '/e/sd-cli');
      journal.add(12, '/e/sd-cli');
      journal.add(13, '/e/sd-cli');
      journal.remove(13);
      expect(journal.read().map((entry) => entry.pid), [10, 11, 12]);
      expect(journal.reap(), [10]);
      expect(killed, [10]);
      expect(journal.read(), isEmpty);
      // A damaged journal is an empty one
      journal.file.writeAsStringSync('{not json');
      expect(journal.read(), isEmpty);
      expect(journal.reap(), isEmpty);
    });

    test('the path of a running program, null for an id that runs nothing', () {
      expect(processImageOf(pid), isNotNull);
      expect(samePrograms(processImageOf(pid)!, Platform.resolvedExecutable), isTrue);
      expect(processImageOf(0x7FFFFFF0), isNull);
    });
  });

  group('the work folders', () {
    test('one per job under the root, deleted at its end, those older than an hour deleted at the next start', () {
      final folders = AiWorkFolders(Directory(p.join(folder.path, aiWorkFolderName)));
      final job = folders.create('panorama 1/2');
      expect(p.basename(job.path), 'panorama_1_2');
      File(p.join(job.path, 'control.png')).writeAsStringSync('x');
      expect(folders.create('panorama 1/2').listSync(), isEmpty);
      final old = folders.create('old');
      expect(folders.deleteOld(now: DateTime.now().add(const Duration(minutes: 30))), 0);
      expect(folders.deleteOld(now: DateTime.now().add(const Duration(minutes: 61))), 2);
      expect(old.existsSync(), isFalse);
      expect(folders.delete(job), isTrue);
      expect(AiWorkFolders.system().root.path, p.join(Directory.systemTemp.path, 'immuch360-ai'));
    });

    test('the answer of a probe of the graphics cards an earlier session left is deleted with the old folders', () {
      final folders = AiWorkFolders(Directory(p.join(folder.path, aiWorkFolderName)));
      folders.root.createSync(recursive: true);
      final probe = File(p.join(folders.root.path, 'gpu-probe-4242-3.json'))..writeAsStringSync('{}');
      final journal = File(p.join(folders.root.path, 'processes.json'))..writeAsStringSync('[]');
      final other = File(p.join(folders.root.path, 'notes.json'))..writeAsStringSync('{}');
      expect(folders.deleteOld(now: DateTime.now().add(const Duration(minutes: 30))), 0);
      expect(probe.existsSync(), isTrue);
      expect(folders.deleteOld(now: DateTime.now().add(const Duration(minutes: 61))), 1);
      expect(probe.existsSync(), isFalse);
      expect(journal.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
    });
  });

  group('a session of the app', () {
    test('the programs an earlier session left are stopped once, never those this session starts', () {
      final killed = <int>[];
      final images = {10: '/e/sd-cli', 20: '/e/sd-cli'};
      final root = Directory(p.join(folder.path, aiWorkFolderName));
      final journal = ProcessJournal(
        File(p.join(root.path, 'processes.json')),
        imageOf: (pid) => images[pid],
        kill: (pid) {
          killed.add(pid);
          return true;
        },
      );
      journal.add(10, '/e/sd-cli');
      final session = AiProcessSession(folders: AiWorkFolders(root), journal: journal);
      expect(killed, [10]);
      // sd-cli of this session runs, and a second engine asks for a runner meanwhile
      final first = session.runner(linuxLauncher: '/e/immuch360-run');
      journal.add(20, '/e/sd-cli');
      final second = session.runner();
      expect(killed, [10]);
      expect(journal.read().map((entry) => entry.pid), [20]);
      expect(first.journal, same(journal));
      expect(second.journal, same(journal));
      expect(first.linuxLauncher, '/e/immuch360-run');
    });
  });

  group('real programs', () {
    test('a program killed is gone within a second', () async {
      final runner = ManagedProcessRunner(journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))));
      final (executable, arguments) = Platform.isWindows
          ? ('powershell.exe', ['-NoProfile', '-Command', 'Start-Sleep -Seconds 60'])
          : ('/bin/sh', ['-c', 'exec sleep 60']);
      final process = await runner.start(ProcessLaunch(executable: executable, arguments: arguments));
      unawaited(process.stdoutLines.drain<void>());
      unawaited(process.stderrLines.drain<void>());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(processImageOf(process.pid), isNull);
    }, skip: Platform.isMacOS ? 'the programs of the AI features run on Windows and Linux' : false);

    test(
      'the fake sd-cli started by a host that is killed dies with it',
      () async {
        final pidFile = p.join(folder.path, 'child.pid');
        final host = await Process.start(
          _fakeSdCli!,
          ['host', pidFile],
          environment: {'IMMUCH360_RUN_LAUNCHER': ?_launcher},
        );
        unawaited(host.stdout.drain<void>());
        unawaited(host.stderr.drain<void>());
        final waited = Stopwatch()..start();
        while (!File(pidFile).existsSync() || File(pidFile).readAsStringSync().isEmpty) {
          expect(waited.elapsed, lessThan(const Duration(seconds: 20)), reason: 'the host never wrote its child');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final child = int.parse(File(pidFile).readAsStringSync());
        expect(processImageOf(child), isNotNull, reason: 'the child runs');
        expect(samePrograms(processImageOf(child)!, _fakeSdCli!), isTrue);
        Process.killPid(host.pid, ProcessSignal.sigkill);
        await host.exitCode.timeout(const Duration(seconds: 5));
        final gone = Stopwatch()..start();
        while (processImageOf(child) != null && gone.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (processImageOf(child) != null) {
          Process.killPid(child, ProcessSignal.sigkill);
          fail('the child $child outlived its host');
        }
        expect(gone.elapsed, lessThan(const Duration(seconds: 2)));
      },
      skip: _fakeSdCli == null
          ? 'no compiled fake sd-cli (IMMUCH360_FAKE_SD_CLI)'
          : Platform.isLinux && _launcher == null
          ? 'no immuch360-run (IMMUCH360_RUN_LAUNCHER)'
          : Platform.isMacOS
          ? 'the programs of the AI features run on Windows and Linux'
          : false,
    );
  });
}
