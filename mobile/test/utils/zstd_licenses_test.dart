import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/zstd_licenses.dart';

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
  final licence = File(zstdLicenseAsset).readAsStringSync();
  String textOf(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).join('\n');

  test('the quest flavour lists zstd-jni with its licence and the BSD licence of zstd', () async {
    final entries = await zstdLicenses(flavor: 'quest', bundle: _TextBundle({zstdLicenseAsset: licence})).toList();
    expect(entries, hasLength(1));
    expect(entries.single.packages, ['zstd-jni']);
    final text = textOf(entries.single);
    expect(text, contains('zstd-jni 1.5.7-3'));
    expect(text, contains('SPZ version 4'));
    expect(text, contains('Copyright (c) 2015-present, Luben Karavelov'));
    expect(text, contains('BSD-2-Clause License'));
    expect(text, contains('For Zstandard software'));
    expect(text, contains('Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.'));
    expect(text, contains('Neither the name Facebook, nor Meta, nor the names of its contributors'));
  });

  test('the other builds ship no zstd-jni and list nothing', () async {
    final bundle = _TextBundle({zstdLicenseAsset: licence});
    expect(await zstdLicenses(flavor: 'phone', bundle: bundle).toList(), isEmpty);
    expect(await zstdLicenses(flavor: null, bundle: bundle).toList(), isEmpty);
    // flutter test builds without a flavour, like the computers
    expect(appFlavor, isNull);
    expect(await zstdLicenses(bundle: bundle).toList(), isEmpty);
  });

  test('a quest build without the asset lists nothing rather than failing', () async {
    expect(await zstdLicenses(flavor: 'quest', bundle: _TextBundle({})).toList(), isEmpty);
  });
}
