// OrtDepthBackend, the depth model behind DepthBackend on ONNX Runtime (lot A4a): the reason given when the library is
// missing and the models it refuses, then, with IMMUCH360_ORT_LIB, the tiny model as a depth model (the map it gives,
// at the size of the real model too), and the session closed and opened again.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import 'ort_for_tests.dart';

void main() {
  group('without ONNX Runtime', () {
    test('says that the library is missing, at the first estimate and on open', () {
      final missing = p.join(Directory.systemTemp.path, 'immuch360-no-ort', 'onnxruntime.dll');
      final backend = OrtDepthBackend(libraryPath: missing, modelPath: tinyDepthModelPath());
      final reason = isA<DepthBackendException>().having(
        (e) => e.message,
        'message',
        'No ONNX Runtime library at $missing',
      );
      expect(() => backend.estimate(Float32List(3 * depthModelInputWidth * depthModelInputHeight)), throwsA(reason));
      expect(backend.open, throwsA(reason));
      expect(backend.isOpen, isFalse);
      backend.close();
    });

    test('takes the input of the real model and its checksum by default, and refuses another input size', () {
      final backend = OrtDepthBackend(libraryPath: 'unused', modelPath: 'unused');
      expect(backend.inputWidth, 686);
      expect(backend.inputHeight, 518);
      expect(backend.modelSha256, depthModelOnnxSha256);
      expect(() => backend.estimate(Float32List(10)), throwsArgumentError);
    });

    test('takes a model of one float32 image [1, 3, H, W], free or fixed to its size, and refuses any other', () {
      const float = 1;
      const int64 = 7;
      final backend = OrtDepthBackend(libraryPath: 'unused', modelPath: 'model.onnx');
      final map = [
        const OrtTensorSpec('predicted_depth', float, [-1, -1, -1]),
      ];
      OrtTensorSpec image(List<int> shape, [int type = float]) => OrtTensorSpec('pixel_values', type, shape);
      expect(
        backend.refusalOf([
          image([-1, 3, -1, -1]),
        ], map),
        isNull,
      );
      expect(
        backend.refusalOf([
          image([1, 3, 518, 686]),
        ], map),
        isNull,
      );
      expect(
        backend.refusalOf(
          [
            image([1, 3, 518, 686]),
          ],
          [
            const OrtTensorSpec('depth', float, [1, 518, 686]),
          ],
        ),
        isNull,
      );
      expect(
        backend.refusalOf([
          image([1, 3, 512, 512]),
        ], map),
        'The input pixel_values [1, 3, 512, 512] of model.onnx does not take a float32 image [1, 3, 518, 686]',
      );
      expect(
        backend.refusalOf([
          image([1, 1, 518, 686]),
        ], map),
        isNotNull,
      );
      expect(
        backend.refusalOf([
          image([2, 3, 518, 686]),
        ], map),
        isNotNull,
      );
      expect(
        backend.refusalOf([
          image([3, 518, 686]),
        ], map),
        isNotNull,
      );
      expect(
        backend.refusalOf([
          image([-1, 3, -1, -1], int64),
        ], map),
        isNotNull,
      );
      expect(
        backend.refusalOf([
          image([-1, 3, -1, -1]),
          image([-1, 3, -1, -1]),
        ], map),
        'model.onnx has 2 inputs and 1 outputs: a depth model takes one image and gives one map',
      );
      expect(
        backend.refusalOf([
          image([-1, 3, -1, -1]),
        ], const []),
        isNotNull,
      );
      expect(
        backend.refusalOf(
          [
            image([-1, 3, -1, -1]),
          ],
          [
            const OrtTensorSpec('depth', int64, [-1, -1, -1]),
          ],
        ),
        'The output depth [-1, -1, -1] of model.onnx is not float32',
      );
    });
  });

  final ort = ortForTests();
  group('ONNX Runtime from IMMUCH360_ORT_LIB', () {
    late TinyDepthModel tiny;

    setUpAll(() => tiny = TinyDepthModel.load());

    test('gives the map of the tiny model', () {
      final backend = OrtDepthBackend(
        libraryPath: ort.library!,
        modelPath: tinyDepthModelPath(),
        inputWidth: 5,
        inputHeight: 4,
      );
      addTearDown(backend.close);
      final map = backend.estimate(tiny.sample);
      expect(map.width, 5);
      expect(map.height, 4);
      expect(map.values, tiny.expected);
      expect(map.at(4, 3), tiny.expected[3 * 5 + 4]);
      expect(backend.runtimeVersion, isNotNull);
    });

    test('gives a map of 686 x 518 for the input of the real model', () {
      final backend = OrtDepthBackend(libraryPath: ort.library!, modelPath: tinyDepthModelPath());
      addTearDown(backend.close);
      final input = TinyDepthModel.exactInput(depthModelInputWidth, depthModelInputHeight);
      final map = backend.estimate(input);
      expect(map.width, depthModelInputWidth);
      expect(map.height, depthModelInputHeight);
      expect(map.values, tiny.outputFor(input, depthModelInputWidth, depthModelInputHeight));
    });

    test('closes its session and opens it again at the next estimate', () {
      final backend = OrtDepthBackend(
        libraryPath: ort.library!,
        modelPath: tinyDepthModelPath(),
        inputWidth: 5,
        inputHeight: 4,
      );
      addTearDown(backend.close);
      backend.open();
      expect(backend.isOpen, isTrue);
      backend.close();
      expect(backend.isOpen, isFalse);
      expect(backend.estimate(tiny.sample).values, tiny.expected);
      expect(backend.isOpen, isTrue);
    });

    test('says why the model cannot be read', () {
      final missing = p.join(Directory.systemTemp.path, 'immuch360-no-model', 'model.onnx');
      final backend = OrtDepthBackend(libraryPath: ort.library!, modelPath: missing);
      expect(
        backend.open,
        throwsA(isA<DepthBackendException>().having((e) => e.message, 'message', startsWith('CreateSession: '))),
      );
      expect(backend.isOpen, isFalse);
    });
  }, skip: ort.skip);
}
