// ONNX Runtime with several inputs and outputs (lot C1, design-final 2026-10-27 section 10.1 point 3): the tensors of
// three element types and their shapes, then, with IMMUCH360_ORT_LIB, the tiny models of make_tiny_models.py read
// and run as the real ones would be: MoGe-2 ViT-S (a float32 image and an int64 scalar in, four float32 maps out, any
// size and batch), LaMa (fixed 512), the MI-GAN pipeline (bytes in and out), the slow model (an int64 scalar out);
// some outputs only; the errors of ONNX Runtime; 200 passes without the memory growing, with and without the arena.
// The stop of a run: ort_stop_test.dart.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';

import 'ort_for_tests.dart';

/// The resident memory of the process; on Linux after glibc gave back the free memory it keeps (malloc_trim): without
/// the arena of ONNX Runtime, each pass frees its memory to malloc, whose arenas per thread would otherwise hide what a
/// leak would show
int _residentMemory() {
  if (Platform.isLinux) {
    try {
      DynamicLibrary.process().lookupFunction<Int Function(Size), int Function(int)>('malloc_trim')(0);
    } on ArgumentError {
      // Not glibc
    }
  }
  return ProcessInfo.currentRss;
}

const _float = 1;
const _uint8 = 2;
const _int64 = 7;
const _float16 = 10;

void main() {
  group('tensors, without ONNX Runtime', () {
    test('a tensor holds as many values as its shape says; a scalar of shape [] holds one', () {
      expect(elementCountOf(const []), 1);
      expect(elementCountOf(const [2, 3, 0]), 0);
      expect(elementCountOf(const [1, 3, 683, 1024]), 3 * 683 * 1024);
      expect(OrtTensor.int64Scalar(2500).shape, isEmpty);
      expect(OrtTensor.int64Scalar(2500).integers, [2500]);
      expect(
        () => OrtTensor(const [1, 3, 4, 5], Float32List(10)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'A tensor of shape [1, 3, 4, 5] holds 60 values, not 10',
          ),
        ),
      );
      expect(() => OrtTensor.uint8(const [2, 2], Uint8List(3)), throwsArgumentError);
      expect(() => OrtTensor.int64(const [-1], Int64List(1)), throwsArgumentError);
    });

    test('each tensor gives its values in its own type only', () {
      final float = OrtTensor(const [2], Float32List.fromList([0.5, 1.5]));
      final bytes = OrtTensor.uint8(const [3], Uint8List.fromList([0, 128, 255]));
      final integers = OrtTensor.int64(const [1, 2], Int64List.fromList([-1, 1 << 40]));
      expect(
        (float.type, bytes.type, integers.type),
        (OrtElementType.float32, OrtElementType.uint8, OrtElementType.int64),
      );
      expect((float.elementCount, bytes.elementCount, integers.elementCount), (2, 3, 2));
      expect(float.values, [0.5, 1.5]);
      expect(bytes.bytes, [0, 128, 255]);
      expect(integers.integers, [-1, 1 << 40]);
      expect(() => float.bytes, throwsStateError);
      expect(() => bytes.values, throwsStateError);
      expect(() => integers.values, throwsStateError);
      expect(float.rawBytes, hasLength(8));
      expect(integers.rawBytes, hasLength(16));
    });

    test('a copy of raw bytes reads back as the tensor they came from, in a buffer of its own', () {
      for (final tensor in [
        OrtTensor(const [1, 2], Float32List.fromList([-0.25, 3])),
        OrtTensor.uint8(const [2, 1], Uint8List.fromList([7, 9])),
        OrtTensor.int64(const [], Int64List.fromList([2500])),
      ]) {
        final raw = tensor.rawBytes;
        final copy = OrtTensor.copyOf(tensor.type, tensor.shape, raw);
        expect(copy.type, tensor.type, reason: '$tensor');
        expect(copy.shape, tensor.shape, reason: '$tensor');
        expect(copy.rawBytes, raw, reason: '$tensor');
        raw[0] ^= 1;
        expect(copy.rawBytes, isNot(raw), reason: 'a copy, not a view');
      }
    });

    test('the element types are those of ONNX Runtime; float16 and the others are not read', () {
      expect(OrtElementType.of(_float), OrtElementType.float32);
      expect(OrtElementType.of(_uint8), OrtElementType.uint8);
      expect(OrtElementType.of(_int64), OrtElementType.int64);
      expect(OrtElementType.of(_float16), isNull);
      expect(const OrtTensorSpec('num_tokens', _int64, []).type, OrtElementType.int64);
      expect(const OrtTensorSpec('x', _float16, [-1]).type, isNull);
    });

    test('a session keeps the arena of ONNX Runtime unless told otherwise', () {
      final settings = OrtSessionSettings.forProcessors(8);
      expect(settings.cpuMemArena, isTrue);
      final without = settings.withCpuMemArena(false);
      expect(
        (without.cpuMemArena, without.intraOpThreads, without.interOpThreads, without.allowSpinning),
        (false, 6, 1, false),
      );
    });
  });

  final ort = ortForTests();
  group('the tiny models on ONNX Runtime from IMMUCH360_ORT_LIB', () {
    late OrtRuntime runtime;
    late TinyModels tiny;

    setUpAll(() {
      runtime = OrtRuntime.load(ort.library!);
      tiny = TinyModels.load();
      // ignore: avoid_print
      print('ONNX Runtime ${runtime.version} from ${runtime.libraryPath}');
    });

    Map<String, int> live() => {
      for (final MapEntry(:key, :value) in runtime.liveObjects.entries)
        if (value != 0) key: value,
    };

    test('each tiny model has the names, types and shapes of the real one, read from the model', () {
      for (final model in ['tiny_moge.onnx', 'tiny_lama.onnx', 'tiny_migan.onnx', 'tiny_slow.onnx']) {
        final session = runtime.openSession(tinyModelPath(model));
        addTearDown(session.close);
        String described(OrtTensorSpec spec) => '${spec.name} ${spec.type!.name} ${spec.shape}';
        expect(session.inputs.map(described).toList(), tiny.specs(model, inputs: true), reason: model);
        expect(session.outputs.map(described).toList(), tiny.specs(model, inputs: false), reason: model);
      }
    });

    test('MoGe: a float32 image and num_tokens as an int64 scalar in, its four maps out, exactly', () {
      final session = runtime.openSession(tinyModelPath('tiny_moge.onnx'));
      addTearDown(session.close);
      final sample = tiny.of('tiny_moge.onnx');
      final shape = (sample['sampleShape'] as List).cast<int>();
      final image = Float32List.fromList((sample['sampleImage'] as List).cast<num>().map((v) => v.toDouble()).toList());

      final outputs = session.runNamed({
        'image': OrtTensor(shape, image),
        'num_tokens': OrtTensor.int64Scalar(sample['sampleTokens'] as int),
      });

      expect(outputs.keys, ['points', 'normal', 'mask', 'scale']);
      final shapes = (sample['expectedShapes'] as Map<String, dynamic>).cast<String, List<dynamic>>();
      final expected = (sample['expected'] as Map<String, dynamic>).cast<String, List<dynamic>>();
      for (final MapEntry(key: name, value: tensor) in outputs.entries) {
        expect(tensor.type, OrtElementType.float32, reason: name);
        expect(tensor.shape, shapes[name]!.cast<int>(), reason: name);
        expect(tensor.values, expected[name]!.cast<num>().map((v) => v.toDouble()).toList(), reason: name);
      }
    });

    test('MoGe: any batch and any size of image, in the order of the tensors', () {
      final session = runtime.openSession(tinyModelPath('tiny_moge.onnx'));
      addTearDown(session.close);
      const batch = 2;
      const height = 7;
      const width = 9;
      final image = exactValues(batch * 3 * height * width);

      final outputs = session.runNamed({
        'image': OrtTensor(const [batch, 3, height, width], image),
        'num_tokens': OrtTensor.int64Scalar(1800),
      });

      expect(outputs['points']!.shape, [batch, height, width, 3]);
      expect(outputs['mask']!.shape, [batch, height, width]);
      expect(outputs['scale']!.shape, [batch]);
      expect(outputs['scale']!.values, everyElement(1800 / tiny.mogeScaleDivisor));
      final points = outputs['points']!.values;
      final normal = outputs['normal']!.values;
      final mask = outputs['mask']!.values;
      for (var b = 0; b < batch; b++) {
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            for (var c = 0; c < 3; c++) {
              final value = image[((b * 3 + c) * height + y) * width + x];
              final at = ((b * height + y) * width + x) * 3 + c;
              expect(points[at], 2 * value - 1);
              expect(normal[at], 1 - value);
            }
            expect(mask[(b * height + y) * width + x], image[(b * 3 * height + y) * width + x]);
          }
        }
      }
    });

    test('gives the outputs it is asked for only, and refuses one the model does not have', () {
      final session = runtime.openSession(tinyModelPath('tiny_moge.onnx'));
      addTearDown(session.close);
      final inputs = {
        'image': OrtTensor(const [1, 3, 4, 6], exactValues(72)),
        'num_tokens': OrtTensor.int64Scalar(2500),
      };

      final scale = session.runNamed(inputs, outputs: const ['scale']);
      expect(scale.keys, ['scale']);
      expect(scale['scale']!.values, [2500 / tiny.mogeScaleDivisor]);
      final two = session.runNamed(inputs, outputs: const ['mask', 'points']);
      expect(two.keys, ['mask', 'points']);
      expect(
        () => session.runNamed(inputs, outputs: const ['depth']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            startsWith('${session.modelPath} has no output depth'),
          ),
        ),
      );
    });

    test('LaMa: an image and a mask of 512 x 512, the output in [0, 255], exactly', () {
      final session = runtime.openSession(tinyModelPath('tiny_lama.onnx'));
      addTearDown(session.close);
      const side = 512;
      final image = exactValues(3 * side * side);
      final mask = Float32List(side * side);
      for (var y = 100; y < 180; y++) {
        for (var x = 40; x < 300; x++) {
          mask[y * side + x] = 1;
        }
      }

      final output = session.runNamed({
        'image': OrtTensor(const [1, 3, side, side], image),
        'mask': OrtTensor(const [1, 1, side, side], mask),
      })['output']!;

      expect(output.shape, [1, 3, side, side]);
      final values = output.values;
      for (var c = 0; c < 3; c++) {
        for (var i = 0; i < side * side; i++) {
          final hole = mask[i] == 1;
          expect(values[c * side * side + i], hole ? 255 * tiny.lamaHole : 255 * image[c * side * side + i]);
        }
      }
    });

    test('MI-GAN: bytes in, bytes out, 255 in the mask where the pixel is known', () {
      final session = runtime.openSession(tinyModelPath('tiny_migan.onnx'));
      addTearDown(session.close);
      const height = 20;
      const width = 30;
      final image = Uint8List.fromList([for (var i = 0; i < 3 * height * width; i++) (37 * i) % 256]);
      final mask = Uint8List(height * width)..fillRange(0, height * width, 255);
      for (var y = 5; y < 9; y++) {
        mask.fillRange(y * width + 3, y * width + 17, 0);
      }

      final result = session.runNamed({
        'image': OrtTensor.uint8(const [1, 3, height, width], image),
        'mask': OrtTensor.uint8(const [1, 1, height, width], mask),
      })['result']!;

      expect(result.type, OrtElementType.uint8);
      expect(result.shape, [1, 3, height, width]);
      for (var c = 0; c < 3; c++) {
        for (var i = 0; i < height * width; i++) {
          expect(result.bytes[c * height * width + i], mask[i] == 255 ? image[c * height * width + i] : tiny.miganHole);
        }
      }
    });

    test('the slow model: an int64 scalar out, and the state turned once per turn', () {
      final session = runtime.openSession(tinyModelPath('tiny_slow.onnx'));
      addTearDown(session.close);
      final size = tiny.slowSize;
      final state = exactValues(size * size, seed: 3);

      final outputs = session.runNamed({
        'state': OrtTensor([size, size], state),
        'iterations': OrtTensor.int64Scalar(5),
      });

      final count = outputs['count']!;
      expect(count.type, OrtElementType.int64);
      expect(count.shape, isEmpty);
      expect(count.integers, [5]);
      expect(outputs['rotated']!.values, turned(state, size, 5));
    });

    test('turns the refusals of ONNX Runtime into OrtException, and leaves no native object behind', () {
      final before = live();
      final session = runtime.openSession(tinyModelPath('tiny_moge.onnx'));
      final open = live();
      final image = OrtTensor(const [1, 3, 4, 6], exactValues(72));
      final refusals = <String, Map<String, OrtTensor>>{
        'a missing input': {'image': image},
        'an input of the wrong type': {'image': image, 'num_tokens': OrtTensor(const [], Float32List(1))},
        'an input of the wrong rank': {
          'image': OrtTensor(const [3, 4, 6], exactValues(72)),
          'num_tokens': OrtTensor.int64Scalar(2500),
        },
        'an input the model does not have': {'image': image, 'num_tokens': OrtTensor.int64Scalar(2500), 'depth': image},
      };
      for (final MapEntry(key: what, value: inputs) in refusals.entries) {
        expect(
          () => session.runNamed(inputs),
          throwsA(
            isA<OrtException>()
                .having((e) => e, 'type', isNot(isA<OrtRunStopped>()))
                .having((e) => e.message, 'message', startsWith('Run: '))
                .having((e) => e.code, 'code', isNotNull),
          ),
          reason: what,
        );
        expect(live(), open, reason: 'after $what');
      }
      session.runNamed({'image': image, 'num_tokens': OrtTensor.int64Scalar(2500)});
      expect(live(), open, reason: 'after a pass of four outputs');
      session.close();
      expect(live(), before);
    });

    // What the arena keeps after a pass is what the setting is for (MoGe: 2.25 GB at the peak with it, 1.35 without,
    // measure M2): a pass of the tiny MoGe on a large image leaves its intermediate tensors in the arena when it is
    // kept, and gives them back when it is off. Measured on Linux, where malloc_trim shows what was really given back
    test('a session without the arena gives the memory of a pass back; one with the arena keeps it', () {
      const side = 2048;
      final inputs = {
        'image': OrtTensor(const [1, 3, side, side], exactValues(3 * side * side)),
        'num_tokens': OrtTensor.int64Scalar(2500),
      };
      int keptAfterAPass(bool arena) {
        final session = runtime.openSession(
          tinyModelPath('tiny_moge.onnx'),
          settings: OrtSessionSettings.forThisComputer().withCpuMemArena(arena),
        );
        try {
          final before = _residentMemory();
          final scale = session.runNamed(inputs, outputs: const ['scale'])['scale']!;
          expect(scale.values, [2500 / tiny.mogeScaleDivisor]);
          return _residentMemory() - before;
        } finally {
          session.close();
        }
      }

      final withArena = keptAfterAPass(true);
      final withoutArena = keptAfterAPass(false);
      // ignore: avoid_print
      print('kept after a pass of 2048 x 2048: ${withArena >> 20} MiB with the arena, ${withoutArena >> 20} without');
      expect(withArena - withoutArena, greaterThan(64 * 1048576));
    }, skip: Platform.isLinux ? null : 'reads what malloc_trim gives back, on Linux only');

    for (final arena in [true, false]) {
      test('runs 200 passes of MoGe on one session without the memory growing, arena ${arena ? 'kept' : 'off'}', () {
        final session = runtime.openSession(
          tinyModelPath('tiny_moge.onnx'),
          settings: OrtSessionSettings.forThisComputer().withCpuMemArena(arena),
        );
        addTearDown(session.close);
        const height = 171;
        const width = 256;
        final inputs = {
          'image': OrtTensor(const [1, 3, height, width], exactValues(3 * height * width)),
          'num_tokens': OrtTensor.int64Scalar(2500),
        };
        for (var i = 0; i < 20; i++) {
          session.runNamed(inputs);
        }
        final before = _residentMemory();
        Map<String, OrtTensor>? last;
        for (var i = 0; i < 200; i++) {
          last = session.runNamed(inputs);
        }
        final growth = _residentMemory() - before;
        // ignore: avoid_print
        print(
          'arena ${arena ? 'kept' : 'off'}: resident memory after 200 passes ${(growth / 1048576).toStringAsFixed(1)} MiB',
        );
        expect(last!['points']!.values[3 * width + 2], 2 * inputs['image']!.values[2 * height * width + width] - 1);
        // One set of outputs left behind would be 1.2 MB a pass, 240 MB over 200 passes. The copies of the outputs in
        // the heap of Dart move the resident memory by up to some 40 MB from one run to the next (measured on ai1);
        // the native objects of a pass are counted exactly by the test above
        expect(growth, lessThan(96 * 1048576));
      });
    }
  }, skip: ort.skip);
}
