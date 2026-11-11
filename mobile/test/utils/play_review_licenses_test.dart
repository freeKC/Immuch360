import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/play_review_licenses.dart';

void main() {
  String textOf(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).join('\n');

  test('the phone flavour lists Play In-App Review with the terms it is used under', () async {
    final entries = await playReviewLicenses(flavor: 'phone').toList();
    expect(entries, hasLength(1));
    expect(entries.single.packages, ['Google Play In-App Review']);
    final text = textOf(entries.single);
    expect(text, contains('com.google.android.play:review'));
    expect(text, contains('Play Core Software Development Kit Terms of Service'));
    expect(text, contains('https://developer.android.com/guide/playcore'));
    expect(text, contains('Google APIs Terms of Service'));
  });

  test('the version named is the one the phone flavour links', () {
    final catalogue = File('android/gradle/libs.versions.toml').readAsStringSync();
    final version = RegExp(r'^play-review = "([^"]+)"', multiLine: true).firstMatch(catalogue)?.group(1);
    expect(version, isNotNull);
    expect(playReviewLicenseText, contains('In-App Review $version (com.google.android.play:review)'));
    final gradle = File('android/app/build.gradle').readAsStringSync();
    expect(gradle, contains('phoneImplementation libs.play.review'));
    expect(gradle, isNot(contains('questImplementation libs.play.review')));
  });

  test('the other builds ship no Play In-App Review and list nothing', () async {
    expect(await playReviewLicenses(flavor: 'quest').toList(), isEmpty);
    expect(await playReviewLicenses(flavor: null).toList(), isEmpty);
    // flutter test builds without a flavour, like iOS and the computers
    expect(appFlavor, isNull);
    expect(await playReviewLicenses().toList(), isEmpty);
  });

  test('main.dart registers it and keeps its CRLF line ends', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('LicenseRegistry.addLicense(playReviewLicenses);\r\n'));
    expect(main, contains("import 'package:immich_mobile/utils/play_review_licenses.dart';\r\n"));
  });
}
