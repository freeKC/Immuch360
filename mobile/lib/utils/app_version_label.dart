// The app version shown to the user. Immuch360 Desktop has a label of its own, the one `immuch360 --version`
// prints and its files are named after (3.4.2-desktop.27 for desktop build 27), while the build number it is compiled
// with is the fork build of the phones (47). The label comes from .github/desktop/desktop_version.py, the single
// source of the desktop numbers: immuch360-desktop.yml passes it to flutter build as
// --dart-define=IMMUCH360_DESKTOP_LABEL. A build made without it (a local one) shows the shared version line.

import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The label of desktop_version.py: 3.4.2-desktop.27 on a desktop pre-release tag, 3.4.2-47 on a release tag,
/// 3.4.2-47-`commit` otherwise; empty when the build was not given one
const kDesktopLabel = String.fromEnvironment('IMMUCH360_DESKTOP_LABEL');

/// The version line of the About box: "3.4.2 build.47" on the phones, the TV and the Quest; on a computer the desktop
/// [label], followed by the shared build when the label does not name it ("3.4.2-desktop.27 (build 47)")
String appVersionLine({
  required String version,
  required String buildNumber,
  required bool desktop,
  String label = kDesktopLabel,
}) {
  if (!desktop || label.isEmpty) {
    return '$version build.$buildNumber';
  }
  if (buildNumber.isEmpty || !label.contains('-desktop.')) {
    return label;
  }
  return '$label (build $buildNumber)';
}

/// The short version (login page, licences page): the desktop [label] on a computer, else [version]
String appVersionName({required String version, required bool desktop, String label = kDesktopLabel}) =>
    desktop && label.isNotEmpty ? label : version;

/// [appVersionLine] for this build
String appVersionLineOf(PackageInfo info) =>
    appVersionLine(version: info.version, buildNumber: info.buildNumber, desktop: CurrentPlatform.isDesktop);

/// [appVersionName] for this build
String appVersionNameOf(PackageInfo info) => appVersionName(version: info.version, desktop: CurrentPlatform.isDesktop);
