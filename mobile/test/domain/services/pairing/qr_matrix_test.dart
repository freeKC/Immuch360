import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/qr_matrix.dart';

/// The matrices python-qrcode made (make_qr_matrices.py): versions 1, 4, 5, 7, 8 and 10, every mask
List<Map<String, dynamic>> _cases() {
  final decoded = jsonDecode(File('test/fixtures/pairing/qr_matrices.json').readAsStringSync());
  return ((decoded as Map<String, dynamic>)['cases'] as List).cast<Map<String, dynamic>>();
}

List<String> _rows(QrMatrix matrix) => [
  for (var row = 0; row < matrix.size; row++)
    [for (var column = 0; column < matrix.size; column++) matrix.isDark(row, column) ? '1' : '0'].join(),
];

void main() {
  test('every module as another encoder places it, mask by mask', () {
    final cases = _cases();
    expect(cases, hasLength(48));
    for (final expected in cases) {
      final matrix = QrMatrix.encode(utf8.encode(expected['text']), mask: expected['mask']);
      final reason = '${expected['text']} mask ${expected['mask']}';
      expect(matrix.version, expected['version'], reason: reason);
      expect(matrix.size, 17 + 4 * matrix.version, reason: reason);
      expect(_rows(matrix), expected['rows'], reason: reason);
    }
  });

  test('the mask chosen is one of the eight, the same each time', () {
    const text = 'http://192.168.1.23:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA';
    final first = QrMatrix.encode(utf8.encode(text));
    final again = QrMatrix.encode(utf8.encode(text));
    expect(first.mask, inInclusiveRange(0, 7));
    expect(_rows(first), _rows(again));
    final forced = QrMatrix.encode(utf8.encode(text), mask: first.mask);
    expect(_rows(first), _rows(forced));
  });

  test('a pairing text is a version 5 code at most', () {
    const longest = 'http://192.168.100.200:65535/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA';
    expect(QrMatrix.encode(utf8.encode(longest)).version, lessThanOrEqualTo(5));
  });

  test('too long for version 10, a mask out of range', () {
    expect(() => QrMatrix.encode(List.filled(214, 65)), throwsArgumentError);
    expect(QrMatrix.encode(List.filled(213, 65)).version, 10);
    expect(() => QrMatrix.encode([65], mask: 8), throwsArgumentError);
  });
}
