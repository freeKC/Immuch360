import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/utils/app_update_link.dart';

/// The certificate of the Horizon Store build, STORE_CERTIFICATE_SHA256 of SplatBuild.kt in upper case, as
/// package_info_plus writes the signature.
const _storeCertificate = 'ECC6B085C727F003CD71AE45927BE08800A7FD84B61A5A5634B3D3D70B4ADB9B';

/// [hex] with a colon between each pair of digits, as keytool writes a digest.
String _withColons(String hex) => [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)].join(':');

void main() {
  String appLink(TargetPlatform platform, {String? flavor, String? signature}) => appUpdateLinkOf(
    status: VersionStatus.clientOutOfDate,
    platform: platform,
    flavor: flavor,
    signature: signature,
  );

  test('a server out of date opens the Immich server releases on every platform and build', () {
    for (final (platform, flavor, signature) in <(TargetPlatform, String?, String?)>[
      (TargetPlatform.iOS, null, null),
      (TargetPlatform.android, 'phone', null),
      (TargetPlatform.android, kQuestFlavor, _storeCertificate),
      (TargetPlatform.android, kQuestFlavor, kGithubReleaseCertificateSha256),
      (TargetPlatform.windows, null, null),
      (TargetPlatform.linux, null, null),
      (TargetPlatform.macOS, null, null),
    ]) {
      expect(
        appUpdateLinkOf(
          status: VersionStatus.serverOutOfDate,
          platform: platform,
          flavor: flavor,
          signature: signature,
        ),
        kImmichServerLatestRelease,
        reason: '$platform $flavor $signature',
      );
    }
  });

  test('an app out of date on iOS opens the App Store', () {
    expect(appLink(TargetPlatform.iOS), kImmichAppStoreLink);
  });

  test('an app out of date on an Android phone, tablet or TV opens Google Play', () {
    expect(appLink(TargetPlatform.android, flavor: 'phone'), kImmichPlayStoreLink);
    expect(appLink(TargetPlatform.android), kImmichPlayStoreLink);
    final githubPhone = appLink(TargetPlatform.android, flavor: 'phone', signature: kGithubReleaseCertificateSha256);
    expect(githubPhone, kImmichPlayStoreLink);
  });

  test('the store build of the Quest, or a quest build of unknown certificate, opens the Horizon Store page', () {
    expect(appLink(TargetPlatform.android, flavor: kQuestFlavor, signature: _storeCertificate), kHorizonStoreLink);
    expect(appLink(TargetPlatform.android, flavor: kQuestFlavor), kHorizonStoreLink);
    expect(appLink(TargetPlatform.android, flavor: kQuestFlavor, signature: ''), kHorizonStoreLink);
  });

  test('the quest APK of GitHub opens the GitHub Latest release, whatever the case and colons of the digest', () {
    for (final signature in [
      kGithubReleaseCertificateSha256.toUpperCase(),
      kGithubReleaseCertificateSha256,
      _withColons(kGithubReleaseCertificateSha256.toUpperCase()),
    ]) {
      expect(appLink(TargetPlatform.android, flavor: kQuestFlavor, signature: signature), kImmichLatestRelease);
    }
  });

  test('the computers, and any other platform, open the download page of the website', () {
    const others = [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.fuchsia];
    for (final platform in others) {
      expect(appLink(platform), kWebsiteDownloadLink, reason: '$platform');
    }
    expect(kWebsiteDownloadLink, 'https://immuch360.com/download/');
    expect(kHorizonStoreLink, 'https://www.meta.com/experiences/immuch360/1384208401440714/');
  });

  test('the GitHub certificate is the one the splat gate of the Kotlin side knows', () {
    // GITHUB_CERTIFICATE_SHA256 of SplatBuild.kt, read from its source: both sides must name the same certificate
    final kotlin = File(
      'android/app/src/main/kotlin/app/alextran/immich/immersive/splat/SplatBuild.kt',
    ).readAsStringSync();

    expect(
      RegExp(r'const val GITHUB_CERTIFICATE_SHA256 = "([0-9a-f]{64})"').firstMatch(kotlin)?.group(1),
      kGithubReleaseCertificateSha256,
    );
    expect(
      RegExp(r'const val STORE_CERTIFICATE_SHA256 = "([0-9a-f]{64})"').firstMatch(kotlin)?.group(1),
      _storeCertificate.toLowerCase(),
    );
  });

  test('kQuestFlavor is the quest flavour of the Android build', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final flavors = gradle.substring(gradle.indexOf('productFlavors {'));

    expect(RegExp('^\\s+$kQuestFlavor \\{\$', multiLine: true).hasMatch(flavors), isTrue);
  });

  test('the README names the Horizon Store page and the download page of the website', () {
    final readme = File('../README.md').readAsStringSync();

    expect(readme, contains(kHorizonStoreLink));
    expect(readme, contains(kWebsiteDownloadLink));
  });
}
