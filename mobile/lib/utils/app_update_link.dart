// The page the "Update" button of the version notice (profile menu) opens. The Immich server releases when the server
// is out of date; when the app is, the store of the device: the App Store on iOS, Google Play on Android phones,
// tablets and TVs, the Horizon Store on a Meta Quest, and the download page of the website on the computers, since the
// GitHub Latest release is the Android one and holds no desktop file.
//
// The store build of the Quest is the GitHub quest APK signed again with the store key, so both have the quest flavour
// and only the signing certificate tells them apart. The APK of GitHub keeps the GitHub Latest release, which holds its
// -quest-release.apk: the Horizon Store likely cannot update an app signed with another key. A certificate the app
// does not know, or none at all, opens the Horizon Store page.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';

/// The SHA-256 of the certificate of the GitHub release builds, in lower case hexadecimal. It is
/// GITHUB_CERTIFICATE_SHA256 of SplatBuild.kt, and a test keeps the two equal.
const kGithubReleaseCertificateSha256 = 'aa7aab33987b1a02d3d2892e60038fb4d8ea8ea6b8aa968a570fcda7558367be';

/// The page the button of the notice [status] opens on [platform], for the build [flavor] signed with the certificate
/// whose SHA-256 is [signature]. The signature is PackageInfo.buildSignature, read in the quest build only, and null
/// when unknown.
String appUpdateLinkOf({
  required VersionStatus status,
  required TargetPlatform platform,
  required String? flavor,
  String? signature,
}) {
  if (status == VersionStatus.serverOutOfDate) {
    return kImmichServerLatestRelease;
  }
  return switch (platform) {
    TargetPlatform.iOS => kImmichAppStoreLink,
    TargetPlatform.android when flavor != kQuestFlavor => kImmichPlayStoreLink,
    TargetPlatform.android => _isGithubReleaseCertificate(signature) ? kImmichLatestRelease : kHorizonStoreLink,
    _ => kWebsiteDownloadLink,
  };
}

/// Whether [signature] is the SHA-256 of the certificate of the GitHub release builds, in any case, with colons or not,
/// as package_info_plus, keytool and apksigner write it.
bool _isGithubReleaseCertificate(String? signature) =>
    signature?.replaceAll(':', '').toLowerCase() == kGithubReleaseCertificateSha256;
