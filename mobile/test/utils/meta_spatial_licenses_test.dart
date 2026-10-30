import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/meta_spatial_licenses.dart';

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
  final licence = File(metaSpatialLicenseAsset).readAsStringSync().replaceAll('\r\n', '\n');
  final notice = File(metaSpatialNoticeAsset).readAsStringSync().replaceAll('\r\n', '\n');
  final assets = {metaSpatialLicenseAsset: licence, metaSpatialNoticeAsset: notice};

  String textOf(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).join('\n');

  test('Android lists the Meta Spatial SDK with its licence, then its notices', () async {
    final entries = await metaSpatialLicenses(android: true, bundle: _TextBundle(assets)).toList();
    expect(entries, hasLength(2));
    expect(entries.map((entry) => entry.packages), everyElement(['Meta Spatial SDK']));
    expect(textOf(entries.first), contains('Meta Platform Technologies SDK License Agreement'));
    expect(textOf(entries.first), contains('Meta Spatial SDK 0.14.0'));
    expect(textOf(entries.last), contains('Third Party Notices'));
    expect(textOf(entries.last), contains('Apache License'));
  });

  test('the other platforms list nothing', () async {
    expect(await metaSpatialLicenses(android: false, bundle: _TextBundle(assets)).toList(), isEmpty);
  });

  test('the licence is the text of the AARs of the SDK, byte for byte', () {
    if (!Platform.isWindows) {
      final bytes = File(metaSpatialLicenseAsset).readAsBytesSync();
      expect(sha256.convert(bytes).toString(), 'bb9b12db3b92c024458df625acd6f2d8140ea805cc6814bac74613a466731368');
      expect(File('../licenses/meta-spatial-sdk/LICENSE.txt').readAsBytesSync(), bytes);
    }
  });
}
