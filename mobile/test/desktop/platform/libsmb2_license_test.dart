import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/libsmb2_license.dart';

/// A text of the vendored package with the CRLF line ends a checkout on Windows gives it
String _withCrlf(String name) =>
    File('packages/dart_smb2/libsmb2/$name').readAsStringSync().replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

void main() {
  test('the libsmb2 entry of the licence page keeps no carriage return from CRLF texts', () {
    final entry = libsmb2LicenseEntry(_withCrlf('NOTICE'), _withCrlf('LICENCE-LGPL-2.1.txt'));
    final paragraphs = entry.paragraphs.map((paragraph) => paragraph.text).toList();

    expect(entry.packages, ['libsmb2']);
    expect(paragraphs.where((text) => text.contains('\r')), isEmpty);
    expect(paragraphs.first, startsWith('libsmb2: the SMB2/3 client library'));
    expect(paragraphs, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
  });
}
