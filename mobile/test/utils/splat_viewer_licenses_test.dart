import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/splat_viewer_licenses.dart';

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
  final assets = {
    for (final asset in [sparkLicenseAsset, threeLicenseAsset, fflateLicenseAsset, sparkCratesNoticeAsset])
      asset: File(asset).readAsStringSync(),
  };
  String textOf(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).join('\n');

  test('every build lists Spark, three.js, fflate and the crates of the WebAssembly, with their texts', () async {
    final entries = await splatViewerLicenses(bundle: _TextBundle(assets)).toList();
    expect(entries.map((entry) => entry.packages.single), ['Spark', 'three.js', 'fflate', 'Spark WebAssembly crates']);
    final spark = textOf(entries[0]);
    expect(spark, contains('Spark 2.4.0'));
    expect(spark, contains('WORLD LABS TECHNOLOGIES, INC.'));
    expect(spark, contains('Permission is hereby granted, free of charge'));
    expect(textOf(entries[1]), contains('three.js authors'));
    expect(textOf(entries[2]), contains('Arjun Barrett'));
    final crates = textOf(entries[3]);
    expect(crates, contains('miniz_oxide'));
    expect(crates, contains('wasm-bindgen'));
    expect(crates, isNot(contains('zlib-rs')));
  });

  test('a text missing from the bundle is left out, the others listed', () async {
    final some = Map.of(assets)..remove(fflateLicenseAsset);
    final entries = await splatViewerLicenses(bundle: _TextBundle(some)).toList();
    expect(entries.map((entry) => entry.packages.single), ['Spark', 'three.js', 'Spark WebAssembly crates']);
  });

  test('the assets are declared in pubspec.yaml for every build, and main.dart registers them with CRLF', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('    - assets/licenses/splat-viewer/\n'));
    expect(pubspec, contains('    - assets/splat_viewer/\n'));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('LicenseRegistry.addLicense(splatViewerLicenses);\r\n'));
  });
}
