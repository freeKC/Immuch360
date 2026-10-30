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
    final entries = await metaSpatialLicenses(
      android: true,
      bundle: _TextBundle(assets),
      splatsInThisBuild: () async => true,
    ).toList();
    expect(entries, hasLength(2));
    expect(entries.map((entry) => entry.packages), everyElement(['Meta Spatial SDK']));
    expect(textOf(entries.first), contains('Meta Platform Technologies SDK License Agreement'));
    expect(textOf(entries.first), contains('Meta Spatial SDK 0.14.0'));
    expect(textOf(entries.last), contains('Third Party Notices'));
    expect(textOf(entries.last), contains('Apache License'));
  });

  test('a GitHub build lists the splat module as what shows the Gaussian splats of other tools, with the words '
      'that Meta neither supports nor warrants its API', () async {
    final entries = await metaSpatialLicenses(
      android: true,
      bundle: _TextBundle(assets),
      splatsInThisBuild: () async => true,
      disclaimer: () => 'the disclaimer in the language of the app',
    ).toList();
    final text = textOf(entries.first);
    expect(text, contains('-isdk, and -splat in the version for Meta Quest'));
    expect(text, contains('and the Gaussian splats of other tools.\nthe disclaimer in the language of the app\n'));
    expect(text.indexOf('the disclaimer'), lessThan(text.indexOf('Meta Platform Technologies SDK License Agreement')));
  });

  test('the build of the Meta Horizon Store does not list the splat module as active', () async {
    final entries = await metaSpatialLicenses(
      android: true,
      bundle: _TextBundle(assets),
      splatsInThisBuild: () async => false,
      disclaimer: () => 'the disclaimer in the language of the app',
    ).toList();
    final text = textOf(entries.first);
    expect(text, isNot(contains('the disclaimer')), reason: 'no splats in this build');
    expect(text, contains('Meta Spatial SDK 0.14.0 (meta-spatial-sdk, -toolkit, -vr and -isdk)'));
    expect(text, contains('which this build never starts'));
    expect(text, isNot(contains('Gaussian splats of other tools')));
    expect(text, contains('Meta Platform Technologies SDK License Agreement'), reason: 'the licence of the package');
  });

  test('a build whose answer fails is read as the store build', () async {
    final entries = await metaSpatialLicenses(
      android: true,
      bundle: _TextBundle(assets),
      splatsInThisBuild: () async => throw StateError('no answer'),
    ).toList();
    expect(textOf(entries.first), contains('which this build never starts'));
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
