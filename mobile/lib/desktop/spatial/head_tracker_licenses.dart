// The face detector of the head tracking of Spatial 2.5D on the licence page of Immuch360 Desktop on Windows:
// libfacedetection (3-clause BSD), built into the detector DLLs of packages/immuch_head_tracker. Flutter's licence page
// lists the Dart packages only; the notice comes from the package itself, so a build run from its build folder (without
// the licenses folder of the ZIP) shows it too.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

/// Adds the libfacedetection entry to the licence page, on Windows (the only system the tracker is built for)
void registerHeadTrackerLicenses() {
  if (!CurrentPlatform.isWindows) {
    return;
  }
  LicenseRegistry.addLicense(headTrackerLicenseEntries);
}

/// The entries of the tracker's third party code
Stream<LicenseEntry> headTrackerLicenseEntries() async* {
  yield libfacedetectionLicenseEntry();
}
