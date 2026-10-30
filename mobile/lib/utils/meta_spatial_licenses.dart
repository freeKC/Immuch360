import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licence of the Meta Spatial SDK 0.14.0, the Meta Platform Technologies SDK License Agreement, as each of its
/// AARs carries it (licenses/meta-spatial-sdk/README.md)
const metaSpatialLicenseAsset = 'assets/licenses/meta-spatial-sdk/LICENSE';

/// The notices of the third party software in the native libraries of the SDK, the notices.html of its AARs as text
/// (.github/desktop/meta_spatial_notices.py)
const metaSpatialNoticeAsset = 'assets/licenses/meta-spatial-sdk/NOTICES.txt';

/// What the licence page says before the text of the licence
const metaSpatialLicenseHeader =
    'Meta Spatial SDK 0.14.0 (meta-spatial-sdk, -toolkit, -vr, -isdk, and -splat in the version for Meta Quest), '
    'Copyright Meta Platform Technologies, LLC and its affiliates: the immersive viewer of the Meta Quest, and the '
    'Gaussian splats of other tools.\n'
    '\n'
    'After this licence come the notices of the third party software of its native libraries, as its packages carry '
    'them.';

/// The entries of the licence page for the Meta Spatial SDK: its licence, then its notices, under "Meta Spatial SDK".
/// Every Android APK ships the SDK (the immersive viewer is in both flavours, the splat module in the quest one only);
/// the other platforms list nothing.
Stream<LicenseEntry> metaSpatialLicenses({bool? android, AssetBundle? bundle}) async* {
  if (!(android ?? defaultTargetPlatform == TargetPlatform.android)) {
    return;
  }
  final assets = bundle ?? rootBundle;
  try {
    final text = await assets.loadString(metaSpatialLicenseAsset);
    yield LicenseEntryWithLineBreaks(const ['Meta Spatial SDK'], '$metaSpatialLicenseHeader\n\n$text');
  } catch (error) {
    dPrint(() => 'Meta Spatial SDK licence text: $error');
  }
  try {
    final notice = await assets.loadString(metaSpatialNoticeAsset, cache: false);
    yield LicenseEntryWithLineBreaks(const ['Meta Spatial SDK'], notice);
  } catch (error) {
    dPrint(() => 'Meta Spatial SDK notices: $error');
  }
}
