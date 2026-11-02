// The AV2 decoder on the licence page of Immuch360 Desktop (store/m2/av2-2026-11-02/plan-2026-11-02.md, sections 2.6
// and 3), on the three systems: dav2d (BSD 2-Clause) with x86inc.asm (ISC), the Alliance for Open Media Patent License
// 1.0 the AV2 implementations come with, immuch360-av2 (AGPL 3.0, the licence of the app) and, on Linux, immuch360-run
// (MIT). Once the decoder is installed the texts come from the licenses/ folder of its archive (engines/<id>/licenses in
// the folder of the components): the texts the jobs of the CI compared with the sources, with the AGPL of
// immuch360-av2 and the commit it was built from. Before that, from the texts the app keeps
// (av2_decoder_licences.dart), since the decoder is offered at the first AV2 video. Nothing under the GPL.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/av2_decoder_licences.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:path/path.dart' as p;

/// The names the entries of the decoder are listed under on the licence page
abstract final class Av2LicensePackages {
  static const dav2d = 'dav2d (AV2 decoder)';
  static const patents = 'Alliance for Open Media Patent License 1.0';
  static const companion = 'immuch360-av2';
  static const launcher = 'immuch360-run';
}

/// Adds the entries of the AV2 decoder to the licence page; [componentsFolder] is the folder of the components of this
/// computer (desktopAiComponentsFolder), read when the page opens
void registerAv2Licenses(Future<Directory> Function() componentsFolder) =>
    LicenseRegistry.addLicense(() => av2LicenseEntries(componentsFolder, platform: aiPlatformOf(Abi.current())));

/// The entries for the decoder of [platform], from the licenses/ folder of the decoder installed in [componentsFolder],
/// else from the texts the app keeps; none where there is no decoder. A folder that cannot be read gives the texts the
/// app keeps, rather than a licence page that fails.
Stream<LicenseEntry> av2LicenseEntries(
  Future<Directory> Function() componentsFolder, {
  required AiPlatform? platform,
}) async* {
  final component = av2DecoderComponentFor(platform);
  if (component == null) {
    return;
  }
  Directory? licenses;
  try {
    final folder = Directory(
      p.joinAll([(await componentsFolder()).path, ...component.installPath.split('/'), 'licenses']),
    );
    if (folder.existsSync()) {
      licenses = folder;
    }
  } catch (error) {
    dPrint(() => 'AV2 decoder licence folder: $error');
  }

  String text(String name, String kept) {
    final folder = licenses;
    if (folder == null) {
      return kept;
    }
    final file = File(p.join(folder.path, name));
    try {
      return file.existsSync() ? file.readAsStringSync().replaceAll('\r\n', '\n') : kept;
    } on FileSystemException catch (error) {
      dPrint(() => 'AV2 decoder licence text $name: $error');
      return kept;
    }
  }

  const intro =
      'dav2d, the AV2 decoder of VideoLAN (https://code.videolan.org/videolan/dav2d, commit $av2Dav2dCommit), built '
      'into immuch360-av2, the AV2 decoder of Immuch360 Desktop.';
  final where = licenses == null
      ? 'The texts below are those Immuch360 keeps until the decoder is downloaded, the first time an AV2 video plays.'
      : 'The texts below are those of the decoder installed on this computer, in ${licenses.path}.';
  yield LicenseEntryWithLineBreaks(
    const [Av2LicensePackages.dav2d],
    [
      '$intro $where',
      'COPYING (BSD-2-Clause):',
      text('dav2d-COPYING.txt', dav2dCopying),
      'x86inc.asm of the x264 project, part of dav2d (ISC):',
      text('x86inc-ISC.txt', x86incIsc),
    ].join('\n\n'),
  );
  yield LicenseEntryWithLineBreaks(
    const [Av2LicensePackages.patents],
    [
      'The patent licence the AV2 implementations come with, doc/PATENTS of dav2d, reproduced as dav2d ships it.',
      text('AOM-PATENTS.txt', aomPatentLicence),
    ].join('\n\n'),
  );
  yield LicenseEntryWithLineBreaks(
    const [Av2LicensePackages.companion],
    [
      av2CompanionNotice,
      if (licenses != null) ...[text('immuch360-av2-SOURCE.txt', ''), text('immuch360-av2-AGPL-3.0.txt', '')],
    ].where((paragraph) => paragraph.trim().isNotEmpty).join('\n\n'),
  );
  if (component.platforms.contains(AiPlatform.linuxX64)) {
    yield LicenseEntryWithLineBreaks(const [
      Av2LicensePackages.launcher,
    ], text('immuch360-run-MIT.txt', immuch360RunMit));
  }
}
