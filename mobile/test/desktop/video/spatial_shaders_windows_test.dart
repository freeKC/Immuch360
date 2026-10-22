// The Spatial passes of renderer C (packages/media_kit_video/windows/spatial_shaders.h, IMMUCH360-NOTE.md patch 11)
// in the ANGLE of the Windows build, without a window (the hosted runners have no GPU: Windows' Basic Render Driver,
// WARP, draws in software):
// - every program compiles and links in OpenGL ES 3.0, put together as SpatialRenderer::PreparePrograms does, with
//   the time each took (Direct3D's compiler and the loops of the disparity pass);
// - the passes run in SpatialRenderer::ComputeDisparity's order on a random dot stereo pair whose square stands 8
//   pixels nearer than its background: the matching finds 8 plus or minus 1 in the square and 0 around it, from either
//   eye, in RGBA8 maps and, where the driver renders into them, in RGBA16F maps without a NaN;
// - the view at p = 0 is the left eye, at p = 1 the right eye, and half way the square moved by 4 pixels while the
//   background stayed;
// - the flat eye pass keeps the first row at the top and never reads the other eye; the equirectangular eye (renderer
//   C's pass with kEyeSphereMain) writes in its alpha whether a VR180 eye covers the direction.
// On Windows, after a build of the app (it holds libEGL.dll and libGLESv2.dll):
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/video/spatial_shaders_windows_test.dart
// On Linux, against Mesa (for the work on the passes): IMMUCH360_GLES=mesa LIBGL_ALWAYS_SOFTWARE=1 flutter test <file>

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'gles_for_tests.dart';

/// The GLSL constants of a header of the plugin by name
Map<String, String> _constants(String header) => {
  for (final match in RegExp(
    r'constexpr const char\* (k\w+) = R"glsl\((.*?)\)glsl";',
    dotAll: true,
  ).allMatches(File(p.join('packages', 'media_kit_video', 'windows', header)).readAsStringSync()))
    match.group(1)!: match.group(2)!,
};

/// The programs of the passes, vertex and fragment sources, put together as SpatialRenderer::PreparePrograms does
Map<String, (String, String)> _programSources() {
  final spatial = _constants('spatial_shaders.h');
  final projection = _constants('projection_shaders.h');
  final vertex = spatial['kVertex']!;
  final prefix = spatial['kFragmentPrefix']!;
  return {
    'eye flat': (vertex, prefix + spatial['kEyeIo']! + spatial['kEyeFlat']!),
    'eye equirectangular': (
      projection['kVertexSource']!,
      [
        projection['kFragmentHeader']!,
        '#define PROJECTION_KIND 0\n',
        projection['kFragmentCommon']!,
        projection['kFragmentEquirect']!,
        spatial['kEyeSphereMain']!,
      ].join(),
    ),
    'copy': (vertex, prefix + spatial['kCopy']!),
    'gray': (vertex, prefix + spatial['kGrayPack']!),
    'disparity': (vertex, prefix + spatial['kDisparity']!),
    'blend': (vertex, prefix + spatial['kBlend']!),
    'blur': (vertex, prefix + spatial['kBlur']!),
    'synthesis': (vertex, prefix + spatial['kSynthesis']!),
    'show disparity': (vertex, prefix + spatial['kShowDisparity']!),
  };
}

// The stereo pair: eyes of 256 x 128 in grey dots of 2 x 2 pixels, the square [96, 160) x [32, 96) of the left eye
// stands 8 pixels nearer than the background (the right eye shows it 8 pixels further left), and the disparity maps at
// the size of the eyes, as SpatialRenderer.kt computes their search range and encoding
const _width = 256;
const _height = 128;
const _disparity = 8;
const _squareLeft = 96;
const _squareRight = 160;
const _squareTop = 32;
const _squareBottom = 96;
final _searchRange = math.max(2, (_width * 0.05).round());
const _encode = 1 / (_width * 2 * 0.1);

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted.isEmpty ? double.nan : sorted[sorted.length ~/ 2];
}

void main() {
  final skip = glesSkipReason() ?? false;
  final arena = Arena();
  late Gles gl;
  late int vertexArray;
  final programs = <String, int>{};
  final random = math.Random(20261022);
  final background = List.generate((_width ~/ 2) * (_height ~/ 2), (_) => random.nextInt(256));
  final square = List.generate(
    ((_squareRight - _squareLeft) ~/ 2) * ((_squareBottom - _squareTop) ~/ 2),
    (_) => random.nextInt(256),
  );

  // The grey of a pixel of an eye: in the square the right eye shows the left eye's column 8 pixels further right
  int grey(int x, int y, {required bool right}) {
    final column = right ? x + _disparity : x;
    if (y >= _squareTop && y < _squareBottom && column >= _squareLeft && column < _squareRight) {
      return square[((y - _squareTop) ~/ 2) * ((_squareRight - _squareLeft) ~/ 2) + (column - _squareLeft) ~/ 2];
    }
    return background[(y ~/ 2) * (_width ~/ 2) + x ~/ 2];
  }

  List<int> eye({required bool right}) => [
    for (var y = 0; y < _height; y++)
      for (var x = 0; x < _width; x++) ...[
        grey(x, y, right: right),
        grey(x, y, right: right),
        grey(x, y, right: right),
        255,
      ],
  ];

  setUpAll(() {
    if (skip != false) {
      return;
    }
    gl = Gles.open(arena);
    // ignore: avoid_print
    print('GLES: ${gl.string(glRenderer)}');
    final names = arena<Uint32>();
    gl.genVertexArrays(1, names);
    vertexArray = names.value;
  });

  tearDownAll(arena.releaseAll);

  int program(String name) => programs.putIfAbsent(name, () {
    final (vertex, fragment) = _programSources()[name]!;
    return gl.program(vertex, fragment);
  });

  // One pass of [name] into [target], the textures on units 0, 1, 2 in order
  void pass(String name, GlTarget target, List<int> textures, void Function(int Function(String) at) uniforms) {
    final id = program(name);
    gl
      ..useProgram(id)
      ..bindFramebuffer(glFramebuffer, target.framebuffer)
      ..viewport(0, 0, target.width, target.height);
    for (var unit = 0; unit < textures.length; unit++) {
      gl
        ..activeTexture(glTexture0 + unit)
        ..bindTexture(glTexture2d, textures[unit]);
    }
    uniforms((uniform) => gl.location(id, uniform));
    gl
      ..bindVertexArray(vertexArray)
      ..drawArrays(glTriangles, 0, 3);
  }

  // Passes 2 to 4 of SpatialRenderer::ComputeDisparity, the left right check on, the previous map cleared
  ({GlTarget left, GlTarget right, GlTarget rawLeft, GlTarget rawRight, GlTarget blurred}) estimate({
    required bool halfFloat,
  }) {
    final left = gl.target(arena, _width, _height, rgba: eye(right: false));
    final right = gl.target(arena, _width, _height, rgba: eye(right: true));
    GlTarget map({int filter = glNearest}) => gl.target(arena, _width, _height, filter: filter, halfFloat: halfFloat);
    final greyLeft = gl.target(arena, _width, _height, filter: glNearest);
    final greyRight = gl.target(arena, _width, _height, filter: glNearest);
    final rawLeft = map();
    final rawRight = map();
    final previous = map();
    final next = map();
    final temp = map();
    final blurred = map(filter: glLinear);
    for (final target in [left, right, greyLeft, greyRight, rawLeft, rawRight, previous, next, temp, blurred]) {
      expect(target.valid, isTrue, reason: 'a target the passes draw into');
    }
    for (final (source, target) in [(left, greyLeft), (right, greyRight)]) {
      pass('gray', target, [source.texture], (at) {
        gl
          ..uniform1i(at('u_eye'), 0)
          ..uniform2f(at('u_texel'), 1 / _width, 1 / _height);
      });
    }
    for (final (target, reference, other, direction) in [
      (rawLeft, greyLeft, greyRight, 1),
      (rawRight, greyRight, greyLeft, -1),
    ]) {
      pass('disparity', target, [reference.texture, other.texture], (at) {
        gl
          ..uniform1i(at('u_reference'), 0)
          ..uniform1i(at('u_other'), 1)
          ..uniform1i(at('u_searchRange'), _searchRange)
          ..uniform1f(at('u_encode'), _encode)
          ..uniform1i(at('u_direction'), direction);
      });
    }
    gl
      ..bindFramebuffer(glFramebuffer, previous.framebuffer)
      ..viewport(0, 0, _width, _height)
      ..clearColor(0.5, 0, 0.5, 0)
      ..clear(glColorBufferBit);
    pass('blend', next, [rawLeft.texture, rawRight.texture, previous.texture], (at) {
      gl
        ..uniform1i(at('u_rawLeft'), 0)
        ..uniform1i(at('u_rawRight'), 1)
        ..uniform1i(at('u_previous'), 2)
        ..uniform1i(at('u_check'), 1)
        ..uniform1f(at('u_newWeight'), 1)
        ..uniform1f(at('u_encode'), _encode)
        ..uniform1f(at('u_tolerance'), 1);
    });
    pass('blur', temp, [next.texture], (at) {
      gl
        ..uniform1i(at('u_map'), 0)
        ..uniform2i(at('u_direction'), 1, 0);
    });
    pass('blur', blurred, [temp.texture], (at) {
      gl
        ..uniform1i(at('u_map'), 0)
        ..uniform2i(at('u_direction'), 0, 1);
    });
    gl.finish();
    expect(gl.getError(), 0);
    return (left: left, right: right, rawLeft: rawLeft, rawRight: rawRight, blurred: blurred);
  }

  // The encoded disparities (r) and validities (g) of a map, as floats in 0 to 1, first row first
  List<double> channels(GlTarget map, {required bool halfFloat}) {
    if (halfFloat) {
      final values = gl.readFloat(map);
      expect(values, isNotNull, reason: 'glReadPixels of an RGBA16F target as floats');
      return values!;
    }
    return [for (final byte in gl.read8(map)) byte / 255];
  }

  // The disparities in pixels of the valid pixels of a map in a rectangle
  List<double> disparities(List<double> rgba, int left, int top, int right, int bottom) => [
    for (var y = top; y < bottom; y++)
      for (var x = left; x < right; x++)
        if (rgba[(y * _width + x) * 4 + 1] > 0.5) (rgba[(y * _width + x) * 4] - 0.5) / _encode,
  ];

  test('the Spatial programs compile and link in OpenGL ES 3.0', () {
    for (final name in _programSources().keys) {
      final watch = Stopwatch()..start();
      expect(program(name), greaterThan(0), reason: name);
      // ignore: avoid_print
      print('$name: compiled and linked in ${watch.elapsedMilliseconds} ms');
    }
  }, skip: skip);

  for (final halfFloat in [false, true]) {
    test('the disparity of a random dot pair, ${halfFloat ? 'RGBA16F' : 'RGBA8'} maps', () {
      if (halfFloat && !gl.target(arena, 4, 4, halfFloat: true).valid) {
        markTestSkipped('this driver does not render into RGBA16F textures');
        return;
      }
      final maps = estimate(halfFloat: halfFloat);
      final rawLeft = channels(maps.rawLeft, halfFloat: halfFloat);
      final rawRight = channels(maps.rawRight, halfFloat: halfFloat);
      final blurred = channels(maps.blurred, halfFloat: halfFloat);
      for (final value in [...rawLeft, ...rawRight, ...blurred]) {
        expect(value.isNaN, isFalse, reason: 'no NaN in the maps');
      }
      for (var i = 0; i < blurred.length; i += 4) {
        expect(blurred[i], inInclusiveRange(0, 1), reason: 'the encoded disparity stays in range');
      }
      void near(List<double> values, double expected, String where) {
        final area = (values.length / 0.9).ceil();
        expect(values.length, greaterThan(0), reason: '$where: valid pixels');
        final median = _median(values);
        final close = values.where((value) => (value - expected).abs() <= 1).length;
        // ignore: avoid_print
        print(
          '$where: ${values.length} valid, median ${median.toStringAsFixed(2)}, ${close * 100 ~/ values.length}% '
          'within 1 of $expected',
        );
        expect((median - expected).abs(), lessThanOrEqualTo(1), reason: '$where: median');
        expect(close, greaterThanOrEqualTo((0.9 * values.length).floor()), reason: '$where ($area)');
      }

      // Inside the square, away from its edges by the half window and the blur, and around it
      near(
        disparities(rawLeft, _squareLeft + 4, _squareTop + 4, _squareRight - 4, _squareBottom - 4),
        8,
        'left map, square',
      );
      near(disparities(rawLeft, 16, 8, 80, 120), 0, 'left map, background');
      near(
        disparities(
          rawRight,
          _squareLeft - _disparity + 4,
          _squareTop + 4,
          _squareRight - _disparity - 4,
          _squareBottom - 4,
        ),
        8,
        'right map, square',
      );
      near(
        disparities(blurred, _squareLeft + 6, _squareTop + 6, _squareRight - 6, _squareBottom - 6),
        8,
        'blurred, square',
      );
      final blurredRight = [
        for (var i = 0; i < blurred.length; i += 4) ...[blurred[i + 2], blurred[i + 3], 0.0, 0.0],
      ];
      near(
        disparities(
          blurredRight,
          _squareLeft - _disparity + 6,
          _squareTop + 6,
          _squareRight - _disparity - 6,
          _squareBottom - 6,
        ),
        8,
        'blurred right, square',
      );

      // The view between the eyes (SpatialRenderer.kt's drawSynthesis)
      List<int> view(double viewpoint) {
        final output = gl.target(arena, _width, _height);
        pass('synthesis', output, [maps.left.texture, maps.right.texture, maps.blurred.texture], (at) {
          gl
            ..uniform1i(at('u_left'), 0)
            ..uniform1i(at('u_right'), 1)
            ..uniform1i(at('u_map'), 2)
            ..uniform1f(at('u_viewpoint'), viewpoint)
            ..uniform1f(at('u_decode'), 2 * 0.1)
            ..uniform1f(at('u_threshold'), 1 / _width)
            ..uniform1f(at('u_searchStep'), 2 / _width)
            ..uniform1i(at('u_hasRightMap'), 1);
        });
        gl.finish();
        return gl.read8(output);
      }

      // Mean difference of the grey of the view against an eye shifted by [shift] in a rectangle
      double difference(
        List<int> pixels,
        int left,
        int top,
        int right,
        int bottom, {
        required bool rightEye,
        int shift = 0,
      }) {
        var sum = 0;
        var count = 0;
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            sum += (pixels[(y * _width + x) * 4] - grey(x + shift, y, right: rightEye)).abs();
            count++;
          }
        }
        return sum / count;
      }

      final atLeft = view(0);
      final atRight = view(1);
      final halfWay = view(0.5);
      final atLeftDifference = difference(atLeft, 0, 0, _width, _height, rightEye: false);
      final atRightDifference = difference(atRight, 0, 0, _width, _height, rightEye: true);
      final squareMoved = difference(
        halfWay,
        _squareLeft + 6,
        _squareTop + 4,
        _squareRight - 10,
        _squareBottom - 4,
        rightEye: false,
        shift: 4,
      );
      final squareStill = difference(
        halfWay,
        _squareLeft + 6,
        _squareTop + 4,
        _squareRight - 10,
        _squareBottom - 4,
        rightEye: false,
      );
      final backgroundStill = difference(halfWay, 8, 8, 72, 120, rightEye: false);
      // ignore: avoid_print
      print(
        'view: p 0 against the left eye ${atLeftDifference.toStringAsFixed(2)}, p 1 against the right eye '
        '${atRightDifference.toStringAsFixed(2)}, p 0.5 square against the left eye moved by 4 '
        '${squareMoved.toStringAsFixed(2)} (not moved ${squareStill.toStringAsFixed(2)}), background '
        '${backgroundStill.toStringAsFixed(2)} (grey levels)',
      );
      expect(atLeftDifference, lessThan(1.0), reason: 'p = 0 is the left eye');
      expect(atRightDifference, lessThan(1.0), reason: 'p = 1 is the right eye');
      expect(squareMoved, lessThan(8.0), reason: 'half way the square moved by half its disparity');
      expect(squareStill, greaterThan(30.0), reason: 'and is not where the left eye has it');
      expect(backgroundStill, lessThan(8.0), reason: 'the background at disparity 0 stays');
      expect(gl.getError(), 0);
    }, skip: skip);
  }

  test('the flat eye keeps the first row at the top and never reads the other eye', () {
    // A side by side frame of 64 x 32: the left eye red, the right eye blue, the green growing from the top row down
    const frameWidth = 64;
    const frameHeight = 32;
    final frame = gl.target(
      arena,
      frameWidth,
      frameHeight,
      wrap: glRepeat,
      rgba: [
        for (var y = 0; y < frameHeight; y++)
          for (var x = 0; x < frameWidth; x++) ...[x < 32 ? 255 : 0, y * 8, x < 32 ? 0 : 255, 255],
      ],
    );
    final eyeTarget = gl.target(arena, 32, 32);
    final identity = arena<Float>(16);
    for (var i = 0; i < 16; i++) {
      identity[i] = i % 5 == 0 ? 1 : 0;
    }
    pass('eye flat', eyeTarget, [frame.texture], (at) {
      gl
        ..uniform1i(at('u_video'), 0)
        ..uniformMatrix4fv(at('u_texMatrix'), 1, 0, identity)
        // The right eye; its left side touches the left eye: one texel of the frame inwards
        ..uniform4f(at('u_rect'), 0.5, 0, 0.5, 1)
        ..uniform4f(at('u_inset'), 1 / 32, 0, 0, 0);
    });
    gl.finish();
    final pixels = gl.read8(eyeTarget);
    expect(pixels[0 * 4 + 1], lessThan(16), reason: 'the first row is the top of the frame');
    expect(pixels[(31 * 32) * 4 + 1], greaterThan(230), reason: 'the last row its bottom');
    for (var i = 0; i < pixels.length; i += 4) {
      expect(pixels[i], lessThan(8), reason: 'no red of the left eye in the right one');
      expect(pixels[i + 2], greaterThan(247));
    }
  }, skip: skip);

  test('an equirectangular eye writes in its alpha whether a VR180 eye covers the direction', () {
    final frame = gl.target(
      arena,
      128,
      64,
      wrap: glRepeat,
      rgba: [
        for (var i = 0; i < 128 * 64; i++) ...[0, 200, 0, 255],
      ],
    );
    final eyeTarget = gl.target(arena, 32, 32);
    final matrix = arena<Float>(9);
    (int, int) draw(double yaw) {
      // ProjectionRenderer::ViewToSphere: rows of Ry(yaw), uploaded column major
      final cy = math.cos(yaw * math.pi / 180);
      final sy = math.sin(yaw * math.pi / 180);
      final rows = [cy, 0.0, sy, 0.0, 1.0, 0.0, -sy, 0.0, cy];
      for (var i = 0; i < 9; i++) {
        matrix[i] = rows[(i % 3) * 3 + i ~/ 3];
      }
      pass('eye equirectangular', eyeTarget, [frame.texture], (at) {
        gl
          ..uniform1i(at('uSource'), 0)
          ..uniformMatrix3fv(at('uViewToSphere'), 1, 0, matrix)
          ..uniform2f(at('uTanHalfFov'), 1, 1)
          ..uniform1f(at('uSharp'), 0)
          ..uniform2f(at('uOutputSize'), 32, 32)
          ..uniform1f(at('uTexelsPerPixel'), 1)
          ..uniform4f(at('uEye'), 0, 0, 1, 1)
          ..uniform4f(at('uCrop'), 0.25, 0, 0.5, 1);
      });
      gl.finish();
      final pixels = gl.read8(eyeTarget);
      const centre = (16 * 32 + 16) * 4;
      return (pixels[centre + 1], pixels[centre + 3]);
    }

    expect(draw(0), (200, 255), reason: 'ahead: the picture, covered');
    expect(draw(180), (0, 0), reason: 'behind a VR180 eye: black, not covered');
    expect(gl.getError(), 0);
  }, skip: skip);
}
