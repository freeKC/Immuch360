import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The folder of the libsmb2 texts among the assets of the vendored dart_smb2 (mobile/packages/dart_smb2/libsmb2)
const libsmb2LicenseAssets = 'packages/dart_smb2/libsmb2';

/// libsmb2 (LGPL-2.1-or-later) is the native library dart_smb2 loads for the SMB shares, in every build. Flutter's
/// licence page lists the LICENSE file of each Dart package, and dart_smb2's covers its own BSD code only, so the
/// notice of libsmb2 (copyright, the build carried, its changes, where its source is) and the text of the LGPL are
/// added here, from the assets the package declares for them.
Stream<LicenseEntry> libsmb2Licenses() async* {
  final notice = await rootBundle.loadString('$libsmb2LicenseAssets/NOTICE');
  final lgpl = await rootBundle.loadString('$libsmb2LicenseAssets/LICENCE-LGPL-2.1.txt');
  yield LicenseEntryWithLineBreaks(const ['libsmb2'], '$notice\n$lgpl');
}
