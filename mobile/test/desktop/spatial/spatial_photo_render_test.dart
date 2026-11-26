import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';

const _sbs = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide);

Future<ui.Image> _imageOf(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  return (await codec.getNextFrame()).image;
}

/// A side by side frame of two [eye] x [eye] eyes of big random blocks, the right eye seeing everything [shift]
/// pixels to the left of where the left eye does (a plane in front of the screen)
Future<(ui.Image, Uint8List)> _frame(int eye, int shift) async {
  final random = math.Random(3);
  const block = 4;
  final cells = List.generate(eye ~/ block + 40, (_) => List.generate(eye ~/ block + 2, (_) => random.nextInt(256)));
  final rgba = Uint8List(eye * 2 * eye * 4);
  int value(int x, int y) => cells[(x + 64) ~/ block][y ~/ block];
  for (var y = 0; y < eye; y++) {
    for (var x = 0; x < eye; x++) {
      for (final (offset, source) in [(0, x), (eye, x + shift)]) {
        final i = (y * eye * 2 + offset + x) * 4;
        final v = value(source, y);
        rgba
          ..[i] = v
          ..[i + 1] = 255 - v
          ..[i + 2] = (v * 7) % 256
          ..[i + 3] = 255;
      }
    }
  }
  return (await _imageOf(rgba, eye * 2, eye), rgba);
}

Future<Uint8List> _render(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.round(), size.height.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  group('layout', () {
    test('eye rectangles of each packing, swapped or not', () {
      expect(_sbs.eyeRect(left: true), const Rect.fromLTWH(0, 0, 0.5, 1));
      expect(_sbs.eyeRect(left: false), const Rect.fromLTWH(0.5, 0, 0.5, 1));
      const crossed = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, swapped: true);
      expect(crossed.eyeRect(left: true), const Rect.fromLTWH(0.5, 0, 0.5, 1));
      const tb = SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom);
      expect(tb.eyeRect(left: true), const Rect.fromLTWH(0, 0, 1, 0.5));
      expect(tb.eyeRect(left: false), const Rect.fromLTWH(0, 0.5, 1, 0.5));
    });

    test('an eye is shown at its own shape, a squeezed one stretched back', () {
      const frame = Size(3840, 1080);
      expect(_sbs.eyeShownSize(frame), const Size(1920, 1080));
      const half = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, squeezed: true);
      expect(half.eyeShownSize(const Size(1920, 1080)), const Size(1920, 1080));
      const tb = SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom);
      expect(tb.eyeShownSize(const Size(1920, 2160)), const Size(1920, 1080));
      const halfTb = SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, squeezed: true);
      expect(halfTb.eyeShownSize(const Size(1920, 1080)), const Size(1920, 1080));
      expect(spatialPhotoArea(frame, _sbs, const Size(1000, 1000)), const Rect.fromLTWH(0, 218.75, 1000, 562.5));
    });

    test('the uniforms, in the order of the shader', () {
      final uniforms = spatialPhotoUniforms(
        size: const Size(800, 450),
        frame: const Size(3840, 1080),
        layout: _sbs,
        mapWidth: 640,
        minimum: -8,
        range: 32,
        viewpoint: 1.4,
      );
      expect(uniforms, hasLength(19));
      expect(uniforms.sublist(0, 2), [800, 450]);
      expect(uniforms.sublist(2, 10), [0, 0, 0.5, 1, 0.5, 0, 0.5, 1]);
      expect(uniforms[10], closeTo(0.5 / 1920, 1e-12));
      expect(uniforms[11], closeTo(0.5 / 1080, 1e-12));
      expect(uniforms[12], closeTo(-8 / 640, 1e-12));
      expect(uniforms[13], closeTo(32 / 640, 1e-12));
      expect(uniforms.sublist(14, 16), [1 / 640, 2 / 640]);
      expect(uniforms[17], 1.0, reason: 'the viewpoint is clamped');
      expect(uniforms[18], 0);
    });
  });

  group('the shader in the tests', () {
    testWidgets('loads, and draws the left eye at p 0, the right eye at p 1, the depth view in gray', (tester) async {
      await tester.runAsync(() async {
        final program = await ui.FragmentProgram.fromAsset(spatialPhotoShaderAsset);
        // 160 pixels: the search reaches 8 pixels each way (5 percent of the width)
        const eye = 160;
        const shift = 6;
        final (frame, rgba) = await _frame(eye, shift);
        final depth = await computeSpatialPhotoDepth(frame, _sbs);
        expect(depth.width, eye);
        // The plane: one disparity of about 6 everywhere
        expect(depth.minimum, lessThanOrEqualTo(shift + 0.5));
        expect(depth.minimum + depth.range, greaterThanOrEqualTo(shift - 0.5));

        final viewpoint = ValueNotifier(0.0);
        final painter = SpatialPhotoPainter(
          program: program,
          frame: frame,
          layout: _sbs,
          depth: depth,
          viewpoint: viewpoint,
        );
        int frameRed(int x, int y, {required bool right}) => rgba[(y * eye * 2 + (right ? eye : 0) + x) * 4];

        Future<double> meanError({required bool right}) async {
          final out = await _render(painter, const Size(eye * 1.0, eye * 1.0));
          var error = 0.0;
          var n = 0;
          for (var y = 10; y < eye - 10; y++) {
            for (var x = 16; x < eye - 16; x++) {
              error += (out[(y * eye + x) * 4] - frameRed(x, y, right: right)).abs();
              n++;
            }
          }
          return error / n;
        }

        viewpoint.value = 0;
        final leftAtZero = await meanError(right: false);
        final rightAtZero = await meanError(right: true);
        viewpoint.value = 1;
        final leftAtOne = await meanError(right: false);
        final rightAtOne = await meanError(right: true);
        debugPrint('p 0: left $leftAtZero right $rightAtZero; p 1: left $leftAtOne right $rightAtOne');
        expect(leftAtZero, lessThan(6));
        expect(rightAtOne, lessThan(6));
        // The eyes differ: each view is far from the other eye
        expect(rightAtZero, greaterThan(30));
        expect(leftAtOne, greaterThan(30));

        // Between the eyes the scene moves half way: the pixel x shows what the left eye shows at x + 3
        viewpoint.value = 0.5;
        final middle = await _render(painter, const Size(eye * 1.0, eye * 1.0));
        var error = 0.0;
        var n = 0;
        for (var y = 10; y < eye - 10; y++) {
          for (var x = 16; x < eye - 16; x++) {
            error += (middle[(y * eye + x) * 4] - frameRed(x + shift ~/ 2, y, right: false)).abs();
            n++;
          }
        }
        expect(error / n, lessThan(12));

        final depthView = SpatialPhotoPainter(
          program: program,
          frame: frame,
          layout: _sbs,
          depth: depth,
          viewpoint: viewpoint,
          showDepth: true,
        );
        final gray = await _render(depthView, const Size(eye * 1.0, eye * 1.0));
        const centre = ((eye ~/ 2) * eye + eye ~/ 2) * 4;
        expect(gray[centre], gray[centre + 1], reason: 'gray where the map is reliable');
        frame.dispose();
        depth.dispose();
      });
    });

    test('without a depth yet, the painter shows the left eye as it is', () async {
      final (frame, rgba) = await _frame(32, 2);
      final painter = SpatialPhotoPainter(
        program: null,
        frame: frame,
        layout: _sbs,
        depth: null,
        viewpoint: ValueNotifier(0.5),
      );
      final out = await _render(painter, const Size(32, 32));
      expect(out[(16 * 32 + 16) * 4], rgba[(16 * 64 + 16) * 4]);
    });
  });
}
