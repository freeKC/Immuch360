import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The folder of the libsmb2 texts among the assets of the vendored dart_smb2 (mobile/packages/dart_smb2/libsmb2)
const libsmb2LicenseAssets = 'packages/dart_smb2/libsmb2';

/// The libsmb2 entry when its texts cannot be read (a build without the assets of dart_smb2): the licence, and where the
/// notice and the corresponding source are, rather than a licence page that fails as a whole
const libsmb2FallbackLicense =
    'libsmb2 (https://github.com/sahlberg/libsmb2), the library Immuch360 uses to open SMB shares, is under the GNU '
    'Lesser General Public License, version 2.1 or (at your option) any later version '
    '(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).\n'
    '\n'
    'Source: its notice could not be read from this build. The notice is mobile/packages/dart_smb2/libsmb2/NOTICE in '
    'https://github.com/freeKC/Immuch360, and the releases on https://github.com/freeKC/Immuch360/releases carry the '
    'corresponding source of libsmb2, the file Immuch360-libsmb2-sources.tar.gz.';

/// libsmb2 (LGPL-2.1-or-later) is the native library dart_smb2 loads for the SMB shares, in every build. Flutter's
/// licence page lists the LICENSE file of each Dart package, and dart_smb2's covers its own BSD code only, so the
/// notice of libsmb2 (copyright, the build carried, its changes, where its source is) and the text of the LGPL are
/// added here, from the assets the package declares for them. [bundle] is the app's own unless a test gives another.
Stream<LicenseEntry> libsmb2Licenses([AssetBundle? bundle]) async* {
  final assets = bundle ?? rootBundle;
  LicenseEntry entry;
  try {
    entry = libsmb2LicenseEntry(
      await assets.loadString('$libsmb2LicenseAssets/NOTICE'),
      await assets.loadString('$libsmb2LicenseAssets/LICENCE-LGPL-2.1.txt'),
    );
  } catch (error) {
    // One entry lost to a missing asset must not take the whole licence page with it
    dPrint(() => 'libsmb2 licence texts: $error');
    entry = const LicenseEntryWithLineBreaks(['libsmb2'], libsmb2FallbackLicense);
  }
  yield entry;
}

/// The entry of the licence page from the two texts. A checkout on Windows gives them CRLF line ends, and the parser
/// of [LicenseEntryWithLineBreaks] would keep each carriage return inside the paragraph it joins, so they go first.
LicenseEntry libsmb2LicenseEntry(String notice, String lgpl) =>
    LicenseEntryWithLineBreaks(const ['libsmb2'], '$notice\n$lgpl'.replaceAll('\r\n', '\n'));
