import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licence of the Meta Spatial SDK 0.14.0, the Meta Platform Technologies SDK License Agreement, as each of its
/// AARs carries it (licenses/meta-spatial-sdk/README.md)
const metaSpatialLicenseAsset = 'assets/licenses/meta-spatial-sdk/LICENSE';

/// The notices of the third party software in the native libraries of the SDK, the notices.html of its AARs as text
/// (.github/desktop/meta_spatial_notices.py)
const metaSpatialNoticeAsset = 'assets/licenses/meta-spatial-sdk/NOTICES.txt';

/// What the licence page says before the text of the licence. A build that offers the Gaussian splats (the GitHub
/// builds) lists the splat module among what shows them; the build of the Meta Horizon Store, the same APK re-signed,
/// carries the module but never starts it (SplatBuild.kt), and says so.
String metaSpatialLicenseHeader({required bool splats}) {
  final what = splats
      ? 'Meta Spatial SDK 0.14.0 (meta-spatial-sdk, -toolkit, -vr, -isdk, and -splat in the version for Meta Quest), '
            'Copyright Meta Platform Technologies, LLC and its affiliates: the immersive viewer of the Meta Quest, and '
            'the Gaussian splats of other tools.'
      : 'Meta Spatial SDK 0.14.0 (meta-spatial-sdk, -toolkit, -vr and -isdk), Copyright Meta Platform Technologies, '
            'LLC and its affiliates: the immersive viewer of the Meta Quest. The version for Meta Quest also carries '
            'the -splat module of the SDK, under the same licence, which this build never starts.';
  return '$what\n'
      '\n'
      'After this licence come the notices of the third party software of its native libraries, as its packages carry '
      'them.';
}

/// Whether this build offers the Gaussian splats, asked to the platform (see askSplatsInThisBuild)
Future<bool> _askSplatsInThisBuild() => askSplatsInThisBuild(ImmersiveApi(), android: true);

/// The entries of the licence page for the Meta Spatial SDK: its licence, then its notices, under "Meta Spatial SDK".
/// Every Android APK ships the SDK (the immersive viewer is in both flavours, the splat module in the quest one only);
/// the other platforms list nothing. [splatsInThisBuild] says whether the splat module is listed as active (false in
/// the build of the Meta Horizon Store, and when the answer fails).
Stream<LicenseEntry> metaSpatialLicenses({
  bool? android,
  AssetBundle? bundle,
  Future<bool> Function() splatsInThisBuild = _askSplatsInThisBuild,
}) async* {
  if (!(android ?? defaultTargetPlatform == TargetPlatform.android)) {
    return;
  }
  final assets = bundle ?? rootBundle;
  var splats = false;
  try {
    splats = await splatsInThisBuild();
  } catch (error) {
    dPrint(() => 'Meta Spatial SDK licence, Gaussian splats in this build: $error');
  }
  try {
    final text = await assets.loadString(metaSpatialLicenseAsset);
    final header = metaSpatialLicenseHeader(splats: splats);
    yield LicenseEntryWithLineBreaks(const ['Meta Spatial SDK'], '$header\n\n$text');
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
