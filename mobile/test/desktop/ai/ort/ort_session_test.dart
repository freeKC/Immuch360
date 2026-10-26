// ONNX Runtime by FFI (lot A4a): what happens without the library, then, with IMMUCH360_ORT_LIB, the tiny model
// loaded, its names and shapes read, its output exact, the session reused for 200 passes without the memory growing,
// and ONNX Runtime's errors turned into exceptions with its message. Paths with accents: ort_accented_path_test.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:path/path.dart' as p;

import 'ort_for_tests.dart';

/// A library of the system that is not ONNX Runtime, null where none is known
String? _otherLibrary() {
  if (Platform.isWindows) {
    return p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'kernel32.dll');
  }
  if (Platform.isLinux) {
    for (final path in [
      '/lib/x86_64-linux-gnu/libc.so.6',
      '/usr/lib/x86_64-linux-gnu/libc.so.6',
      '/lib64/libc.so.6',
      '/usr/lib64/libc.so.6',
    ]) {
      if (File(path).existsSync()) {
        return path;
      }
    }
  }
  return null;
}

void main() {
  group('without ONNX Runtime', () {
    test('a missing library is refused with its path', () {
      final missing = p.join(Directory.systemTemp.path, 'immuch360-no-ort', 'libonnxruntime.so');
      expect(
        () => OrtRuntime.load(missing),
        throwsA(isA<OrtLoadException>().having((e) => e.message, 'message', 'No ONNX Runtime library at $missing')),
      );
    });

    test('a file that is not a library is refused with the reason of the system', () {
      expect(
        () => OrtRuntime.load(tinyDepthModelPath()),
        throwsA(
          isA<OrtLoadException>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith('ONNX Runtime could not be loaded from ${tinyDepthModelPath()}: '),
              hasLength(greaterThan(80)),
            ),
          ),
        ),
      );
    });

    final other = _otherLibrary();
    test('a library that is not ONNX Runtime is refused', () {
      expect(
        () => OrtRuntime.load(other!),
        throwsA(
          isA<OrtLoadException>().having(
            (e) => e.message,
            'message',
            '$other is not ONNX Runtime: it has no OrtGetApiBase',
          ),
        ),
      );
    }, skip: other == null ? 'no system library known here' : null);

    test('the library of the tests: none named skips, a name that leads to no file fails', () {
      expect(ortForTests(const {}).skip, startsWith('no ONNX Runtime: set IMMUCH360_ORT_LIB'));
      expect(ortForTests(const {'IMMUCH360_ORT_LIB': ''}).library, isNull);
      final missing = p.join(Directory.systemTemp.path, 'immuch360-no-ort', 'libonnxruntime.so.1.31.0');
      expect(
        () => ortForTests({'IMMUCH360_ORT_LIB': missing}),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'IMMUCH360_ORT_LIB names no file: $missing')),
      );
      final found = ortForTests({'IMMUCH360_ORT_LIB': tinyDepthModelPath()});
      expect(found.library, tinyDepthModelPath());
      expect(found.skip, isNull);
    });

    test('the settings of the design: all logical processors but two, at least one, no spinning', () {
      expect(OrtSessionSettings.forProcessors(32).intraOpThreads, 30);
      expect(OrtSessionSettings.forProcessors(8).intraOpThreads, 6);
      expect(OrtSessionSettings.forProcessors(3).intraOpThreads, 1);
      expect(OrtSessionSettings.forProcessors(2).intraOpThreads, 1);
      expect(OrtSessionSettings.forProcessors(1).intraOpThreads, 1);
      final settings = OrtSessionSettings.forThisComputer();
      expect(settings.interOpThreads, 1);
      expect(settings.allowSpinning, isFalse);
      expect(settings.intraOpThreads, OrtSessionSettings.forProcessors(Platform.numberOfProcessors).intraOpThreads);
    });
  });

  final ort = ortForTests();
  group('ONNX Runtime from IMMUCH360_ORT_LIB', () {
    late OrtRuntime runtime;
    late TinyDepthModel tiny;

    setUpAll(() {
      runtime = OrtRuntime.load(ort.library!);
      tiny = TinyDepthModel.load();
      // ignore: avoid_print
      print('ONNX Runtime ${runtime.version} from ${runtime.libraryPath}');
    });

    test('loads once per path and gives its version', () {
      expect(OrtRuntime.load(ort.library!), same(runtime));
      expect(runtime.version, matches(RegExp(r'^1\.\d+\.\d+')));
      final minor = int.parse(runtime.version.split('.')[1]);
      expect(minor, greaterThanOrEqualTo(ortApiVersion));
    });

    test('reads the names and shapes of the model, never constants', () {
      final session = runtime.openSession(tinyDepthModelPath());
      addTearDown(session.close);
      expect(session.inputs, hasLength(1));
      expect(session.outputs, hasLength(1));
      expect(session.inputs.single.name, tiny.inputName);
      expect(session.inputs.single.shape, [-1, 3, -1, -1]);
      expect(session.inputs.single.isFloat, isTrue);
      expect(session.outputs.single.name, tiny.outputName);
      expect(session.outputs.single.shape, [-1, -1, -1]);
      expect(session.outputs.single.isFloat, isTrue);
    });

    test('gives the expected output of the sample, exactly', () {
      final session = runtime.openSession(tinyDepthModelPath());
      addTearDown(session.close);
      final output = session.run(tiny.sample, tiny.sampleShape);
      expect(output.shape, tiny.expectedShape);
      expect(output.values, tiny.expected);
    });

    test('runs an input of the size of the real model, 686 x 518, exactly', () {
      final session = runtime.openSession(tinyDepthModelPath());
      addTearDown(session.close);
      final input = TinyDepthModel.exactInput(686, 518);
      final output = session.run(input, [1, 3, 518, 686]);
      expect(output.shape, [1, 518, 686]);
      expect(output.values, tiny.outputFor(input, 686, 518));
    });

    test('runs 200 passes on one session without the memory growing', () {
      final session = runtime.openSession(tinyDepthModelPath());
      addTearDown(session.close);
      final input = TinyDepthModel.exactInput(686, 518);
      final expected = tiny.outputFor(input, 686, 518);
      // The arenas of ONNX Runtime and the heap of Dart reach their size in the first passes
      for (var i = 0; i < 20; i++) {
        session.run(input, [1, 3, 518, 686]);
      }
      final before = ProcessInfo.currentRss;
      Float32List? last;
      for (var i = 0; i < 200; i++) {
        last = session.run(input, [1, 3, 518, 686]).values;
      }
      final growth = ProcessInfo.currentRss - before;
      // ignore: avoid_print
      print('resident memory after 200 passes: ${growth >= 0 ? '+' : ''}${(growth / 1048576).toStringAsFixed(1)} MiB');
      expect(last, expected);
      // One input left behind would be 4.3 MB a pass, one output 1.4 MB: 280 MB or more over 200 passes
      expect(growth, lessThan(48 * 1048576));
    });

    test('turns an error of ONNX Runtime into an OrtException with its message, and the session still runs', () {
      final session = runtime.openSession(tinyDepthModelPath());
      addTearDown(session.close);
      expect(
        () => session.run(Float32List(2 * 4 * 5), [1, 2, 4, 5]),
        throwsA(
          isA<OrtException>()
              .having((e) => e.message, 'message', startsWith('Run: '))
              .having((e) => e.code, 'code', isNotNull),
        ),
      );
      expect(session.run(tiny.sample, tiny.sampleShape).values, tiny.expected);
    });

    test('refuses a tensor whose shape does not match its values', () {
      final session = runtime.openSession(tinyDepthModelPath());
      addTearDown(session.close);
      expect(() => session.run(Float32List(10), [1, 3, 4, 5]), throwsArgumentError);
    });

    test('says why a model cannot be read', () {
      final missing = p.join(Directory.systemTemp.path, 'immuch360-no-model', 'model.onnx');
      expect(
        () => runtime.openSession(missing),
        throwsA(isA<OrtException>().having((e) => e.message, 'message', startsWith('CreateSession: '))),
      );
      final notAModel = File(p.join(Directory.systemTemp.createTempSync('immuch360-ort-').path, 'model.onnx'))
        ..writeAsStringSync('not a model');
      addTearDown(() => notAModel.parent.deleteSync(recursive: true));
      expect(
        () => runtime.openSession(notAModel.path),
        throwsA(isA<OrtException>().having((e) => e.message, 'message', startsWith('CreateSession: '))),
      );
    });

    test('cannot run once closed', () {
      final session = runtime.openSession(tinyDepthModelPath());
      session.close();
      expect(session.isClosed, isTrue);
      expect(() => session.run(tiny.sample, tiny.sampleShape), throwsStateError);
      session.close();
    });
  }, skip: ort.skip);
}
