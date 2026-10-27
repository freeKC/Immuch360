import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/litert_licenses.dart';

/// An asset bundle that holds the given text files
class _TextBundle extends CachingAssetBundle {
  _TextBundle(this.files);

  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) {
      throw FlutterError('no asset $key');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

void main() {
  // The LiteRT licence of the repository, the text of its packages (a checkout on Windows may end its lines with \r\n)
  final licence = File('assets/licenses/litert/LICENSE').readAsStringSync().replaceAll('\r\n', '\n');

  test('the quest flavour lists LiteRT with its licence and where the notices of its libraries are', () async {
    final entries = await liteRtLicenses(flavor: 'quest', bundle: _TextBundle({liteRtLicenseAsset: licence})).toList();
    expect(entries, hasLength(1));
    expect(entries.single.packages, ['LiteRT']);
    final text = entries.single.paragraphs.map((paragraph) => paragraph.text).join('\n');
    expect(text, contains('LiteRT 2.3.0'));
    expect(text, contains('THIRD_PARTY_NOTICE.txt'));
    expect(text, contains('Apache License'));
    expect(text, contains('Version 2.0, January 2004'));
    // The BSD terms of the parts from Caffe travel with it
    expect(text, contains('The Regents of the University of California'));
  });

  test('the other builds ship no LiteRT and list nothing', () async {
    final bundle = _TextBundle({liteRtLicenseAsset: licence});
    expect(await liteRtLicenses(flavor: 'phone', bundle: bundle).toList(), isEmpty);
    expect(await liteRtLicenses(flavor: null, bundle: bundle).toList(), isEmpty);
    // flutter test builds without a flavour, like the computers
    expect(appFlavor, isNull);
    expect(await liteRtLicenses(bundle: bundle).toList(), isEmpty);
  });

  test('a quest build without the asset lists nothing rather than failing', () async {
    expect(await liteRtLicenses(flavor: 'quest', bundle: _TextBundle({})).toList(), isEmpty);
  });

  test('the licence asset is the one of the LiteRT 2.3.0 packages', () {
    expect(licence.length, 13575);
    expect(licence, startsWith('                                 Apache License\n'));
  });
}
