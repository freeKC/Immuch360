// The store a build of Immuch360 came from, the one that can take a rating of it (the invitation to rate the app,
// lib/domain/models/rate_app.dart). Pure, so that every platform, flavour, installer and signature is tested.
//
// On iOS the receipt tells (package_info_plus reads it): "com.apple" is the App Store, TestFlight and the simulator are
// not. On Android the phone flavour is installed from Google Play when the Play Store initiated the install (the
// installer, not the certificate, which Play App Signing replaces); any other installer (a browser, a file manager,
// adb) is the APK of the GitHub releases. On a Meta Quest there is no Google Play: the phone flavour asks nothing
// there. The quest flavour is the GitHub quest APK signed again with the store key (app_update_link.dart), so only its
// certificate tells the Horizon Store build from the GitHub one. Only the fork's own package asks: a build under
// another id (an upstream build, a debug build with its suffix) resolves to none.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/utils/app_update_link.dart';

/// The package of every Immuch360 build on Android, and the bundle id of the App Store app
const kImmuch360PackageName = 'com.aprogsys.immuch360';

/// The SHA-256 of the certificate of the Meta Horizon Store builds, in lower case hexadecimal. It is
/// STORE_CERTIFICATE_SHA256 of SplatBuild.kt, and a test keeps the two equal.
const kHorizonStoreCertificateSha256 = 'ecc6b085c727f003cd71ae45927be08800a7fd84b61a5a5634b3d3d70b4adb9b';

/// The id of the app on the Meta Horizon Store, the end of [kHorizonStoreLink]
const kHorizonStoreAppId = '1384208401440714';

/// The installer of the apps of Google Play (InstallSourceInfo.initiatingPackageName)
const kGooglePlayInstaller = 'com.android.vending';

/// The installer package_info_plus reports for an app of the App Store
const kAppStoreInstaller = 'com.apple';

/// The store of this build: [platform], the build [flavor], the package (or bundle id) [packageName], the SHA-256 of
/// the signing certificate [signature] (PackageInfo.buildSignature, Android), the [installerStore] package_info_plus
/// reads, and whether the device runs Horizon OS [isHorizonOs]
RateAppChannel storeChannelOf({
  required TargetPlatform platform,
  required String? flavor,
  required String packageName,
  String? signature,
  String? installerStore,
  bool isHorizonOs = false,
}) {
  if (packageName != kImmuch360PackageName) {
    return RateAppChannel.none;
  }
  switch (platform) {
    case TargetPlatform.iOS:
      return installerStore == kAppStoreInstaller ? RateAppChannel.appStore : RateAppChannel.none;
    case TargetPlatform.android when flavor == kQuestFlavor:
      final certificate = signature?.replaceAll(':', '').toLowerCase();
      if (certificate == kHorizonStoreCertificateSha256) {
        return RateAppChannel.horizonStore;
      }
      return certificate == kGithubReleaseCertificateSha256 ? RateAppChannel.github : RateAppChannel.none;
    case TargetPlatform.android:
      if (isHorizonOs) {
        return RateAppChannel.none;
      }
      return installerStore == kGooglePlayInstaller ? RateAppChannel.googlePlay : RateAppChannel.github;
    default:
      return RateAppChannel.none;
  }
}
