// Stitches a real Insta360 photo of the development machine as the app does, and compares the result with the export
// of Insta360 Studio when one is given: IMMUCH_INSTA_SAMPLE=/path/to/IMG_..._00_001.insp, and optionally
// IMMUCH_INSTA_REFERENCE=/path/to/the/Studio/export.jpg and IMMUCH_STITCH_OUT=/a/directory for the pictures. The files
// are only read, in place.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_stitcher.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';

final _sample = Platform.environment['IMMUCH_INSTA_SAMPLE'];
final _reference = Platform.environment['IMMUCH_INSTA_REFERENCE'];
final _out = Platform.environment['IMMUCH_STITCH_OUT'];

// The size the prototype of the stitch was compared with Studio at
const _width = 2048;
const _height = 1024;

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

Future<ui.Image> _decode(String path, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (_, _) => ui.TargetImageSize(width: width, height: height),
  );
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  return image;
}

Future<Uint8List> _pixels(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

// Mean absolute difference of the grey levels of two RGBA pictures of the same size, in levels of 255
double _greyDifference(Uint8List a, Uint8List b) {
  double grey(Uint8List rgba, int at) => 0.299 * rgba[at] + 0.587 * rgba[at + 1] + 0.114 * rgba[at + 2];
  var sum = 0.0;
  for (var at = 0; at < a.length; at += 4) {
    sum += (grey(a, at) - grey(b, at)).abs();
  }
  return sum / (a.length / 4);
}

void main() {
  testWidgets('stitches a real Insta360 photo', (tester) async {
    await tester.runAsync(() async {
      final path = _sample!;
      final file = await File(path).open();
      addTearDown(file.close);
      final calibration = (await resolveDualFisheyeCalibration(
        read: (offset, length) async {
          await file.setPosition(offset);
          return file.read(length);
        },
        fileSize: await file.length(),
        isPhoto: true,
        store: DualFisheyeCalibrationStore(() async => null),
      )).calibration;
      _print('${calibration.source.name} calibration of ${calibration.cameraModel}, gravity ${calibration.downBody}');

      // The frame decoded at twice the output width, as the panorama viewer decodes a frame wider than its stitch
      final frame = await _decode(path, 2 * _width, _width);
      final gpu = await (await DualFisheyeStitcher.load()).stitch(frame, calibration, maxWidth: _width);
      final cpu = await stitchDualFisheyeOnCpu(frame, calibration, width: _width);
      frame.dispose();
      final gpuPixels = await _pixels(gpu);
      final cpuPixels = await _pixels(cpu);
      _print('GPU and CPU stitches differ by ${_greyDifference(gpuPixels, cpuPixels).toStringAsFixed(2)} grey levels');
      expect(_greyDifference(gpuPixels, cpuPixels), lessThan(1));

      final out = _out;
      if (out != null) {
        Directory(out).createSync(recursive: true);
        File('$out/stitch_gpu.png').writeAsBytesSync(encodeOpaquePng(gpuPixels, _width, _height));
        File('$out/stitch_cpu.png').writeAsBytesSync(encodeOpaquePng(cpuPixels, _width, _height));
      }

      final reference = _reference;
      if (reference != null) {
        final studio = await _decode(reference, _width, _height);
        final studioPixels = await _pixels(studio);
        studio.dispose();
        final difference = _greyDifference(gpuPixels, studioPixels);
        // The prototype of the stitch, on the same photo and at this size, is 12.2 levels from Studio: the parallax of
        // near subjects and Studio's optical flow seams
        _print('The stitch differs from the export of Studio by ${difference.toStringAsFixed(2)} grey levels');
        if (out != null) {
          File('$out/studio.png').writeAsBytesSync(encodeOpaquePng(studioPixels, _width, _height));
        }
        expect(difference, lessThan(20));
      }
      gpu.dispose();
      cpu.dispose();
    });
    // Skipped unless IMMUCH_INSTA_SAMPLE names an Insta360 .insp photo
  }, skip: _sample == null);
}
