// The playback of the AV2 videos on the computers (lot AD3, lib/desktop/video/av2_playback.dart): the contracts read
// without a program (the access points a restart may use, the pictures of a cut file, the stat lines, the probe, the
// options of mpv, the companion of an archive), the writes of the units held back by a companion that stops reading,
// and the session against the compiled fake companion (IMMUCH360_FAKE_AV2, a real child process of the launcher of the
// app): the y4m served whole, a seek that restarts at the access point before it with a new generation, the stop
// within a second, a companion silent for 10 s, killed, or failing on a damaged unit, the probe of a file and of a
// share, and the rule of a format too slow for this computer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/player_resource_options.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/y4m_layout.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_av2.dart';
import 'av2_test_support.dart';

Future<Av2Index> _index(Uint8List bytes) => indexAv2Stream(
  (offset, length) async => Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + length)),
  bytes.length,
);

/// A process that answers as the companion would, without being one: its lines are the test's, and its standard
/// input takes each write only when the test lets it, as a pipe the companion stopped reading
class _HeldProcess implements RunningProcess {
  _HeldProcess() {
    stdin = IOSink(_input);
  }

  final _out = StreamController<String>();
  final _exit = Completer<int>();
  final _input = _HeldConsumer();

  @override
  final int pid = 9001;

  // Closed by the session it is given to
  @override
  // ignore: close_sinks
  late final IOSink stdin;

  @override
  Stream<String> get stdoutLines => _out.stream;

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  void say(String line) => _out.add(line);

  @override
  void kill() {
    if (!_exit.isCompleted) {
      unawaited(_out.close());
      _exit.complete(-9);
    }
  }
}

/// A consumer that takes each flush only once [release] is called: the records written so far, by header
class _HeldConsumer implements StreamConsumer<List<int>> {
  final records = <(int generation, int unit, int length)>[];
  final _pending = <int>[];
  Completer<void>? _gate;
  bool open = true;

  /// Lets the pending flush through
  void release() => _gate?.complete();

  bool get waiting => _gate != null && !_gate!.isCompleted;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _pending.addAll(chunk);
    }
    while (_pending.length >= 16) {
      final header = ByteData.sublistView(Uint8List.fromList(_pending.sublist(0, 16)));
      final length = header.getUint32(12, Endian.little);
      if (_pending.length < 16 + length) {
        break;
      }
      records.add((header.getUint32(4, Endian.little), header.getUint32(8, Endian.little), length));
      _pending.removeRange(0, 16 + length);
    }
    _gate = Completer<void>();
    await _gate!.future;
  }

  @override
  Future<void> close() async => open = false;
}

/// A companion that died: its standard input breaks at the first write, and the system tells its end a moment later
/// (Windows told the broken pipe first in the CI run 41622847292)
class _DeadProcess implements RunningProcess {
  _DeadProcess() {
    stdin = IOSink(_BrokenConsumer());
  }

  final _out = StreamController<String>();
  final _exit = Completer<int>();

  @override
  final int pid = 9002;

  // Closed by the session it is given to
  @override
  // ignore: close_sinks
  late final IOSink stdin;

  @override
  Stream<String> get stdoutLines => _out.stream;

  @override
  Stream<String> get stderrLines => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  void say(String line) => _out.add(line);

  /// The end the system tells, after the pipe broke
  void end() {
    if (!_exit.isCompleted) {
      unawaited(_out.close());
      _exit.complete(-9);
    }
  }

  @override
  void kill() => Timer(const Duration(milliseconds: 50), end);
}

class _BrokenConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
    throw const SocketException('Broken pipe (OS Error: The pipe is being closed, errno = 232)');
  }

  @override
  Future<void> close() async {}
}

class _OneProcessRunner implements ProcessRunner {
  _OneProcessRunner(this.process);

  final RunningProcess process;
  final launches = <ProcessLaunch>[];

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    launches.add(launch);
    return process;
  }
}

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail('waited ${timeout.inSeconds} s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A session of a share served by a [FakeAv2ServeProcess] of [runner], once it listens
Future<(Av2Session, FakeAv2ServeProcess)> _scriptedSession(ScriptedAv2Runner runner) async {
  final starting = Av2Session.start(
    bytes: Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
    files: (program: 'immuch360-av2', launcher: null),
    runner: runner,
    decoderVersion: 'test',
    probe: () async => Av2Probe.fromJson(av2ProbeJson()),
  );
  await _until(() => runner.serves.isNotEmpty);
  final process = runner.serves.last..say(av2ListeningLine);
  return (await starting, process);
}

/// The picture numbers of the records of [bytes], the y4m of [layout] from picture [first]
List<int> _frames(Uint8List bytes, Y4mLayout layout, {bool withHeader = false}) {
  var at = withHeader ? layout.headerLength : 0;
  final frames = <int>[];
  while (at + layout.recordBytes <= bytes.length) {
    expect(ascii.decode(bytes.sublist(at, at + 6)), y4mFrameMarker);
    frames.add(fakeAv2FrameOf(Uint8List.sublistView(bytes, at + 6), layout.bits));
    at += layout.recordBytes;
  }
  return frames;
}

void main() {
  group('without a program', () {
    test('an AV2 video by its extension, on a path or the path of a URL', () {
      expect(isAv2VideoPath(r'C:\Vidéos\phare.ivf'), isTrue);
      expect(isAv2VideoPath('/home/u/clips/WorldCup.OBU'), isTrue);
      expect(isAv2VideoPath('/token/smb-1/clips/a.ivf'), isTrue);
      expect(isAv2VideoPath('/clips/a.mp4'), isFalse);
      expect(isAv2VideoPath('/clips/ivf'), isFalse);
      expect(isAv2VideoPath('/clips.ivf/a.mkv'), isFalse);
    });

    test('the companion of an archive: the program in the folder of the component, or beside the file given', () {
      expect(
        av2CompanionFilesIn(
          r'C:\c\engines\av2-decoder-windows-x64',
          windows: true,
          linux: false,
          isFolder: (_) => true,
        ),
        (program: r'C:\c\engines\av2-decoder-windows-x64\immuch360-av2.exe', launcher: null),
      );
      expect(
        av2CompanionFilesIn('/c/engines/av2-decoder-linux-x64', windows: false, linux: true, isFolder: (_) => true),
        (
          program: '/c/engines/av2-decoder-linux-x64/immuch360-av2',
          launcher: '/c/engines/av2-decoder-linux-x64/immuch360-run',
        ),
      );
      // Once the catalogue lists the files of the archive, the service gives one of them
      expect(
        av2CompanionFilesIn(
          '/c/engines/av2-decoder-linux-x64/immuch360-run',
          windows: false,
          linux: true,
          isFolder: (_) => false,
        ).program,
        '/c/engines/av2-decoder-linux-x64/immuch360-av2',
      );
    });

    test(
      'a restart may begin only at a key unit that carries its sequence header, below the pictures served',
      () async {
        final index = await _index(av2Fixture('av2-256x144-8bit.ivf'));
        expect(av2AccessPoints(index, 12), [0, 6]);
        expect(av2AccessPoints(index, 6), [0], reason: 'unit 6 is not served');
        // A key unit without its header (the companion empties its decoder at each restart): not an access point
        final stripped = Av2Index(
          head: index.head,
          fileLength: index.fileLength,
          units: [
            for (final unit in index.units)
              unit.index == 6
                  ? Av2Unit(
                      index: 6,
                      offset: unit.offset,
                      length: unit.length,
                      obuTypes: [
                        for (final type in unit.obuTypes)
                          if (type != Av2ObuType.sequenceHeader) type,
                      ],
                      packet: unit.packet,
                    )
                  : unit,
          ],
          packets: index.packets,
          end: index.end,
          endOffset: index.endOffset,
        );
        expect(av2AccessPoints(stripped, 12), [0]);
      },
    );

    test('a file cut short serves the pictures before its first cut packet, not every whole unit', () async {
      final cut = await _index(av2Fixture('av2-256x144-8bit-cut.ivf'));
      expect(cut.frameCount, 8);
      expect(av2FramesOf(cut), 7, reason: 'the 8th whole unit codes picture 11');
      final whole = await _index(av2Fixture('av2-256x144-8bit.ivf'));
      expect(av2FramesOf(whole), 12);
    });

    test('a stat line', () {
      final stat = Av2Stat.parse('stat decoded=151 served=140 fps=232.4 simd=avx2 gen=3 frame=140 serving=1')!;
      expect(
        (stat.decoded, stat.served, stat.fps, stat.simd, stat.generation, stat.frame, stat.serving),
        (151, 140, 232.4, 'avx2', 3, 140, true),
      );
      expect(Av2Stat.parse('need 2 60'), isNull);
      expect(Av2Stat.parse('stat decoded=x'), isNull);
    });

    test('the probe of the companion: the first picture, the refusal, the colours', () {
      final plain = Av2Probe.fromJson(av2ProbeJson());
      expect(
        (plain.width, plain.height, plain.bits, plain.playable, plain.colour, plain.fullRange),
        (256, 144, 8, true, null, false),
      );
      final refused = Av2Probe.fromJson(av2ProbeJson(bits: 12, playable: false, refusal: '4:2:0 12-bit'));
      expect((refused.playable, refused.refusal, refused.width), (false, '4:2:0 12-bit', null));
      final described = Av2Probe.fromJson(
        av2ProbeJson(color: const {'description': true, 'primaries': 9, 'transfer': 16, 'matrix': 9, 'range': 'full'}),
      );
      expect(described.colour, (primaries: 9, transfer: 16, matrix: 9));
      expect(described.fullRange, isTrue);
      expect(() => Av2Probe.fromJson(const {'error': 'x'}), throwsFormatException);
    });

    test('mpv reads the y4m without a probe, with a cache of a second at least, up to 512 MiB, its colours, and waits '
        'a second after a stall', () {
      final hd = Y4mLayout(width: 1920, height: 1080, bits: 8, fpsNumerator: 30, fpsDenominator: 1, frames: 151);
      final uhd10 = Y4mLayout(width: 4096, height: 2160, bits: 10, fpsNumerator: 24, fpsDenominator: 1, frames: 51);
      final uhd8 = Y4mLayout(width: 3840, height: 2160, bits: 8, fpsNumerator: 30, fpsDenominator: 1, frames: 60);
      expect(av2CacheBytes(hd), 256 * 1024 * 1024, reason: '86 pictures, 2.9 s');
      expect(av2CacheBytes(uhd8), uhd8.recordBytes * 30, reason: '256 MiB hold 21 pictures: a second asked');
      expect(av2CacheBytes(uhd10), 512 * 1024 * 1024, reason: 'a second would be 637 MB');
      expect(av2MpvOptions(hd, null), {
        'demuxer-lavf-format': 'yuv4mpegpipe',
        'demuxer-max-bytes': '268435456',
        // A second of video after a stall until the decoder's speed is known, mpv's own, not the 5 s of a network
        'cache-pause-wait': '1',
      });
      expect(
        av2MpvOptions(hd, (primaries: 1, transfer: 1, matrix: 1))['vf'],
        'format=colormatrix=bt.709:primaries=bt.709:gamma=bt.1886',
      );
      expect(
        av2MpvOptions(hd, (primaries: 9, transfer: 16, matrix: 9))['vf'],
        'format=colormatrix=bt.2020-ncl:primaries=bt.2020:gamma=pq',
      );
      expect(
        av2MpvOptions(hd, (primaries: 2, transfer: 2, matrix: 2)).containsKey('vf'),
        isFalse,
        reason: 'unspecified',
      );
    });

    test('the URL of a companion', () {
      expect(isAv2CompanionUrl('http://127.0.0.1:52011/AbCdEfGhIjKlMnOp0123456789abcdef/video.y4m'), isTrue);
      expect(isAv2CompanionUrl('http://127.0.0.1:52011/AbCdEfGhIjKlMnOp0123456789abcdef/smb-1/video.y4m'), isFalse);
      expect(isAv2CompanionUrl('http://10.0.0.2:52011/AbCdEfGhIjKlMnOp0123456789abcdef/video.y4m'), isFalse);
    });

    test('a format below 0.95 times the speed of its video is too slow', () {
      const format = Av2Format(width: 4096, height: 2160, bits: 10, frameRate: 24);
      expect(av2IsTooSlow(const Av2SpeedMeasure(format: format, fps: 7.4, decoder: 'd')), isTrue);
      expect(av2IsTooSlow(const Av2SpeedMeasure(format: format, fps: 22.7, decoder: 'd')), isTrue);
      expect(
        av2IsTooSlow(const Av2SpeedMeasure(format: format, fps: 23.7, decoder: 'd')),
        isFalse,
        reason: '0.99x',
      );
      expect(av2IsTooSlow(null), isFalse, reason: 'without a measure the video plays, and the rule of the link waits');
      expect(
        const Av2TooSlow(fps: 7.4, needed: 24, key: 'k').message,
        'This computer decodes this AV2 video at about 7 frames per second and it needs 24: it will pause to catch up',
      );
      final json = const Av2SpeedMeasure(format: format, fps: 7.4, decoder: '30140b5-1').toJson();
      final back = Av2SpeedMeasure.fromJson(jsonDecode(jsonEncode(json)) as Map<String, Object?>);
      expect((back.format, back.fps, back.decoder), (format, 7.4, '30140b5-1'));
    });
  });

  group('the units written', () {
    test('one record at a time: a companion that stops reading holds the app back, and a newer generation drops the '
        'rest of the older one', () async {
      final bytes = av2Fixture('av2-256x144-8bit.ivf');
      final process = _HeldProcess();
      final runner = _OneProcessRunner(process);
      final starting = Av2Session.start(
        bytes: Av2Bytes.share(MemoryShare(bytes), '/clips/video.ivf'),
        files: (program: 'immuch360-av2', launcher: null),
        runner: runner,
        decoderVersion: 'test',
        probe: () async => Av2Probe.fromJson(av2ProbeJson()),
      );
      await _until(() => runner.launches.isNotEmpty);
      final launch = runner.launches.single;
      expect(launch.lowPriority, isFalse, reason: 'playback is the task in front');
      expect(launch.arguments.take(1), ['serve']);
      expect(launch.arguments.join(' '), contains('--width 256 --height 144 --bits 8 --fps 30/1 --frames 12'));
      // The token in the companion's environment, never on its command line, which every account of the computer
      // reads (n1 of the second review of lot AD2)
      expect(launch.arguments, isNot(contains('--token')));
      final token = launch.environment['IMMUCH360_AV2_TOKEN'];
      expect(token, matches(RegExp(r'^[A-Za-z0-9]{32}$')));
      process.say('listening 50123 address=127.0.0.1 length=663626 header=63 frame=55296 frames=12');
      final session = await starting;
      expect(session.url.toString(), 'http://127.0.0.1:50123/$token/video.y4m');
      expect(isAv2CompanionUrl(session.url.toString()), isTrue);

      // The index first, held until the pipe takes it
      await _until(() => process._input.waiting);
      expect(process._input.records, [(0, av2IndexUnit, 8)]);
      process._input.release();
      process.say('need 1 0');
      await _until(() => process._input.records.length == 2 && process._input.waiting);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      List<(int, int)> written() => [for (final (generation, unit, _) in process._input.records) (generation, unit)];
      expect(written().last, (1, 0), reason: 'unit 0 written, unit 1 waits for the pipe');
      expect(process._input.records, hasLength(2));
      process._input.release();
      await _until(() => process._input.records.length == 3 && process._input.waiting);
      // A seek: generation 2 from unit 6, the rest of generation 1 never written
      process.say('need 2 6');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      process._input.release();
      await _until(() => process._input.records.length == 4 && process._input.waiting);
      expect(written().sublist(1), [(1, 0), (1, 1), (2, 6)]);
      for (var i = 0; i < 6; i++) {
        process._input.release();
        await _until(() => process._input.waiting);
      }
      expect(written().sublist(4), [(2, 7), (2, 8), (2, 9), (2, 10), (2, 11), (2, 12)]);
      expect(process._input.records.last.$3, 0, reason: 'the end record after the last unit');

      // Stopped while a write waits: killed, its input never closed by a flush in the middle
      final watch = Stopwatch()..start();
      await session.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(session.isRunning, isFalse);
      expect(session.failure.value, isNull, reason: 'asked to stop');
    });
  });

  group('a companion that died', () {
    test('its input broken before its end is told: the video says how it ended, not that its file went away', () async {
      final process = _DeadProcess();
      final runner = _OneProcessRunner(process);
      final starting = Av2Session.start(
        bytes: Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
        files: (program: 'immuch360-av2', launcher: null),
        runner: runner,
        decoderVersion: 'test',
        probe: () async => Av2Probe.fromJson(av2ProbeJson()),
      );
      await _until(() => runner.launches.isNotEmpty);
      process.say('listening 50123 address=127.0.0.1 length=663626 header=63 frame=55296 frames=12');
      final session = await starting;
      addTearDown(session.stop);
      // The index could not be written: the pipe broke; the system tells the end 300 ms later
      Timer(const Duration(milliseconds: 300), process.end);
      await _until(() => session.failure.value != null);
      expect(session.failure.value, contains('(code -9)'));
      expect(session.isRunning, isFalse);
    });

    test('killed while it served: its end in words, without the lines of its protocol', () async {
      final runner = ScriptedAv2Runner();
      final (session, process) = await _scriptedSession(runner);
      addTearDown(session.stop);
      process
        ..say('request bytes=0-663625 frame=0')
        ..say('need 1 0')
        ..say('stat decoded=4 served=3 fps=0.0 simd=avx2 gen=1 frame=3 serving=1');
      await _until(() => session.stat.value != null);
      // Killed by another program, or by the system short of memory: the review of lot AD3 saw "immuch360-av2 ended
      // with -9: listening 52771 ... / request bytes=0-... / need 1 0" in three lines of the failure panel
      process.kill();
      await _until(() => session.failure.value != null);
      final failure = session.failure.value!;
      for (final protocol in ['listening', 'request', 'need', 'stat', 'immuch360-av2', '\n']) {
        expect(failure, isNot(contains(protocol)));
      }
      expect(failure, contains('(code -9)'));
      if (!Platform.isWindows) {
        expect(failure, 'it was stopped (code -9)');
      }
    });

    test('a crash after a line of its own: its end in words, and that line', () async {
      final runner = ScriptedAv2Runner();
      final (session, process) = await _scriptedSession(runner);
      addTearDown(session.stop);
      process
        ..say('request bytes=0-663625 frame=0')
        ..say('dav2d: assertion failed in lr_apply')
        ..say('need 1 0')
        ..end(-6);
      await _until(() => session.failure.value != null);
      expect(session.failure.value, endsWith('(code -6): dav2d: assertion failed in lr_apply'));
      if (!Platform.isWindows) {
        expect(session.failure.value, 'it crashed (code -6): dav2d: assertion failed in lr_apply');
      }
    });
  });

  group('the speed of the decoder', () {
    test('the stat lines: the speed the companion measured, or while it says 0.0 and serves, the pictures it decodes '
        'against the clock', () async {
      final process = _HeldProcess();
      final runner = _OneProcessRunner(process);
      final starting = Av2Session.start(
        bytes: Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
        files: (program: 'immuch360-av2', launcher: null),
        runner: runner,
        decoderVersion: 'test',
        probe: () async => Av2Probe.fromJson(av2ProbeJson()),
      );
      await _until(() => runner.launches.isNotEmpty);
      process.say('listening 50123 address=127.0.0.1 length=663626 header=63 frame=55296 frames=12');
      final session = await starting;
      addTearDown(session.stop);
      expect(session.speed.value, isNull);
      expect(session.decoding, (fps: null, needed: 30.0, failure: null));

      // A player that reads at the pace of the video from the start: no run long enough for the companion to measure
      // (mobile/native/av2/README.md, stat), so the pictures decoded a second while it serves
      process.say('stat decoded=4 served=3 fps=0.0 simd=avx2 gen=1 frame=3 serving=1');
      await _until(() => session.stat.value?.decoded == 4);
      expect(session.speed.value, isNull, reason: 'one line says no speed');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      process.say('stat decoded=19 served=18 fps=0.0 simd=avx2 gen=1 frame=18 serving=1');
      await _until(() => session.stat.value?.decoded == 19);
      expect(session.speed.value, inInclusiveRange(15 / 0.8, 15 / 0.45));
      expect(session.measuredFps, isNull, reason: 'a paced count is no measure of this computer');
      // Nothing served (a pause): the count starts again, the last speed stays
      final paced = session.speed.value;
      process.say('stat decoded=19 served=18 fps=0.0 simd=avx2 gen=1 frame=18 serving=0');
      await _until(() => session.stat.value?.serving == false);
      expect(session.speed.value, paced);
      // The companion's own measure wins and is kept
      process.say('stat decoded=80 served=60 fps=232.4 simd=avx2 gen=2 frame=60 serving=1');
      await _until(() => session.stat.value?.decoded == 80);
      expect((session.speed.value, session.measuredFps), (232.4, 232.4));
      expect(session.decoding.fps, 232.4);
    });
  });

  group('the speed of a decoder slower than the video', () {
    test('counted against the clock while the player takes every picture, it is a measure of this computer', () async {
      final process = _HeldProcess();
      final runner = _OneProcessRunner(process);
      final starting = Av2Session.start(
        bytes: Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
        files: (program: 'immuch360-av2', launcher: null),
        runner: runner,
        decoderVersion: 'test',
        probe: () async => Av2Probe.fromJson(av2ProbeJson()),
      );
      await _until(() => runner.launches.isNotEmpty);
      process.say('listening 50123 address=127.0.0.1 length=663626 header=63 frame=55296 frames=12');
      final session = await starting;
      addTearDown(session.stop);
      Future<void> stat(int decoded, int served, {bool serving = true}) async {
        process.say(
          'stat decoded=$decoded served=$served fps=0.0 simd=avx2 gen=1 frame=$served serving=${serving ? 1 : 0}',
        );
        await _until(() => session.stat.value?.decoded == decoded && session.stat.value?.served == served);
      }

      // Paused: nothing decoded nor served, no measure (the companion never timed a run: cosmos 4K in 10 bits on the
      // PC on 3 November, its player waiting for every picture, kept no speed and the notice never came)
      await stat(10, 9);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await stat(10, 9);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await stat(10, 9);
      expect(session.measuredFps, isNull);
      // 6 pictures a second for a video of 30, every one taken by the player at once: the decoder sets the pace
      for (var i = 1; i <= 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await stat(10 + 3 * i, 9 + 3 * i);
      }
      expect(session.measuredFps, isNotNull);
      expect(session.measuredFps, inInclusiveRange(2, 6.5), reason: "9 pictures in 1.5 s, the test's delays at least");
      expect(session.tooSlow, isTrue);
    });

    test('a count that the player paces, or that a seek spends on pictures it drops, is no measure', () async {
      final process = _HeldProcess();
      final runner = _OneProcessRunner(process);
      final starting = Av2Session.start(
        bytes: Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
        files: (program: 'immuch360-av2', launcher: null),
        runner: runner,
        decoderVersion: 'test',
        probe: () async => Av2Probe.fromJson(av2ProbeJson()),
      );
      await _until(() => runner.launches.isNotEmpty);
      process.say('listening 50123 address=127.0.0.1 length=663626 header=63 frame=55296 frames=12');
      final session = await starting;
      addTearDown(session.stop);
      Future<void> stat(int decoded, int served) async {
        process.say('stat decoded=$decoded served=$served fps=0.0 simd=avx2 gen=1 frame=$served serving=1');
        await _until(() => session.stat.value?.decoded == decoded && session.stat.value?.served == served);
      }

      // At the pace of the video (15 a half second): what the player reads, not what the decoder can
      for (var i = 0; i <= 4; i++) {
        await stat(15 * i, 15 * i);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(session.measuredFps, isNull);
      // A seek: 40 pictures decoded to reach the one asked, 1 served
      for (var i = 1; i <= 4; i++) {
        await stat(60 + 10 * i, 61);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(session.measuredFps, isNull);
    });
  });

  group('the measure a session keeps', () {
    test('its best: a start measured low beside the thumbnails is settled by a later measure that keeps up', () async {
      final process = _HeldProcess();
      final runner = _OneProcessRunner(process);
      final starting = Av2Session.start(
        bytes: Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
        files: (program: 'immuch360-av2', launcher: null),
        runner: runner,
        decoderVersion: 'test',
        probe: () async => Av2Probe.fromJson(av2ProbeJson()),
      );
      await _until(() => runner.launches.isNotEmpty);
      process.say('listening 50123 address=127.0.0.1 length=663626 header=63 frame=55296 frames=12');
      final session = await starting;
      addTearDown(session.stop);
      expect((session.bestMeasuredFps, session.measureSettled), (null, false));
      // Skater in 10 bits on the PC on 3 November: 16.9 at the start, 36.8 at the end, for a video of 30
      process.say('stat decoded=20 served=18 fps=16.9 simd=avx2 gen=1 frame=18 serving=1');
      await _until(() => session.measuredFps == 16.9);
      expect(
        session.measureSettled,
        isFalse,
        reason: 'too slow, measured for less than ${av2SlowVerdictAfter.inSeconds} s',
      );
      process.say('stat decoded=40 served=38 fps=36.8 simd=avx2 gen=1 frame=38 serving=1');
      await _until(() => session.measuredFps == 36.8);
      expect((session.bestMeasuredFps, session.measureSettled), (36.8, true));
      process.say('stat decoded=60 served=58 fps=31.0 simd=avx2 gen=1 frame=58 serving=1');
      await _until(() => session.measuredFps == 31.0);
      expect(session.bestMeasuredFps, 36.8, reason: 'what this computer can, not its last moment');
    });

    test('too slow, it is settled after ${av2SlowVerdictAfter.inSeconds} s of measures only', () async {
      final process = _HeldProcess();
      final runner = _OneProcessRunner(process);
      final starting = Av2Session.start(
        bytes: Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
        files: (program: 'immuch360-av2', launcher: null),
        runner: runner,
        decoderVersion: 'test',
        probe: () async => Av2Probe.fromJson(av2ProbeJson()),
      );
      await _until(() => runner.launches.isNotEmpty);
      process.say('listening 50123 address=127.0.0.1 length=663626 header=63 frame=55296 frames=12');
      final session = await starting;
      addTearDown(session.stop);
      process.say('stat decoded=5 served=4 fps=7.4 simd=avx2 gen=1 frame=4 serving=1');
      await _until(() => session.measuredFps == 7.4);
      expect(session.measureSettled, isFalse);
      await Future<void>.delayed(av2SlowVerdictAfter);
      process.say('stat decoded=9 served=8 fps=7.2 simd=avx2 gen=1 frame=8 serving=1');
      await _until(() => session.measuredFps == 7.2);
      expect((session.bestMeasuredFps, session.measureSettled), (7.4, true));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('on the compiled fake companion', () {
    late Directory folder;
    late ManagedProcessRunner runner;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('av2-playback-');
      runner = ManagedProcessRunner(journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))));
    });
    tearDown(() => folder.deleteSync(recursive: true));

    Av2CompanionFiles files() => (program: fakeAv2Program!, launcher: null);

    Future<Av2Session> start(Uint8List bytes, {Map<String, String> environment = const {}, bool share = false}) async {
      final File file = File(p.join(folder.path, 'clip.ivf'))..writeAsBytesSync(bytes);
      return Av2Session.start(
        bytes: share ? Av2Bytes.share(MemoryShare(bytes), '/clips/clip.ivf') : Av2Bytes.file(file.path),
        files: files(),
        runner: EnvironmentRunner(runner, environment),
        decoderVersion: 'fake',
        parentPid: pid,
      );
    }

    test('the y4m served whole: our header at the rate of the IVF, the pictures in order, its length known', () async {
      final session = await start(av2Fixture('av2-256x144-8bit.ivf'));
      addTearDown(session.stop);
      final layout = session.layout;
      expect(layout.header, 'YUV4MPEG2 W256 H144 F30:1 Ip A1:1 C420 XCOLORRANGE=LIMITED\n');
      final all = await readAv2Url(session.url);
      expect(all.length, layout.length);
      expect(ascii.decode(all.sublist(0, layout.headerLength)), layout.header);
      expect(_frames(all, layout, withHeader: true), List.generate(12, (i) => i));
      expect(session.failure.value, isNull);
    }, skip: skipWithoutFakeAv2);

    test('a seek restarts at the access point before the picture asked, with a new generation each time', () async {
      final session = await start(repeatAv2Ivf(av2Fixture('av2-256x144-8bit.ivf'), 10));
      addTearDown(session.stop);
      final layout = session.layout;
      expect(layout.frames, 120);
      expect(session.accessPoints, List.generate(20, (i) => 6 * i));
      // Picture 100: the companion starts again at 96
      var bytes = await readAv2Url(session.url, start: layout.offsetOf(100), length: 3 * layout.recordBytes);
      expect(_frames(bytes, layout), [100, 101, 102]);
      await _until(() => (session.stat.value?.generation ?? 0) >= 1);
      final first = session.stat.value!.generation;
      // Back to picture 8: a newer generation from unit 6
      bytes = await readAv2Url(session.url, start: layout.offsetOf(8), length: 2 * layout.recordBytes);
      expect(_frames(bytes, layout), [8, 9]);
      await _until(() => session.stat.value!.generation > first);
      // From the middle of picture 9, to its end and the next
      bytes = await readAv2Url(session.url, start: layout.offsetOf(9) + 1000, length: layout.recordBytes * 2 - 1000);
      expect(fakeAv2FrameOf(Uint8List.sublistView(bytes, layout.recordBytes - 1000 + 6), 8), 10);
      expect(session.failure.value, isNull);
    }, skip: skipWithoutFakeAv2);

    test('a share: the probe on its first bytes through the standard input, the units read through it', () async {
      final share = MemoryShare(av2Fixture('av2-256x144-10bit.ivf'));
      final probe = await runAv2Probe(
        EnvironmentRunner(runner, {'IMMUCH360_FAKE_AV2_BITS': '10'}),
        files(),
        Av2Bytes.share(share, '/clips/clip.ivf'),
      );
      expect((probe.width, probe.height, probe.bits, probe.playable), (256, 144, 10, true));
      final session = await start(share.bytes, share: true, environment: {'IMMUCH360_FAKE_AV2_BITS': '10'});
      addTearDown(session.stop);
      expect(session.layout.header, contains('C420p10'));
      final all = await readAv2Url(session.url);
      expect(_frames(all, session.layout, withHeader: true), List.generate(12, (i) => i));
    }, skip: skipWithoutFakeAv2);

    test('the player closed: the standard input closes, the companion is gone within a second', () async {
      final session = await start(repeatAv2Ivf(av2Fixture('av2-256x144-8bit.ivf'), 10));
      await readAv2Url(session.url, length: session.layout.headerLength + session.layout.recordBytes);
      final pid = session.pid!;
      expect(processImageOf(pid), isNotNull);
      final watch = Stopwatch()..start();
      await session.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(processImageOf(pid), isNull);
      expect(session.failure.value, isNull);
    }, skip: skipWithoutFakeAv2);

    test(
      'silent for 10 s: stopped, and the video says the decoder stopped',
      () async {
        final session = await start(
          av2Fixture('av2-256x144-8bit.ivf'),
          environment: {'IMMUCH360_FAKE_AV2_MODE': 'silent'},
        );
        addTearDown(session.stop);
        final pid = session.pid!;
        await _until(() => session.failure.value != null, timeout: const Duration(seconds: 15));
        expect(session.failure.value, contains('wrote nothing for 10 s'));
        expect(session.decoding.failure, session.failure.value);
        await _until(() => processImageOf(pid) == null, timeout: const Duration(seconds: 2));
      },
      skip: skipWithoutFakeAv2,
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test('killed by something else: the video says the decoder stopped', () async {
      final session = await start(repeatAv2Ivf(av2Fixture('av2-256x144-8bit.ivf'), 10));
      addTearDown(session.stop);
      await readAv2Url(session.url, length: session.layout.headerLength + session.layout.recordBytes);
      Process.killPid(session.pid!, ProcessSignal.sigkill);
      await _until(() => session.failure.value != null, timeout: const Duration(seconds: 5));
      // A signal on Linux, TerminateProcess and its -1 on Windows; never the lines of its protocol
      expect(session.failure.value, Platform.isWindows ? 'it was stopped (code -1)' : 'it was stopped (code -9)');
      expect(session.isRunning, isFalse);
    }, skip: skipWithoutFakeAv2);

    test('a unit the decoder stops on: the error line names it, the app stays', () async {
      final session = await start(
        av2Fixture('av2-256x144-8bit.ivf'),
        environment: {'IMMUCH360_FAKE_AV2_MODE': 'fail', 'IMMUCH360_FAKE_AV2_FAIL_AT': '3'},
      );
      addTearDown(session.stop);
      final bytes = await readAv2Url(session.url, start: session.layout.headerLength, cut: true);
      expect(_frames(bytes, session.layout), [0, 1, 2]);
      await _until(() => session.failure.value != null);
      expect(session.failure.value, 'dav2d error -22 at picture 3');
    }, skip: skipWithoutFakeAv2);

    test('the playbacks of the app: the setting, the decoder, the measure kept, a format too slow, Play anyway, the '
        'release', () async {
      final bytes = repeatAv2Ivf(av2Fixture('av2-256x144-8bit.ivf'), 10);
      final file = File(p.join(folder.path, 'clip.ivf'))..writeAsBytesSync(bytes);
      var on = true;
      Av2CompanionFiles? installed = files();
      final kept = <Av2SpeedMeasure>[];
      Av2SpeedMeasure? last;
      final launched = EnvironmentRunner(runner, {'IMMUCH360_FAKE_AV2_FPS': '600'});
      final playbacks = Av2Playbacks(
        companion: () async => installed,
        runner: (launcher) => launched,
        enabled: () => on,
        decoderVersion: 'fake-1',
        loadMeasure: (format, decoder) async => last,
        recordMeasure: (measure) async => kept.add(measure),
        parentPid: pid,
      );
      on = false;
      await expectLater(playbacks.open(Av2Bytes.file(file.path)), throwsA(isA<Av2TurnedOff>()));
      on = true;
      installed = null;
      await expectLater(playbacks.open(Av2Bytes.file(file.path)), throwsA(isA<Av2DecoderMissing>()));
      installed = files();

      final url = await playbacks.open(Av2Bytes.file(file.path));
      final session = playbacks.sessionOf(url)!;
      expect(desktopResourceOptions[url]?['demuxer-lavf-format'], 'yuv4mpegpipe');
      expect(playbacks.decodingOf(url)?.needed, 30);
      await readAv2Url(Uri.parse(url));
      await _until(() => kept.isNotEmpty, timeout: const Duration(seconds: 10));
      expect(kept.first.format, const Av2Format(width: 256, height: 144, bits: 8, frameRate: 30));
      expect(kept.first.decoder, 'fake-1');
      expect(kept.first.fps, greaterThan(100));
      expect(playbacks.decodingOf(url)?.fps, greaterThan(100));
      final companion = session.pid!;
      await playbacks.release(url);
      expect(processImageOf(companion), isNull);
      expect(playbacks.sessionOf(url), isNull);
      expect(desktopResourceOptions.containsKey(url), isFalse);
      expect(kept, hasLength(2), reason: 'the last speed kept at the release too');

      // Measured at 7 of the 30 a second it needs: it does not play by itself, no companion serves it
      last = Av2SpeedMeasure(format: kept.first.format, fps: 7, decoder: 'fake-1');
      final serves = launched.launches.where((launch) => launch.arguments.first == 'serve').length;
      final refusal = await playbacks
          .open(Av2Bytes.file(file.path))
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(refusal, isA<Av2TooSlow>().having((e) => e.fps, 'fps', 7).having((e) => e.needed, 'needed', 30));
      expect(playbacks.sessions, isEmpty);
      expect(launched.launches.where((launch) => launch.arguments.first == 'serve'), hasLength(serves));
      // The thumbnail does not ask, and its companion runs at a low priority: the player's start comes first (two
      // grabs and the playback at once when a file is opened with the app, measured on the PC on 3 November)
      final thumbnail = await playbacks.open(Av2Bytes.file(file.path), forThumbnail: true);
      final serveLaunches = launched.launches.where((launch) => launch.arguments.first == 'serve').toList();
      expect(serveLaunches.first.lowPriority, isFalse, reason: 'the player');
      expect(serveLaunches.last.lowPriority, isTrue, reason: 'the thumbnail');
      await readAv2Url(Uri.parse(thumbnail));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await playbacks.release(thumbnail);
      expect(kept, hasLength(2), reason: 'a thumbnail measures nothing');
      playbacks.playAnyway((refusal! as Av2TooSlow).key);
      final anyway = await playbacks.open(Av2Bytes.file(file.path));
      await playbacks.releaseAll();
      expect(playbacks.sessionOf(anyway), isNull);
    }, skip: skipWithoutFakeAv2);

    test('a session too slow and closed early keeps no measure; one that keeps up keeps its best at once', () async {
      final file = File(p.join(folder.path, 'clip.ivf'))
        ..writeAsBytesSync(repeatAv2Ivf(av2Fixture('av2-256x144-8bit.ivf'), 10));
      final kept = <Av2SpeedMeasure>[];
      var fps = '12';
      final playbacks = Av2Playbacks(
        companion: () async => files(),
        runner: (launcher) => EnvironmentRunner(runner, {'IMMUCH360_FAKE_AV2_FPS': fps}),
        enabled: () => true,
        decoderVersion: 'fake-1',
        recordMeasure: (measure) async => kept.add(measure),
        parentPid: pid,
      );
      // 12 of the 30 a second, closed after a second of measures: a start, no verdict
      var url = await playbacks.open(Av2Bytes.file(file.path));
      unawaited(readAv2Url(Uri.parse(url), cut: true).then((_) {}, onError: (Object _) {}));
      await _until(() => playbacks.sessionOf(url)!.measuredFps != null);
      await playbacks.release(url);
      expect(kept, isEmpty);
      // At 600 a second: kept at once, and at the release
      fps = '600';
      url = await playbacks.open(Av2Bytes.file(file.path));
      await readAv2Url(Uri.parse(url));
      await _until(() => kept.isNotEmpty);
      expect(kept.single.fps, greaterThan(100));
      await playbacks.release(url);
      expect(kept, hasLength(2));
    }, skip: skipWithoutFakeAv2);

    test('a format this version does not play is refused by its name', () async {
      final playbacks = Av2Playbacks(
        companion: () async => files(),
        runner: (launcher) => EnvironmentRunner(runner, {'IMMUCH360_FAKE_AV2_BITS': '12'}),
        enabled: () => true,
      );
      final file = File(p.join(folder.path, 'clip.ivf'))..writeAsBytesSync(av2Fixture('av2-256x144-8bit.ivf'));
      await expectLater(
        playbacks.open(Av2Bytes.file(file.path)),
        throwsA(
          isA<Av2FormatRefused>().having(
            (e) => e.message,
            'message',
            'This AV2 video is 4:2:0 12-bit: this version of the AV2 decoder does not play it yet',
          ),
        ),
      );
      expect(playbacks.sessions, isEmpty);
    }, skip: skipWithoutFakeAv2);

    test('an IVF of AV1 is no AV2: the player gets the file itself', () async {
      final file = File(p.join(folder.path, 'av1.ivf'))..writeAsBytesSync(av2Fixture('av1-256x144-8bit.ivf'));
      final playbacks = Av2Playbacks(companion: () async => files(), runner: (_) => runner, enabled: () => true);
      await expectLater(playbacks.open(Av2Bytes.file(file.path)), throwsA(isA<Av2NotAv2>()));
    }, skip: skipWithoutFakeAv2);
  });
}
