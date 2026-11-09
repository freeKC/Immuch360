import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licences of zstd-jni 1.5.7-3 (BSD 2-Clause) and of zstd 1.5.7 built into its native library (its BSD licence),
/// an asset of the quest flavour only (pubspec.yaml), see licenses/zstd-jni/README.md of the repository
const zstdLicenseAsset = 'assets/licenses/zstd-jni/LICENSE';

/// What the licence page says before the texts: what zstd-jni does in the app
const zstdLicenseHeader =
    'zstd-jni 1.5.7-3, Copyright (c) 2015-present Luben Karavelov, with zstd 1.5.7, Copyright (c) Meta Platforms, '
    'Inc. and affiliates: it reads the Gaussian splats saved in SPZ version 4 on Meta Quest.';

/// The entry of the licence page for zstd-jni, under "zstd-jni". Only the APK of the quest flavour ships it
/// (android/app/build.gradle, questImplementation), so the other builds list nothing; a build without the asset lists
/// nothing rather than failing the page
Stream<LicenseEntry> zstdLicenses({String? flavor = appFlavor, AssetBundle? bundle}) async* {
  if (flavor != kQuestFlavor) {
    return;
  }
  try {
    final text = await (bundle ?? rootBundle).loadString(zstdLicenseAsset);
    yield LicenseEntryWithLineBreaks(const ['zstd-jni'], '$zstdLicenseHeader\n\n${text.replaceAll('\r\n', '\n')}');
  } catch (error) {
    dPrint(() => 'zstd-jni licence text: $error');
  }
}
