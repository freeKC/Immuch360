// The pictures of test/fixtures/ai_immersive/codec, made by .github/desktop/ai/make_codec_fixtures.py (Pillow on
// libjpeg, another encoder than the one under test), and what that script says they hold.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const codecFixtures = 'test/fixtures/ai_immersive/codec';

Uint8List codecFixture(String name) => File('$codecFixtures/$name').readAsBytesSync();

/// expected.json
final Map<String, dynamic> codecExpected =
    jsonDecode(File('$codecFixtures/expected.json').readAsStringSync()) as Map<String, dynamic>;

/// The colour of a key of expected.json, [r, g, b]
List<int> colourOf(Object? value) => (value! as List).cast<int>();

/// The RGB at ([x], [y]) of RGBA rows [width] pixels wide
List<int> rgbAt(Uint8List rgba, int width, int x, int y) {
  final at = (y * width + x) * 4;
  return [rgba[at], rgba[at + 1], rgba[at + 2]];
}

/// Whether two colours differ by at most [tolerance] on each channel
bool near(List<int> a, List<int> b, int tolerance) {
  for (var index = 0; index < 3; index++) {
    if ((a[index] - b[index]).abs() > tolerance) {
      return false;
    }
  }
  return true;
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
