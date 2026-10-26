// The licence texts of the Rust crates built into the JPEG codec of the AI features (mobile/packages/immuch_sbs_codec)
// on the licence page of Immuch360 Desktop, on the three systems. Flutter's page lists the Dart packages only. The
// texts come from the library itself, which carries them; jpeg-encoder is "(MIT OR Apache-2.0) AND IJG", and the IJG
// terms ask that a program shipped as executable code says it is based in part on the work of the Independent JPEG
// Group, which the first paragraph does, in the fallback too.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immuch_sbs_codec/immuch_sbs_codec.dart' as native;

/// The names the entry is listed under
const sbsCodecLicensePackages = ['jpeg-encoder', 'zune-jpeg', 'zune-core'];

/// The entry when the library cannot give its texts: what it is built from, the IJG sentence, and where the texts are
const sbsCodecFallbackLicense =
    'The JPEG codec of the AI features of Immuch360 Desktop (immuch_sbs_codec), written in Rust: it decodes the '
    'original photos and writes the side by side 3D photos. This software is based in part on the work of the '
    'Independent JPEG Group.\n'
    '\n'
    'It is built from jpeg-encoder 0.7.1 ((MIT OR Apache-2.0) AND IJG), zune-jpeg 0.5.15 and zune-core 0.5.3 (MIT OR '
    'Apache-2.0 OR Zlib), each used under its MIT licence, and the Rust standard library (MIT OR Apache-2.0). Their '
    'licence texts could not be read from this build; they are in mobile/packages/immuch_sbs_codec/licenses of '
    'https://github.com/freeKC/Immuch360.';

/// Adds the entry of the codec to the licence page
void registerSbsCodecLicenses() => LicenseRegistry.addLicense(sbsCodecLicenseEntries);

/// The entry, from [texts] (the library's own by default), or [sbsCodecFallbackLicense] when it gives none
Stream<LicenseEntry> sbsCodecLicenseEntries([String? Function() texts = native.nativeCodecLicenses]) async* {
  String? text;
  try {
    text = texts();
  } catch (error) {
    // One entry lost must not take the whole licence page with it
    dPrint(() => 'codec licence texts: $error');
  }
  yield LicenseEntryWithLineBreaks(sbsCodecLicensePackages, text ?? sbsCodecFallbackLicense);
}
