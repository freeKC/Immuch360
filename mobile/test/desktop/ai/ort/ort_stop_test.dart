// The stop of a run of ONNX Runtime from another isolate (lot C1, design-final 2026-10-27 sections 2.5 and 10.1
// point 3): the slow tiny model, a loop of matrix products of minutes, ended within a second of the stop asked by
// another isolate through its own binding (ort_terminate.dart), and the run turned into OrtRunStopped; the options
// stopped once stay stopped, fresh ones run; nothing native left behind. Then the same through the worker: a task
// cancelled on the root isolate ends within a second, its run options kept by the worker until the root isolate lets
// them go, and at most two sessions kept open.

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_engine_tools.dart';
import '../fakes/fake_thread_priority.dart';
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

/// The slow model run in the worker for [turns] turns, with the options of its job; the session kept as 'slow'
class _SlowTask implements AiWorkerTask<String> {
  const _SlowTask(this.library, this.turns);

  final String library;
  final int turns;

  @override
  String run(AiWorkerContext context) {
    final session = context.sessions.open(
      'slow',
      () => OrtRuntime.load(library).openSession(tinyModelPath('tiny_slow.onnx')),
      (OrtSession session) => session.close(),
    );
    final options = context.runOptions(library);
    final size = session.inputs.first.shape.first;
    try {
      final count = session.runNamed(
        {
          'state': OrtTensor([size, size], exactValues(size * size)),
          'iterations': OrtTensor.int64Scalar(turns),
        },
        outputs: const ['count'],
        options: options,
      )['count']!;
      return 'done ${count.integers.single}';
    } on OrtRunStopped {
      return context.isCancelled ? 'cancelled' : 'stopped without a cancel';
    }
  }
}

/// Opens the tiny model [model] in the worker as the session [name], and says how many sessions are open there
class _OpenTask implements AiWorkerTask<int> {
  const _OpenTask(this.library, this.name, this.model);

  final String library;
  final String name;
  final String model;

  @override
  int run(AiWorkerContext context) {
    final runtime = OrtRuntime.load(library);
    context.sessions.open(name, () => runtime.openSession(tinyModelPath(model)), (OrtSession s) => s.close());
    return runtime.liveObjects['OrtSession'] ?? 0;
  }
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

    group('through the worker', () {
      late AiWorker worker;

      setUp(() async {
        worker = await AiWorker.spawn(
          AiWorkerSetup(
            backend: const FakeBackendSpec(),
            codec: SbsCodecChoice.dart,
            memory: const FixedMemoryProbe(),
            priority: FakeThreadPriority(threads: {1: 'main'}),
          ),
        );
      });
      tearDown(() => worker.close());

      test('a task cancelled on the root isolate ends within a second; its options are given back after', () async {
        final cancel = NativeCancelFlag();
        addTearDown(cancel.free);
        final result = worker.runTask(_SlowTask(ort.library!, _endless), cancelAddress: cancel.address);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        cancel.cancel();
        final watch = Stopwatch()..start();

        expect(await result, 'cancelled');
        // ignore: avoid_print
        print('the task ended ${watch.elapsedMilliseconds} ms after the cancel');
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        final status = await worker.status();
        expect((status.runOptionsHeld, status.openSessions.join(' ')), (0, 'slow'));
      });

      test('a task cancelled before its options reach the root isolate is stopped as soon as they do', () async {
        final cancel = NativeCancelFlag()..cancel();
        addTearDown(cancel.free);
        final watch = Stopwatch()..start();
        expect(await worker.runTask(_SlowTask(ort.library!, _endless), cancelAddress: cancel.address), 'cancelled');
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)), reason: 'the session opens first');
      });

      test('the worker keeps the run options until the root isolate lets them go', () async {
        final cancel = NativeCancelFlag();
        addTearDown(cancel.free);
        worker.holdRunOptions = true;

        expect(await worker.runTask(_SlowTask(ort.library!, 4), cancelAddress: cancel.address), 'done 4');
        expect((await worker.status()).runOptionsHeld, 1);
        expect(await worker.runTask(_SlowTask(ort.library!, 2), cancelAddress: cancel.address), 'done 2');
        expect((await worker.status()).runOptionsHeld, 2);

        worker.releaseRunOptions();
        expect((await worker.status()).runOptionsHeld, 0);
      });

      test('at most two sessions stay open: a third gives back the one used least recently', () async {
        final cancel = NativeCancelFlag();
        addTearDown(cancel.free);
        Future<int> open(String name, String model) =>
            worker.runTask(_OpenTask(ort.library!, name, model), cancelAddress: cancel.address);

        expect(await open('moge', 'tiny_moge.onnx'), 1);
        expect(await open('lama', 'tiny_lama.onnx'), 2);
        expect(await open('moge', 'tiny_moge.onnx'), 2, reason: 'kept, not opened again');
        expect(await open('migan', 'tiny_migan.onnx'), 2);

        final status = await worker.status();
        expect((status.openSessions.join(' '), status.sessionCloses), ('moge migan', 1));
      });
    });
  }, skip: ort.skip);
}
