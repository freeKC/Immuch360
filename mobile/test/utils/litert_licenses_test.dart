import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
  // The LiteRT licence and notices of the repository, the texts of its packages (a checkout on Windows may end their
  // lines with \r\n)
  final licence = File('assets/licenses/litert/LICENSE').readAsStringSync().replaceAll('\r\n', '\n');
  final notice = File(liteRtNoticeAsset).readAsStringSync().replaceAll('\r\n', '\n');
  final assets = {liteRtLicenseAsset: licence, liteRtNoticeAsset: notice};

  String textOf(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).join('\n');

  test('the quest flavour lists LiteRT with its licence, then the notices of its libraries', () async {
    final entries = await liteRtLicenses(flavor: 'quest', bundle: _TextBundle(assets)).toList();
    // The licence, then the 135 libraries the notices name
    expect(entries, hasLength(1 + 135));
    expect(entries.map((entry) => entry.packages), everyElement(['LiteRT']));
    final text = textOf(entries.first);
    expect(text, contains('LiteRT 2.3.0'));
    expect(text, contains('THIRD_PARTY_NOTICE.txt'));
    expect(text, contains('Apache License'));
    expect(text, contains('Version 2.0, January 2004'));
    // The BSD terms of the parts from Caffe travel with it
    expect(text, contains('The Regents of the University of California'));
    // XNNPACK, compiled into libLiteRt.so, with its BSD notice, as one entry of the page
    final xnnpack = entries.singleWhere((entry) => entry.paragraphs.first.text == 'XNNPACK:');
    expect(textOf(xnnpack), contains('Redistribution and use in source and binary forms'));
    expect(textOf(xnnpack), contains('Copyright 2019 Google LLC'));
  });

  test('the notices are those of the LiteRT 2.3.0 packages', () {
    // THIRD_PARTY_NOTICE.txt of litert, litert-api and litert-gpu 2.3.0, the same file in the three. Twenty of its
    // lines end with \r\n (the DirectX headers), which a checkout on Windows may give to the others too
    if (!Platform.isWindows) {
      final bytes = File(liteRtNoticeAsset).readAsBytesSync();
      expect(bytes, hasLength(1960672));
      expect(sha256.convert(bytes).toString(), 'db6e1ff4b16c11eb01c45f135928527a50a05282739054686793ec70f442f119');
    }
    // The same text with every line ended by \n, as the page reads it
    final normalised = sha256.convert(utf8.encode(notice)).toString();
    expect(normalised, '43f00bb1acf6f0b19c5c44e361fc26fccd77ceac273ba6a6d6956b3a1e3df6d2');
  });

  test('the notices cut by library keep every line in its order', () {
    final sections = liteRtNoticeSections(notice);
    expect(sections.join('\n'), notice);
    // The blank lines before the first name, then one section for each name
    expect(sections.first.trim(), isEmpty);
    expect(sections, hasLength(1 + 135));
    final names = sections.skip(1).map((section) => section.split('\n').first).toList();
    expect(names.first, 'Abseil:');
    expect(names.last, 'zlib:');
    // The libraries of the native code that XNNPACK brings, with their BSD and MIT terms
    for (final name in ['XNNPACK:', 'pthreadpool:', 'cpuinfo:', 'FP16:', 'FXdiv:', 'ruy:', 'FlatBuffers:']) {
      expect(names, contains(name));
    }
    String section(String name) => sections.singleWhere((section) => section.startsWith('$name\n'));
    expect(section('FP16:'), contains('The MIT License (MIT)'));
    expect(section('FXdiv:'), contains('The MIT License (MIT)'));
    expect(section('pthreadpool:'), contains('Redistribution and use in source and binary forms'));
    // Eigen comes under the Mozilla Public License 2.0
    expect(section('Eigen 3:'), contains('Mozilla Public License Version 2.0'));
    // No section is larger than a twelfth of the file
    expect(sections.map((section) => section.length).reduce((a, b) => a > b ? a : b), lessThan(notice.length ~/ 12));
  });

  test('a name is a line of its own after two blank lines, not a line of the text', () {
    const sample =
        '\n\nFirst:\n\nterms one\n'
        '\n\n  Indented:\n\n'
        '\n\nRedistribution and use, with or without:\n\n'
        'Only one blank line before:\n\n'
        'terms two\n\n\nSecond:\n\nterms three\n';
    final sections = liteRtNoticeSections(sample);
    expect(sections.join('\n'), sample);
    expect(sections.map((section) => section.split('\n').first).toList(), ['', 'First:', 'Second:']);
    expect(sections[1], contains('Only one blank line before:'));
    // Lines that end with \r\n read the same
    expect(liteRtNoticeSections(sample.replaceAll('\n', '\r\n')), sections);
  });

  test('the other builds ship no LiteRT and list nothing', () async {
    final bundle = _TextBundle(assets);
    expect(await liteRtLicenses(flavor: 'phone', bundle: bundle).toList(), isEmpty);
    expect(await liteRtLicenses(flavor: null, bundle: bundle).toList(), isEmpty);
    // flutter test builds without a flavour, like the computers
    expect(appFlavor, isNull);
    expect(await liteRtLicenses(bundle: bundle).toList(), isEmpty);
  });

  test('a quest build without the assets lists nothing rather than failing', () async {
    expect(await liteRtLicenses(flavor: 'quest', bundle: _TextBundle({})).toList(), isEmpty);
  });

  test('a quest build without the notices still lists the licence', () async {
    final entries = await liteRtLicenses(flavor: 'quest', bundle: _TextBundle({liteRtLicenseAsset: licence})).toList();
    expect(entries, hasLength(1));
    expect(textOf(entries.single), contains('Apache License'));
  });

  test('the licence asset is the one of the LiteRT 2.3.0 packages', () {
    expect(licence.length, 13575);
    expect(licence, startsWith('                                 Apache License\n'));
  });
}
