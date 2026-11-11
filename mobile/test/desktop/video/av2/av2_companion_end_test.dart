// What the app says of an AV2 companion that ended, and the threads it is given (lot AD3, its review's m1 and M1): the
// exit code in words, the lines of its protocol left out of a failure, and the threads of IMMUCH360_AV2_THREADS.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';

import 'av2_test_support.dart';

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail('waited 10 s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('an exit code in words: a signal on Linux and macOS', () {
    expect(av2EndedReason(-9, windows: false), 'it was stopped (code -9)');
    expect(av2EndedReason(-15, windows: false), 'it was stopped (code -15)');
    expect(av2EndedReason(-11, windows: false), 'it crashed (code -11)');
    expect(av2EndedReason(-6, windows: false), 'it crashed (code -6)');
    expect(av2EndedReason(-10, windows: false), 'it ended on a signal (code -10)');
  });

  test('an exit code in words: TerminateProcess and the exceptions of Windows', () {
    // Process.kill and the end of a task: -1, which Dart may give as the unsigned 4294967295
    expect(av2EndedReason(-1, windows: true), 'it was stopped (code -1)');
    expect(av2EndedReason(0xffffffff, windows: true), 'it was stopped (code -1)');
    // An access violation, as a signed and as an unsigned 32-bit number
    expect(av2EndedReason(-1073741819, windows: true), 'it crashed (code 0xC0000005)');
    expect(av2EndedReason(0xc0000409, windows: true), 'it crashed (code 0xC0000409)');
  });

  test("an exit code in words: the companion's own (the README of immuch360/av2-companion)", () {
    for (final windows in [true, false]) {
      expect(av2EndedReason(1, windows: windows), 'it ran short of memory or threads (code 1)');
      expect(av2EndedReason(2, windows: windows), 'it did not understand the app (code 2)');
      expect(av2EndedReason(3, windows: windows), 'it could not decode this video (code 3)');
      expect(av2EndedReason(4, windows: windows), 'it could not listen on 127.0.0.1 (code 4)');
      expect(av2EndedReason(5, windows: windows), 'it did not understand the app (code 5)');
      expect(av2EndedReason(42, windows: windows), 'it ended (code 42)');
      expect(av2EndedReason(-9, windows: true), 'it ended (code -9)', reason: 'no signal on Windows');
    }
  });

  test('the lines of the protocol say where the companion was, not why it ended', () {
    for (final line in [
      'listening 52771 address=127.0.0.1 length=66362459 header=59 frame=55296 frames=1200',
      'request bytes=0-66362458 frame=0',
      'need 1 0',
      'stat decoded=4 served=3 fps=0.0 simd=avx2 gen=1 frame=3 serving=1',
      'refused token',
      'exit input-closed',
      'error decode dav2d error -22 at picture 1',
      '{"error": "not an AV2 stream"}',
    ]) {
      expect(av2LineSaysWhy(line), isFalse, reason: line);
    }
    expect(av2LineSaysWhy('dav2d: assertion failed in lr_apply'), isTrue);
    expect(av2SidecarProgram.inTail, isNotNull);
  });

  test('the threads of the decoder: dav2d chooses, or IMMUCH360_AV2_THREADS says how many', () async {
    expect(av2ThreadsFrom(const {}), isNull);
    expect(av2ThreadsFrom(const {av2ThreadsVariable: '8'}), 8);
    expect(av2ThreadsFrom(const {av2ThreadsVariable: '0'}), isNull);
    expect(av2ThreadsFrom(const {av2ThreadsVariable: 'all'}), isNull);
    expect(av2ThreadsFrom(const {av2ThreadsVariable: '1000'}), isNull);

    Future<List<String>> serveArguments(int? threads) async {
      final runner = ScriptedAv2Runner();
      final playbacks = Av2Playbacks(
        companion: () async => (program: 'immuch360-av2', launcher: null),
        runner: (_) => runner,
        enabled: () => true,
        threads: threads,
      );
      final opening = playbacks.open(
        Av2Bytes.share(MemoryShare(av2Fixture('av2-256x144-8bit.ivf')), '/clips/video.ivf'),
      );
      await _until(() => runner.serves.isNotEmpty);
      runner.serves.single.say(av2ListeningLine);
      await playbacks.release(await opening);
      return runner.launchesOf('serve').single.arguments;
    }

    expect((await serveArguments(8)).join(' '), contains('--threads 8'));
    expect(await serveArguments(null), isNot(contains('--threads')));
  });
}
