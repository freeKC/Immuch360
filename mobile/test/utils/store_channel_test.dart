import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/utils/app_update_link.dart';
import 'package:immich_mobile/utils/store_channel.dart';

// The certificates as package_info_plus gives them: upper case hexadecimal
final _store = kHorizonStoreCertificateSha256.toUpperCase();
final _github = kGithubReleaseCertificateSha256.toUpperCase();

RateAppChannel _channel({
  TargetPlatform platform = TargetPlatform.android,
  String? flavor = 'phone',
  String packageName = kImmuch360PackageName,
  String? signature,
  String? installer,
  bool horizon = false,
}) => storeChannelOf(
  platform: platform,
  flavor: flavor,
  packageName: packageName,
  signature: signature,
  installerStore: installer,
  isHorizonOs: horizon,
);

void main() {
  group('iOS', () {
    test('the App Store build asks the App Store', () {
      expect(_channel(platform: TargetPlatform.iOS, flavor: null, installer: 'com.apple'), RateAppChannel.appStore);
    });

    test('TestFlight, the simulator and an unknown receipt ask nothing', () {
      for (final installer in ['com.apple.testflight', 'com.apple.simulator', null]) {
        expect(
          _channel(platform: TargetPlatform.iOS, flavor: null, installer: installer),
          RateAppChannel.none,
          reason: '$installer',
        );
      }
    });
  });

  group('Android, phone flavour', () {
    test('installed by Google Play: Play', () {
      expect(_channel(installer: kGooglePlayInstaller), RateAppChannel.googlePlay);
      expect(_channel(flavor: null, installer: kGooglePlayInstaller), RateAppChannel.googlePlay);
    });

    test('installed otherwise: the GitHub APK', () {
      for (final installer in [
        'com.android.chrome',
        'com.google.android.packageinstaller',
        'com.android.shell',
        null,
      ]) {
        expect(
          _channel(installer: installer, signature: _github),
          RateAppChannel.github,
          reason: '$installer',
        );
      }
    });

    test('on a Meta Quest: nothing, there is no Google Play', () {
      expect(_channel(installer: kGooglePlayInstaller, horizon: true), RateAppChannel.none);
      expect(_channel(installer: 'com.oculus.horizon', horizon: true), RateAppChannel.none);
    });
  });

  group('Android, quest flavour', () {
    test('signed with the store key: the Horizon Store, in any case and with colons', () {
      expect(_channel(flavor: kQuestFlavor, signature: _store), RateAppChannel.horizonStore);
      expect(_channel(flavor: kQuestFlavor, signature: _store.toLowerCase()), RateAppChannel.horizonStore);
      final colons = [for (var i = 0; i < _store.length; i += 2) _store.substring(i, i + 2)].join(':');
      expect(_channel(flavor: kQuestFlavor, signature: colons, horizon: true), RateAppChannel.horizonStore);
    });

    test('signed with the GitHub key: the GitHub APK', () {
      expect(_channel(flavor: kQuestFlavor, signature: _github, horizon: true), RateAppChannel.github);
    });

    test('an unknown or missing signature asks nothing', () {
      for (final signature in ['', 'AB' * 32, null]) {
        expect(
          _channel(flavor: kQuestFlavor, signature: signature),
          RateAppChannel.none,
          reason: '$signature',
        );
      }
    });

    test('the installer does not matter', () {
      expect(
        _channel(flavor: kQuestFlavor, signature: _store, installer: kGooglePlayInstaller),
        RateAppChannel.horizonStore,
      );
    });
  });

  test('another package (an upstream or a debug build) asks nothing', () {
    for (final packageName in ['app.alextran.immich', '$kImmuch360PackageName.debug']) {
      expect(_channel(packageName: packageName, installer: kGooglePlayInstaller), RateAppChannel.none);
      expect(_channel(packageName: packageName, flavor: kQuestFlavor, signature: _store), RateAppChannel.none);
      expect(
        _channel(packageName: packageName, platform: TargetPlatform.iOS, installer: kAppStoreInstaller),
        RateAppChannel.none,
      );
    }
  });

  test('the computers ask nothing', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
      expect(
        _channel(platform: platform, installer: kAppStoreInstaller),
        RateAppChannel.none,
        reason: '$platform',
      );
    }
  });

  test('the store certificate is the one the splat gate of the Kotlin side knows', () {
    final kotlin = File(
      'android/app/src/main/kotlin/app/alextran/immich/immersive/splat/SplatBuild.kt',
    ).readAsStringSync();
    expect(
      RegExp(r'const val STORE_CERTIFICATE_SHA256 = "([0-9a-f]{64})"').firstMatch(kotlin)?.group(1),
      kHorizonStoreCertificateSha256,
    );
  });

  test('the Horizon Store id is the one of the store page and of the Kotlin store link', () {
    expect(kHorizonStoreLink, contains('/$kHorizonStoreAppId/'));
    final kotlin = File(
      'android/app/src/main/kotlin/app/alextran/immich/review/StoreReviewApiImpl.kt',
    ).readAsStringSync();
    expect(RegExp(r'const val APP_ID = "([0-9]+)"').firstMatch(kotlin)?.group(1), kHorizonStoreAppId);
  });

  test('the package is the application id of the Android build and the bundle id of the App Store app', () {
    expect(File('android/app/build.gradle').readAsStringSync(), contains('applicationId "$kImmuch360PackageName"'));
    expect(File('ios/Signing.xcconfig').readAsStringSync(), contains('IMMICH_BUNDLE_ID_PROD = $kImmuch360PackageName'));
  });
}
