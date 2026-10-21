import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/libsmb2_license.dart';

/// A text of the vendored package with the CRLF line ends a checkout on Windows gives it
String _withCrlf(String name) =>
    File('packages/dart_smb2/libsmb2/$name').readAsStringSync().replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

/// The assets of the vendored package as a build carries them, or none at all
class _PackageAssets extends CachingAssetBundle {
  final bool present;

  _PackageAssets({required this.present});

  @override
  Future<ByteData> load(String key) async {
    // flutter test runs in mobile/, where the assets of the package are at the path of their key
    final file = File(key);
    if (!present || !key.startsWith('$libsmb2LicenseAssets/') || !file.existsSync()) {
      throw FlutterError('Unable to load asset: "$key".');
    }
    return ByteData.sublistView(file.readAsBytesSync());
  }
}

List<String> _paragraphs(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).toList();

void main() {
  test('the libsmb2 entry of the licence page keeps no carriage return from CRLF texts', () {
    final entry = libsmb2LicenseEntry(_withCrlf('NOTICE'), _withCrlf('LICENCE-LGPL-2.1.txt'));
    final paragraphs = _paragraphs(entry);

    expect(entry.packages, ['libsmb2']);
    expect(paragraphs.where((text) => text.contains('\r')), isEmpty);
    expect(paragraphs.first, startsWith('libsmb2: the SMB2/3 client library'));
    expect(paragraphs, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
  });

  test(
    'the entry read from the assets opens with the notice, whose Source paragraph says where the sources are',
    () async {
      final entries = await libsmb2Licenses(_PackageAssets(present: true)).toList();

      expect(entries, hasLength(1));
      final paragraphs = _paragraphs(entries.single);
      expect(paragraphs.first, startsWith('libsmb2: the SMB2/3 client library'));
      final source = paragraphs.firstWhere((text) => text.startsWith('Source:'));
      expect(paragraphs.indexOf(source), lessThan(6), reason: 'near the top of the entry');
      expect(source, contains('Immuch360-libsmb2-sources.tar.gz'));
      const inTheApk = 'assets/flutter_assets/packages/dart_smb2/libsmb2/Immuch360-libsmb2-sources.tar.gz';
      expect(paragraphs.where((text) => text.contains(inTheApk)), isNotEmpty);
      expect(paragraphs, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
    },
  );

  test('texts that cannot be read give a short entry instead of an error on the licence page', () async {
    final entries = await libsmb2Licenses(_PackageAssets(present: false)).toList();

    expect(entries, hasLength(1));
    expect(entries.single.packages, ['libsmb2']);
    final text = _paragraphs(entries.single).join('\n');
    expect(_paragraphs(entries.single).first, 'Copyright (C) 2016-2025 Ronnie Sahlberg and the libsmb2 contributors.');
    expect(text, contains('GNU Lesser General Public License, version 2.1 or (at your option) any later version'));
    expect(text, contains('https://github.com/sahlberg/libsmb2'));
    expect(text, contains('Immuch360-libsmb2-sources.tar.gz'));
  });
}
