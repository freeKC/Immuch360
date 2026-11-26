import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/stereo_disparity.dart';

/// A random dot scene of [width] x [height] whose right eye sees every pixel moved left by [disparityAt] (the left eye
/// at x shows what the right eye shows at x - d): a far plane and whatever [disparityAt] puts in front of it
GrayEyes _scene(int width, int height, double Function(int x, int y) disparityAt, {int seed = 7}) {
  final random = math.Random(seed);
  // A wide texture, so that a shifted read never leaves it
  final texWidth = width * 2;
  final texture = Float32List(texWidth * height);
  for (var i = 0; i < texture.length; i++) {
    texture[i] = random.nextDouble();
  }
  double at(double x, int y) {
    // Linear between the dots of the row, as a camera would blend them
    final x0 = x.floor().clamp(0, texWidth - 2);
    final t = x - x0;
    return texture[y * texWidth + x0] * (1 - t) + texture[y * texWidth + x0 + 1] * t;
  }

  final left = Float32List(width * height);
  final right = Float32List(width * height);
  final offset = width / 2;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // The texture lies on the surfaces: the left eye reads it at x, the right eye at x + d of its own
      left[y * width + x] = at(x + offset, y);
    }
  }
  // The right eye: for each of its pixels, the left pixels that show the same point (xL = xR + d(xL)); of several, the
  // nearest one (largest d) hides the others. Where none does, the fixed point of the far surface.
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      double? nearest;
      for (var xl = math.max(0, x - 40); xl < math.min(width, x + 41); xl++) {
        final d = disparityAt(xl, y);
        if ((xl - d - x).abs() <= 0.5 && (nearest == null || d > nearest)) {
          nearest = d;
        }
      }
      var d = nearest ?? disparityAt(x, y);
      if (nearest == null) {
        for (var i = 0; i < 4; i++) {
          d = disparityAt((x + d).round().clamp(0, width - 1), y);
        }
      }
      right[y * width + x] = at(x + d + offset, y);
    }
  }
  return GrayEyes(width: width, height: height, left: left, right: right);
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

void main() {
  group('matching', () {
    test('a flat plane at 6 pixels gives 6 everywhere inside, sub pixel steps included', () {
      for (final shift in [6.0, 6.5, -3.25]) {
        final eyes = _scene(96, 48, (_, _) => shift);
        final raw = matchDisparity(eyes.left, eyes.right, eyes.width, eyes.height, searchRange: 12, direction: 1);
        final errors = <double>[];
        for (var y = 0; y < eyes.height; y++) {
          for (var x = 20; x < eyes.width - 20; x++) {
            final i = y * eyes.width + x;
            expect(raw.validity[i], 1.0, reason: 'x $x y $y');
            errors.add((raw.disparity[i] - shift).abs());
          }
        }
        expect(_median(errors), lessThan(0.2), reason: 'shift $shift');
      }
    });

    test('the right eye as reference finds the same disparity', () {
      final eyes = _scene(96, 48, (_, _) => 5);
      final raw = matchDisparity(eyes.right, eyes.left, eyes.width, eyes.height, searchRange: 12, direction: -1);
      final i = 24 * eyes.width + 48;
      expect(raw.disparity[i], closeTo(5, 0.25));
    });

    test('the borders and a flat area are unreliable, as on the phones', () {
      const width = 64;
      const height = 32;
      final flat = Float32List(width * height)..fillRange(0, width * height, 0.5);
      final raw = matchDisparity(flat, flat, width, height, searchRange: 4, direction: 1);
      expect(raw.validity.every((v) => v == 0), isTrue);
      final eyes = _scene(width, height, (_, _) => 2);
      final textured = matchDisparity(eyes.left, eyes.right, width, height, searchRange: 4, direction: 1);
      for (var y = 0; y < height; y++) {
        expect(textured.validity[y * width + 2], 0, reason: 'left border');
        expect(textured.validity[y * width + width - 3], 0, reason: 'right border');
      }
    });
  });

  group('the whole chain', () {
    test('a square in front of a far plane: near bright, far dark, edges where they belong', () {
      // The far plane at 1 pixel, a square at 9 pixels in the middle
      bool inSquare(int x, int y) => x >= 60 && x < 100 && y >= 20 && y < 60;
      final eyes = _scene(160, 80, (x, y) => inSquare(x, y) ? 9 : 1);
      final map = computeDisparity(eyes, searchRange: 14);
      expect(map.width, 160);
      expect(map.height, 80);
      expect(map.left[40 * 160 + 80], closeTo(9, 0.6), reason: 'centre of the square');
      expect(map.left[40 * 160 + 30], closeTo(1, 0.6), reason: 'far plane');
      expect(map.right[40 * 160 + 72], closeTo(9, 0.6), reason: 'the square seen from the right eye');
      expect(map.left[70 * 160 + 130], closeTo(1, 0.6), reason: 'far plane, bottom right');
    });

    test('the left right check throws out the occluded strip beside a near object', () {
      bool inSquare(int x, int y) => x >= 60 && x < 100 && y >= 20 && y < 60;
      final eyes = _scene(160, 80, (x, y) => inSquare(x, y) ? 10 : 0);
      final rawLeft = matchDisparity(eyes.left, eyes.right, 160, 80, searchRange: 14, direction: 1);
      final rawRight = matchDisparity(eyes.right, eyes.left, 160, 80, searchRange: 14, direction: -1);
      final checked = checkConsistency(rawLeft, rawRight, 160, 80);
      // Just left of the square, the left eye sees background that the square hides from the right eye
      var rejected = 0;
      for (var x = 52; x < 59; x++) {
        if (checked.leftValidity[40 * 160 + x] == 0) {
          rejected++;
        }
      }
      expect(rejected, greaterThanOrEqualTo(4));
      // Far from the edges both checks pass
      expect(checked.leftValidity[40 * 160 + 80], 1);
      expect(checked.leftValidity[40 * 160 + 30], 1);
    });

    test('holes take the farther of their neighbours, then the blur smooths', () {
      final values = Float32List.fromList([2, 2, 0, 0, 8, 8]);
      final validity = Float32List.fromList([1, 1, 0, 0, 1, 1]);
      fillHoles(values, validity, 6, 1);
      expect(values, [2, 2, 2, 2, 8, 8]);
      final blurred = Float32List.fromList([0, 0, 10, 0, 0]);
      final blurValidity = Float32List.fromList([1, 1, 1, 1, 1]);
      final (out, outValidity) = blurOnce(blurred, blurValidity, 5, 1, horizontal: true);
      expect(out[2], closeTo(10 * 6 / 16, 1e-6));
      expect(out[1], closeTo(10 * 4 / 16, 1e-6));
      expect(outValidity[2], closeTo(1, 1e-6));
    });

    test('encoded as RGBA: both maps over their own range, opaque, and decoded back', () {
      final map = DisparityMap(
        width: 2,
        height: 1,
        left: Float32List.fromList([-4, 12]),
        right: Float32List.fromList([0, 8]),
        leftValidity: Float32List.fromList([1, 0]),
      );
      final encoded = encodeDisparityMap(map);
      expect(encoded.minimum, -4);
      expect(encoded.range, 16);
      expect(encoded.rgba, [0, 64, 255, 255, 255, 191, 0, 255]);
      expect(encoded.decode(encoded.rgba[4]), closeTo(12, 1e-9));
      // A flat map still gets a range, so that the shader never divides by zero
      final flat = encodeDisparityMap(
        DisparityMap(
          width: 1,
          height: 1,
          left: Float32List.fromList([3]),
          right: Float32List.fromList([3]),
          leftValidity: Float32List.fromList([1]),
        ),
      );
      expect(flat.range, greaterThan(0));
    });

    test('the map size keeps the shown shape of the eye and the pixel count of the phones\' high tier', () {
      expect(disparityMapSize(1920, 1080), (width: 640, height: 360));
      expect(disparityMapSize(1080, 1920), (width: 360, height: 640));
      expect(disparityMapSize(1000, 1000), (width: 480, height: 480));
      // A small photo is never scaled up
      expect(disparityMapSize(300, 200), (width: 300, height: 200));
      expect(disparityMapSearchRange(640), 32);
      expect(disparityMapSearchRange(20), 2);
    });

    test('640 x 360 takes well under the budget of a photo opening', () {
      final eyes = _scene(640, 360, (x, _) => 4 + 8 * x / 640);
      final watch = Stopwatch()..start();
      final map = computeDisparity(eyes);
      watch.stop();
      expect(map.left[180 * 640 + 320], closeTo(8, 0.7));
      // Debug mode in the tests is several times slower than a release build; the bound only catches a runaway
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
      // ignore: avoid_print
      print('disparity 640 x 360 in ${watch.elapsedMilliseconds} ms (test mode)');
    });
  });

  group('parity with the phones', () {
    // The constants of the Android passes (SpatialShaders.kt, SpatialRenderer.kt), read from their source
    final shaders = File(
      'android/app/src/main/kotlin/app/alextran/immich/spatial/SpatialShaders.kt',
    ).readAsStringSync();
    final renderer = File(
      'android/app/src/main/kotlin/app/alextran/immich/spatial/SpatialRenderer.kt',
    ).readAsStringSync();

    test('contrast floor, consistency tolerance, search fraction and blur kernel', () {
      expect(shaders, contains('const float MIN_CONTRAST = $disparityMinContrast;'));
      expect(renderer, contains('const val CONSISTENCY_TOLERANCE = ${disparityConsistencyTolerance}f'));
      expect(renderer, contains('const val SEARCH_FRACTION = ${disparitySearchFraction}f'));
      expect(renderer, contains('Quality.HIGH -> Tier($disparityMapWidth, $disparityMapHeight,'));
      expect(shaders, contains('float kernel[5] = float[5](${disparityBlurKernel.map((k) => '$k.0').join(', ')});'));
      // The 7 x 7 window: rows r - 3 to r + 3
      expect(shaders, contains('for (int r = 0; r < $disparityWindow; r++)'));
      expect(shaders, contains('rows[r] = clamp(p.y + r - ${disparityWindow ~/ 2}, 0, size.y - 1);'));
    });

    test('the photo shader follows the synthesis of the phones', () {
      final photo = File('shaders/spatial_photo.frag').readAsStringSync();
      // Three fixed point steps, the settled test, the half texel margin and the search of four pixels each side
      expect(shaders, contains('for (int i = 0; i < 3; i++) d = leftDisparity(uv.x + p * d, uv.y);'));
      expect(photo, contains('for (int i = 0; i < 3; i++) {'));
      expect(shaders, contains('for (int k = 1; k <= 4 && !found; k++) {'));
      expect(photo, contains('for (int k = 1; k <= 4; k++) {'));
      expect(shaders, contains('max(1.0 - p, 0.001) * left.z * leftInside'));
      expect(photo, contains('max(1.0 - p, 0.001) * left.z * leftInside'));
      expect(shaders, contains('if (m.g < 0.5) color *= vec3(1.0, 0.55, 0.55);'));
      expect(photo, contains('color *= vec3(1.0, 0.55, 0.55);'));
    });

    test('the sphere shader takes the same synthesis, word for word', () {
      final photo = File('shaders/spatial_photo.frag').readAsStringSync();
      final sphere = File('shaders/spatial_sphere.frag').readAsStringSync();
      String between(String source, String from, String to) {
        final start = source.indexOf(from);
        return source.substring(start, source.indexOf(to, start));
      }

      // The steps of each eye and the blend, the search along the row and the last resort
      for (final (from, to) in [
        ('vec3 solveLeft(vec2 uv) {', '// The right source'),
        ('vec3 solveRight(vec2 uv) {', '\n}\n'),
        ('  float p = uParams.w;\n  vec3 left = solveLeft(uv);', '  fragColor = vec4(color, 1.0);\n}'),
      ]) {
        expect(between(sphere, from, to), between(photo, from, to), reason: from);
      }
    });
  });
}
