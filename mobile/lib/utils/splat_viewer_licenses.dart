import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licences of the splat viewer of the computers, phones and tablets (licenses/splat-viewer/README.md of the
/// repository): its page draws with Spark 2.4.0, built by the fork's CI from its tag, on three.js 0.180.0; Spark
/// bundles fflate, and its WebAssembly is made of the Rust crates listed with their texts in THIRD_PARTY_NOTICES.txt.
/// Every build ships the page (assets/splat_viewer/), so every build lists them.
const splatViewerLicenseFolder = 'assets/licenses/splat-viewer';
const sparkLicenseAsset = '$splatViewerLicenseFolder/LICENSE-spark';
const threeLicenseAsset = '$splatViewerLicenseFolder/LICENSE-three';
const fflateLicenseAsset = '$splatViewerLicenseFolder/LICENSE-fflate';
const sparkCratesNoticeAsset = '$splatViewerLicenseFolder/THIRD_PARTY_NOTICES.txt';

/// What the licence page says before the texts: what each one does in the app
const _what =
    'It shows the Gaussian splat scenes (.spz, .ply) on computers, phones and tablets, in the splat viewer '
    'of the app.';

/// The entries of the licence page for the splat viewer: Spark, three.js, fflate and the crates of Spark's
/// WebAssembly; an entry whose text is not in the bundle is left out rather than failing the page
Stream<LicenseEntry> splatViewerLicenses({AssetBundle? bundle}) async* {
  final assets = bundle ?? rootBundle;
  final entries = [
    (['Spark'], sparkLicenseAsset, 'Spark 2.4.0, built from its tag with flate2 on miniz_oxide. $_what'),
    (['three.js'], threeLicenseAsset, 'three.js 0.180.0, the 3D library Spark draws with. $_what'),
    (['fflate'], fflateLicenseAsset, 'fflate 0.8.3, bundled into Spark: it inflates the SPZ files.'),
    (
      ['Spark WebAssembly crates'],
      sparkCratesNoticeAsset,
      'The Rust crates compiled into the WebAssembly of Spark: it decodes the splat files.',
    ),
  ];
  for (final (packages, asset, header) in entries) {
    try {
      final text = await assets.loadString(asset, cache: false);
      yield LicenseEntryWithLineBreaks(packages, '$header\n\n${text.replaceAll('\r\n', '\n')}');
    } catch (error) {
      dPrint(() => '$asset: $error');
    }
  }
}
