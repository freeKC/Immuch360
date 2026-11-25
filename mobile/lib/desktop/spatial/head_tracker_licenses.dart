// The face detector of the head tracking of Spatial 2.5D on the licence page of Immuch360 Desktop: libfacedetection
// (3-clause BSD), built into the detector libraries of packages/immuch_head_tracker on Windows and Linux and into its
// framework on macOS. Flutter's licence page lists the Dart packages only; the notice comes from the package itself, so
// a build run from its build folder (without the licenses folder of the ZIP) shows it too. The provenance of the
// network's weights and FreeKC's decision of 25 November 2026 are in licenses/libfacedetection/README.md.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

/// Adds the libfacedetection entry to the licence page, on the computers (the systems the tracker is built for)
void registerHeadTrackerLicenses() {
  if (!CurrentPlatform.isDesktop) {
    return;
  }
  LicenseRegistry.addLicense(headTrackerLicenseEntries);
}

/// The entries of the tracker's third party code
Stream<LicenseEntry> headTrackerLicenseEntries() async* {
  yield libfacedetectionLicenseEntry();
}
