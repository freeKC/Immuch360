import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/debug_print.dart';

/// The licence of LiteRT 2.3.0 as its packages carry it (the Apache License 2.0, with the BSD terms of the parts that
/// come from Caffe), an asset of the quest flavour only (pubspec.yaml)
const liteRtLicenseAsset = 'assets/licenses/litert/LICENSE';

/// The notices of the libraries LiteRT 2.3.0 is built from, THIRD_PARTY_NOTICE.txt as its packages carry it (the same
/// file in litert, litert-api and litert-gpu): XNNPACK, pthreadpool, cpuinfo, FP16 and FXdiv compiled into its native
/// libraries, and the rest of Google's build. Their BSD and MIT terms ask for the notices to travel with the binaries,
/// so the quest flavour ships the file as an asset next to the licence
const liteRtNoticeAsset = 'assets/licenses/litert/THIRD_PARTY_NOTICE.txt';

/// What the licence page says before the text of the licence: what LiteRT does in the app, and what follows it
const liteRtLicenseHeader =
    'LiteRT 2.3.0 (litert, litert-api and litert-gpu, with the ML Drift GPU engine and XNNPACK), Copyright 2025-2026 '
    'Google LLC: the engine of the depth model of the AI relief on Meta Quest.\n'
    '\n'
    'After this licence come the notices of the libraries LiteRT is built from, as its packages carry them '
    '(THIRD_PARTY_NOTICE.txt), one entry for each library the file names, in its order.';

/// The longest line read as the name of a library in the notices ("vulkan_utility_libraries:" is 25 characters)
const _liteRtNoticeNameMaxLength = 60;

/// [notice] cut before the name of each library it lists: a line of its own, not indented, without a comma, that
/// ends with a colon, after two blank lines and before a blank one ("XNNPACK:"). Every line stays, in its order, so
/// joining the sections with a line break gives the text back; a name the file writes after a single blank line stays
/// inside the section before it, where the page shows it too
List<String> liteRtNoticeSections(String notice) {
  final lines = notice.replaceAll('\r\n', '\n').split('\n');
  final sections = <String>[];
  var start = 0;
  for (var i = 2; i + 1 < lines.length; i++) {
    if (lines[i - 2].isEmpty && lines[i - 1].isEmpty && lines[i + 1].isEmpty && _isLibraryName(lines[i])) {
      sections.add(lines.sublist(start, i).join('\n'));
      start = i;
    }
  }
  sections.add(lines.sublist(start).join('\n'));
  return sections;
}

bool _isLibraryName(String line) =>
    line.length > 1 &&
    line.length <= _liteRtNoticeNameMaxLength &&
    line.endsWith(':') &&
    line.trimLeft() == line &&
    !line.contains(',');

/// The entries of the licence page for LiteRT: its licence, then the notices of its libraries one entry each, all
/// under "LiteRT". Only the APK of the quest flavour ships it (android/app/build.gradle, questImplementation), so the
/// other builds list nothing. The notices are 1.9 MB: cut by library, each entry is parsed on its own when the page of
/// LiteRT opens, and the asset is not kept in the cache of the bundle
Stream<LicenseEntry> liteRtLicenses({String? flavor = appFlavor, AssetBundle? bundle}) async* {
  if (flavor != 'quest') {
    return;
  }
  final assets = bundle ?? rootBundle;
  try {
    final text = await assets.loadString(liteRtLicenseAsset);
    yield LicenseEntryWithLineBreaks(const ['LiteRT'], '$liteRtLicenseHeader\n\n$text');
  } catch (error) {
    dPrint(() => 'LiteRT licence text: $error');
  }
  final String notice;
  try {
    notice = await assets.loadString(liteRtNoticeAsset, cache: false);
  } catch (error) {
    dPrint(() => 'LiteRT notices: $error');
    return;
  }
  for (final section in liteRtNoticeSections(notice)) {
    final text = section.trimRight();
    if (text.trim().isNotEmpty) {
      yield LicenseEntryWithLineBreaks(const ['LiteRT'], text);
    }
  }
}
