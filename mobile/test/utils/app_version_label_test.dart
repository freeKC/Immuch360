// The version line of the About box (issue 16): on a computer the desktop label, as `immuch360 --version` prints it,
// with the shared build after it; the phones, the TV and the Quest keep "3.4.2 build.47".

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/app_version_label.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  group('appVersionLine', () {
    test('phones, TV and Quest: version and build', () {
      expect(appVersionLine(version: '3.4.2', buildNumber: '47', desktop: false), '3.4.2 build.47');
      expect(
        appVersionLine(version: '3.4.2', buildNumber: '3030045', desktop: false, label: '3.4.2-desktop.27'),
        '3.4.2 build.3030045',
        reason: 'a label never shows off a computer',
      );
    });

    test('a desktop pre-release: the label of --version, then the shared build', () {
      expect(
        appVersionLine(version: '3.4.2', buildNumber: '47', desktop: true, label: '3.4.2-desktop.27'),
        '3.4.2-desktop.27 (build 47)',
      );
      expect(
        appVersionLine(version: '3.4.2', buildNumber: '', desktop: true, label: '3.4.2-desktop.27'),
        '3.4.2-desktop.27',
      );
    });

    test('a desktop build of a release tag or of a commit: the label alone, it names the build', () {
      expect(appVersionLine(version: '3.4.2', buildNumber: '47', desktop: true, label: '3.4.2-47'), '3.4.2-47');
      expect(
        appVersionLine(version: '3.4.2', buildNumber: '47', desktop: true, label: '3.4.2-47-3ccdb0b'),
        '3.4.2-47-3ccdb0b',
      );
    });

    test('a desktop build made without a label (a local build): the shared line', () {
      expect(appVersionLine(version: '3.4.2', buildNumber: '47', desktop: true, label: ''), '3.4.2 build.47');
    });
  });

  group('appVersionName', () {
    test('the label on a computer, the version elsewhere or without a label', () {
      expect(appVersionName(version: '3.4.2', desktop: true, label: '3.4.2-desktop.27'), '3.4.2-desktop.27');
      expect(appVersionName(version: '3.4.2', desktop: false, label: '3.4.2-desktop.27'), '3.4.2');
      expect(appVersionName(version: '3.4.2', desktop: true, label: ''), '3.4.2');
    });
  });

  group('for this build', () {
    final info = PackageInfo(
      appName: 'Immuch360',
      packageName: 'app.alextran.immich',
      version: '3.4.2',
      buildNumber: '47',
    );

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('flutter test passes no label: the shared line on every platform', () {
      expect(kDesktopLabel, isEmpty);
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(appVersionLineOf(info), '3.4.2 build.47', reason: '$platform');
        expect(appVersionNameOf(info), '3.4.2', reason: '$platform');
      }
    });
  });
}
