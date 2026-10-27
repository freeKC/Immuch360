import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licence of LiteRT 2.3.0 as its packages carry it (the Apache License 2.0, with the BSD terms of the parts that
/// come from Caffe), an asset of the quest flavour only (pubspec.yaml)
const liteRtLicenseAsset = 'assets/licenses/litert/LICENSE';

/// What the licence page says before the text: what LiteRT does in the app, and where the notices of the libraries
/// it is built from are (THIRD_PARTY_NOTICE.txt, 1.9 MB, in each of its packages)
const liteRtLicenseHeader =
    'LiteRT 2.3.0 (litert, litert-api and litert-gpu, with the ML Drift GPU engine and XNNPACK), Copyright 2025-2026 '
    'Google LLC: the engine of the depth model of the AI relief on Meta Quest.\n'
    '\n'
    'The notices of the libraries LiteRT is built from are in THIRD_PARTY_NOTICE.txt of its packages: '
    'https://dl.google.com/android/maven2/com/google/ai/edge/litert/litert/2.3.0/litert-2.3.0.aar';

/// The entry of the licence page for LiteRT: only the APK of the quest flavour ships it (android/app/build.gradle,
/// questImplementation), so the other builds list nothing
Stream<LicenseEntry> liteRtLicenses({String? flavor = appFlavor, AssetBundle? bundle}) async* {
  if (flavor != 'quest') {
    return;
  }
  try {
    final text = await (bundle ?? rootBundle).loadString(liteRtLicenseAsset);
    yield LicenseEntryWithLineBreaks(const ['LiteRT'], '$liteRtLicenseHeader\n\n$text');
  } catch (error) {
    dPrint(() => 'LiteRT licence text: $error');
  }
}
