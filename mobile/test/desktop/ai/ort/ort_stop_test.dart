// The stop of a run of ONNX Runtime from another isolate (lot C1, design-final 2026-10-27 sections 2.5 and 10.1
// point 3): the slow tiny model, a loop of matrix products of minutes, ended within a second of the stop asked by
// another isolate through its own binding (ort_terminate.dart), and the run turned into OrtRunStopped; the options
// stopped once stay stopped, fresh ones run; nothing native left behind.

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:path/path.dart' as p;

import 'ort_for_tests.dart';

/// Turns of the slow model that would take a minute or more: the stop must end them long before
const _endless = 240000;

/// Starts another isolate that waits [delay], raises the stop, and sends to the port it gives the time it did
Future<ReceivePort> _stopFromAnotherIsolate(OrtRunStopHandle handle, Duration delay) async {
  final port = ReceivePort();
  await Isolate.spawn(_stopLater, (handle, delay, port.sendPort));
  return port;
}

void _stopLater((OrtRunStopHandle, Duration, SendPort) message) {
  final (handle, delay, port) = message;
  sleep(delay);
  final at = DateTime.now().microsecondsSinceEpoch;
  OrtRunStopper(handle).stop();
  port.send(at);
}

void main() {
  test('a stop needs the library: the flag is raised, then the reason is given', () {
    final asked = calloc<Int32>();
    addTearDown(() => calloc.free(asked));
    final missing = p.join(Directory.systemTemp.path, 'immuch360-no-ort', 'libonnxruntime.so');
    final stopper = OrtRunStopper(
      OrtRunStopHandle(libraryPath: missing, optionsAddress: 0, askedAddress: asked.address),
    );

    expect(stopper.stop, throwsA(isA<OrtLoadException>()));
    expect((stopper.stopped, asked.value), (true, 1));
    // Once only
    stopper.stop();
  });

  final ort = ortForTests();
  group('ONNX Runtime from IMMUCH360_ORT_LIB', () {
    late OrtRuntime runtime;
    late int size;

    setUpAll(() {
      runtime = OrtRuntime.load(ort.library!);
      size = TinyModels.load().slowSize;
    });

    Map<String, int> live() => {
      for (final MapEntry(:key, :value) in runtime.liveObjects.entries)
        if (value != 0) key: value,
    };

    Map<String, OrtTensor> slowInputs(int turns) => {
      'state': OrtTensor([size, size], exactValues(size * size)),
      'iterations': OrtTensor.int64Scalar(turns),
    };

    test('a run stopped by another isolate ends within a second with OrtRunStopped', () async {
      final before = live();
      final session = runtime.openSession(tinyModelPath('tiny_slow.onnx'));
      addTearDown(session.close);
      final options = runtime.createRunOptions();
      expect(live()['OrtRunOptions'], (before['OrtRunOptions'] ?? 0) + 1);
      // Started before the run, which blocks this isolate
      final stoppedAt = await _stopFromAnotherIsolate(options.handle, const Duration(milliseconds: 300));

      final watch = Stopwatch()..start();
      Object? thrown;
      try {
        session.runNamed(slowInputs(_endless), options: options);
      } catch (error) {
        thrown = error;
      }
      final endedAt = DateTime.now().microsecondsSinceEpoch;
      final lag = Duration(microseconds: endedAt - (await stoppedAt.first as int));
      // ignore: avoid_print
      print(
        'ONNX Runtime ${runtime.version}: run ended ${lag.inMilliseconds} ms after the stop, ${watch.elapsed} in all',
      );

      expect(thrown, isA<OrtRunStopped>().having((e) => e.message, 'message', startsWith('Run: ')));
      expect(lag, lessThan(const Duration(seconds: 1)));
      expect(options.stopAsked, isTrue);
      expect(live().keys, isNot(contains('OrtValue')), reason: 'the inputs given back, no output made');

      // Options stopped once stop every later run at once; fresh ones run, and the session still works
      final again = Stopwatch()..start();
      expect(() => session.runNamed(slowInputs(_endless), options: options), throwsA(isA<OrtRunStopped>()));
      expect(again.elapsed, lessThan(const Duration(seconds: 1)));
      final fresh = runtime.createRunOptions();
      final outputs = session.runNamed(slowInputs(3), options: fresh);
      expect(outputs['count']!.integers, [3]);
      expect(fresh.stopAsked, isFalse);

      options.release();
      fresh.release();
      options.release();
      expect(options.isReleased, isTrue);
      expect(() => options.handle, throwsStateError);
      expect(
        () => session.runNamed(slowInputs(1), options: options),
        throwsArgumentError,
        reason: 'options given back are refused',
      );
      expect(live()['OrtRunOptions'] ?? 0, before['OrtRunOptions'] ?? 0);
    });

    test('a run that fails while nothing stopped it is an OrtException, not OrtRunStopped', () {
      final session = runtime.openSession(tinyModelPath('tiny_slow.onnx'));
      addTearDown(session.close);
      final options = runtime.createRunOptions();
      addTearDown(options.release);
      expect(
        () => session.runNamed({
          'state': OrtTensor.int64Scalar(1),
          'iterations': OrtTensor.int64Scalar(1),
        }, options: options),
        throwsA(isA<OrtException>().having((e) => e, 'type', isNot(isA<OrtRunStopped>()))),
      );
    });
  }, skip: ort.skip);
}
