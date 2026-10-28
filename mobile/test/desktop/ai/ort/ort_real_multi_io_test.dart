// The real models of phase 2 on the real ONNX Runtime through runNamed (lot C1, the trial of the lot): run by hand on
// a build host, never in the CI, which downloads no model. One library per run (see ort_for_tests.dart), so the parity
// of two versions takes two runs sharing a folder of outputs: the first writes them, the second compares with them; a
// folder of the outputs ONNX Runtime gave in Python (measure M2) compares this binding with that one.
//
//   IMMUCH360_ORT_LIB     the library (1.31.0, then 1.23.2: the proof that Intel Macs run the models)
//   IMMUCH360_AI_INPUTS   a folder of photos ready for MoGe, as the measure M2 kept them: <name>.npy, float32
//                         [height, width, 3] in [0, 1], the longest side 1024 (landscape photos among them: opset 20
//                         loads in 1.23.2 but fails on a landscape photo, so loading proves nothing)
//   IMMUCH360_AI_MOGE     our export of MoGe-2 ViT-S (moge_2_vits_normal_immuch360.onnx, 140 852 051 bytes), run at
//                         2 500 tokens with the arena of ONNX Runtime off, as the scene engine will
//   IMMUCH360_AI_LAMA     LaMa (lama_fp32.onnx), optional: the top left 512 x 512 of each photo with a hole
//   IMMUCH360_AI_MIGAN    the MI-GAN pipeline (migan_pipeline_v2.onnx), optional: the same region and hole, in bytes
//   IMMUCH360_ORT_MAPS    a folder for the outputs: <name>_<model>_<output>.f32 (float32) or .u8 (bytes), written
//                         when absent, compared when present: the largest difference, relative to the spread of the
//                         output (its range, or its largest magnitude when larger), at most 1e-4; bytes equal

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:path/path.dart' as p;

import 'ort_for_tests.dart';

/// A float32 array of a .npy file of NumPy (format 1, 2 or 3, little endian, C order)
({List<int> shape, Float32List values}) _readNpy(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length < 10 || bytes[0] != 0x93 || ascii.decode(bytes.sublist(1, 6)) != 'NUMPY') {
    throw FormatException('${file.path} is not a .npy file');
  }
  final major = bytes[6];
  final data = ByteData.sublistView(bytes);
  final headerLength = major == 1 ? data.getUint16(8, Endian.little) : data.getUint32(8, Endian.little);
  final start = major == 1 ? 10 : 12;
  final header = latin1.decode(bytes.sublist(start, start + headerLength));
  if (!header.contains("'descr': '<f4'") || !header.contains("'fortran_order': False")) {
    throw FormatException('${file.path} is not float32 in C order: $header');
  }
  final shape = [
    for (final dimension in RegExp(r"'shape': \(([^)]*)\)").firstMatch(header)!.group(1)!.split(','))
      if (dimension.trim().isNotEmpty) int.parse(dimension.trim()),
  ];
  // The header pads the data to a multiple of 64 bytes: a float32 view of the bytes read is aligned
  final values = bytes.buffer.asFloat32List(bytes.offsetInBytes + start + headerLength, elementCountOf(shape));
  return (shape: shape, values: Float32List.fromList(values));
}

/// [hwc], [height] x [width] x 3, as [1, 3, height, width]
Float32List _nchw(Float32List hwc, int height, int width) {
  final out = Float32List(hwc.length);
  final plane = height * width;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      out[c * plane + i] = hwc[i * 3 + c];
    }
  }
  return out;
}

/// The top left [side] x [side] of the planes of [nchw]
Float32List _crop(Float32List nchw, int height, int width, int side) {
  final out = Float32List(3 * side * side);
  for (var c = 0; c < 3; c++) {
    for (var y = 0; y < side; y++) {
      out.setRange((c * side + y) * side, (c * side + y + 1) * side, nchw, (c * height + y) * width);
    }
  }
  return out;
}

/// The hole of the region: rows 192 to 319, columns 128 to 383 of 512
bool _inHole(int y, int x) => y >= 192 && y < 320 && x >= 128 && x < 384;

/// Writes [output] to [folder] when it is not there, else compares with it; says what it did
String _keepOrCompare(String folder, String name, OrtTensor output) {
  final isBytes = output.type == OrtElementType.uint8;
  final file = File(p.join(folder, '$name.${isBytes ? 'u8' : 'f32'}'));
  if (!file.existsSync()) {
    Directory(folder).createSync(recursive: true);
    file.writeAsBytesSync(output.rawBytes);
    return '$name written';
  }
  final saved = file.readAsBytesSync();
  expect(saved.length, output.rawBytes.length, reason: name);
  if (isBytes) {
    var differing = 0;
    var largest = 0;
    for (var i = 0; i < saved.length; i++) {
      final difference = (saved[i] - output.bytes[i]).abs();
      if (difference > 0) {
        differing++;
        largest = math.max(largest, difference);
      }
    }
    expect(differing, 0, reason: '$name: $differing bytes differ, by $largest at most');
    return '$name equal';
  }
  final reference = saved.buffer.asFloat32List();
  final values = output.values;
  var largest = 0.0;
  var low = double.infinity;
  var high = -double.infinity;
  var magnitude = 0.0;
  for (var i = 0; i < reference.length; i++) {
    expect(values[i].isFinite, isTrue, reason: '$name at $i');
    largest = math.max(largest, (reference[i] - values[i]).abs());
    low = math.min(low, values[i]);
    high = math.max(high, values[i]);
    magnitude = math.max(magnitude, values[i].abs());
  }
  final spread = math.max(high - low, magnitude);
  final relative = spread == 0 ? largest : largest / spread;
  expect(relative, lessThanOrEqualTo(1e-4), reason: '$name: largest difference $largest, $relative of $spread');
  return '$name ${relative.toStringAsExponential(1)}';
}

void main() {
  final ort = ortForTests();
  final environment = Platform.environment;
  final inputs = environment['IMMUCH360_AI_INPUTS'];
  final moge = environment['IMMUCH360_AI_MOGE'];
  final lama = environment['IMMUCH360_AI_LAMA'];
  final migan = environment['IMMUCH360_AI_MIGAN'];
  final maps = environment['IMMUCH360_ORT_MAPS'];
  final skip =
      ort.skip ??
      (inputs == null || (moge == null && lama == null && migan == null)
          ? 'set IMMUCH360_AI_INPUTS and IMMUCH360_AI_MOGE, IMMUCH360_AI_LAMA or IMMUCH360_AI_MIGAN (see this file)'
          : null);

  test(
    'the real models of phase 2 give the same outputs on every version of ONNX Runtime',
    () {
      final runtime = OrtRuntime.load(ort.library!);
      final settings = OrtSessionSettings.forThisComputer().withCpuMemArena(false);
      OrtSession? open(String? path) {
        if (path == null) {
          return null;
        }
        final watch = Stopwatch()..start();
        final session = runtime.openSession(path, settings: settings);
        // ignore: avoid_print
        print('ONNX Runtime ${runtime.version}: ${p.basename(path)} opened in ${watch.elapsedMilliseconds} ms');
        return session;
      }

      final mogeSession = open(moge);
      final lamaSession = open(lama);
      final miganSession = open(migan);
      addTearDown(() {
        mogeSession?.close();
        lamaSession?.close();
        miganSession?.close();
      });
      final files = Directory(inputs!).listSync().whereType<File>().where((file) => file.path.endsWith('.npy')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(files, isNotEmpty);
      var landscapes = 0;
      for (final file in files) {
        final name = p.basenameWithoutExtension(file.path);
        final photo = _readNpy(file);
        final height = photo.shape[0];
        final width = photo.shape[1];
        if (width > height) {
          landscapes++;
        }
        final image = _nchw(photo.values, height, width);
        final lines = <String>['$name $width x $height'];
        if (mogeSession != null) {
          final watch = Stopwatch()..start();
          final outputs = mogeSession.runNamed({
            'image': OrtTensor([1, 3, height, width], image),
            'num_tokens': OrtTensor.int64Scalar(2500),
          });
          lines.add('MoGe ${watch.elapsedMilliseconds} ms');
          expect(outputs['points']!.shape, [1, height, width, 3]);
          expect(outputs['mask']!.shape, [1, height, width]);
          expect(outputs['scale']!.shape, [1]);
          for (final MapEntry(key: output, value: tensor) in outputs.entries) {
            if (maps != null) {
              lines.add(_keepOrCompare(maps, '${name}_moge_$output', tensor));
            }
          }
        }
        if ((lamaSession != null || miganSession != null) && height >= 512 && width >= 512) {
          final region = _crop(image, height, width, 512);
          if (lamaSession != null) {
            final mask = Float32List(512 * 512);
            for (var i = 0; i < mask.length; i++) {
              mask[i] = _inHole(i ~/ 512, i % 512) ? 1 : 0;
            }
            final watch = Stopwatch()..start();
            final output = lamaSession.runNamed({
              'image': OrtTensor(const [1, 3, 512, 512], region),
              'mask': OrtTensor(const [1, 1, 512, 512], mask),
            })['output']!;
            lines.add('LaMa ${watch.elapsedMilliseconds} ms');
            expect(output.shape, [1, 3, 512, 512]);
            if (maps != null) {
              lines.add(_keepOrCompare(maps, '${name}_lama_output', output));
            }
          }
          if (miganSession != null) {
            final bytes = Uint8List.fromList([for (final value in region) (value * 255).round()]);
            final mask = Uint8List.fromList([for (var i = 0; i < 512 * 512; i++) _inHole(i ~/ 512, i % 512) ? 0 : 255]);
            final watch = Stopwatch()..start();
            final result = miganSession.runNamed({
              'image': OrtTensor.uint8(const [1, 3, 512, 512], bytes),
              'mask': OrtTensor.uint8(const [1, 1, 512, 512], mask),
            })['result']!;
            lines.add('MI-GAN ${watch.elapsedMilliseconds} ms');
            expect(result.type, OrtElementType.uint8);
            expect(result.shape, [1, 3, 512, 512]);
            if (maps != null) {
              lines.add(_keepOrCompare(maps, '${name}_migan_result', result));
            }
          }
        }
        // ignore: avoid_print
        print(lines.join(', '));
      }
      expect(landscapes, greaterThan(0), reason: 'a landscape photo is the one that fails where loading does not');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
