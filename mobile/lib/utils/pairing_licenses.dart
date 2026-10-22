import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licence of the noble libraries (MIT), bundled into the browser page a big screen serves for "Sign in with your
/// phone" (assets/pairing/app.js, built by mobile/tool/pairing_page)
const pairingNobleLicenseAsset = 'assets/pairing/LICENSE-noble.txt';

/// ZXing (Apache-2.0), the QR code scanner of the Android phones
const zxingLicense =
    'ZXing core and ZXing Android Embedded, the QR code scanner of "Connect a TV or computer" on Android.\n'
    '\n'
    'Copyright (C) 2008 ZXing authors, Copyright (C) 2012-2018 ZXing Android Embedded authors.\n'
    '\n'
    'Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance '
    'with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0\n'
    '\n'
    'Unless required by applicable law or agreed to in writing, software distributed under the License is distributed '
    'on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for '
    'the specific language governing permissions and limitations under the License.';

/// The entries of the licence page for "Sign in with your phone"
Stream<LicenseEntry> pairingLicenses([AssetBundle? bundle]) async* {
  try {
    final noble = await (bundle ?? rootBundle).loadString(pairingNobleLicenseAsset);
    yield LicenseEntryWithLineBreaks(const ['@noble/curves', '@noble/ciphers', '@noble/hashes'], noble);
  } catch (error) {
    dPrint(() => 'noble licence text: $error');
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    yield const LicenseEntryWithLineBreaks(['zxing', 'zxing-android-embedded'], zxingLicense);
  }
}
