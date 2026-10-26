// The 3D versions an original already has, so that a batch can skip a photo whose version with the same settings is
// there (design-final 2026-10-26, section 2.6.1), or replace that version on purpose. The library index is asked
// first: it knows the versions of the scanned folders by the sum of their original, wherever they were moved (lot A6a
// fills it). Then the neighbours of the destination folder whose name starts like a version are read, five at most and
// 128 KiB each: that covers an external drive or a NAS not scanned again yet. A file only counts once its own XMP
// links it to the original (derived_file_rule.dart), so close names and stale rows of the index never mislead it.

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

/// The head of a file read to find its XMP, as the readers of GPano do
const versionHeadBytes = 128 * 1024;

/// What two versions of one original are compared on, as [StereoPhotoXmp.settingsKey] gives it for a file: the model
/// file, the pipeline, the parallax, the convergence and the quarter turns
String versionSettingsKey({
  required String depthModelSha256,
  double parallax = ReliefV1.parallax,
  double convergence = ReliefV1.convergence,
  int quarterTurns = 0,
}) => StereoPhotoXmp(
  depthModelSha256: depthModelSha256,
  pipeline: ReliefV1.pipeline,
  parallax: parallax,
  convergence: convergence,
  sourceQuarterTurns: quarterTurns & 3,
).settingsKey!;

/// The files of the library whose XMP names an original, by the sum of that original (the source_sha1 column of the
/// index, lot A6a)
abstract interface class DerivedVersionIndex {
  Future<List<String>> versionPathsOf(String sourceSha1);
}

/// A version found, with the XMP read from its file
class ExistingVersion {
  const ExistingVersion({required this.path, required this.xmp});

  final String path;
  final StereoPhotoXmp xmp;

  String? get settingsKey => xmp.settingsKey;
}

/// The first [versionHeadBytes] of the file at [path], null when it cannot be read
Future<Uint8List?> readFileHead(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    return await file.read(versionHeadBytes);
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}

/// The names of the files of [folder], empty when it cannot be listed
Future<List<String>> listFileNames(String folder) async {
  try {
    return [
      await for (final entry in Directory(folder).list(followLinks: false))
        if (entry is File) p.basename(entry.path),
    ];
  } on FileSystemException {
    return const [];
  }
}

class ExistingVersionFinder {
  ExistingVersionFinder({
    this.index,
    Future<Uint8List?> Function(String path)? readHead,
    Future<List<String>> Function(String folder)? listFolder,
  }) : _readHead = readHead ?? readFileHead,
       _listFolder = listFolder ?? listFileNames;

  /// Null where there is no library (the files of a share alone)
  final DerivedVersionIndex? index;
  final Future<Uint8List?> Function(String path) _readHead;
  final Future<List<String>> Function(String folder) _listFolder;

  /// The versions of [original]: those the index knows first, then those among the neighbours in [folder] (the
  /// destination of the job). With [onlyInFolder], those the index knows elsewhere are left out without being read.
  /// Each file is read once, when it is reached.
  Stream<ExistingVersion> versionsOf(DerivedRuleOriginal original, {String? folder, bool onlyInFolder = false}) async* {
    final seen = <String>{};
    final sum = original.sha1;
    final known = index;
    final inFolder = folder == null ? null : p.canonicalize(folder);
    if (known != null && sum != null && sum.isNotEmpty) {
      for (final path in await known.versionPathsOf(sum)) {
        if (onlyInFolder && p.canonicalize(p.dirname(path)) != inFolder) {
          continue;
        }
        if (seen.add(p.canonicalize(path))) {
          final found = await _versionAt(path, p.dirname(path), original);
          if (found != null) {
            yield found;
          }
        }
      }
    }
    if (folder == null) {
      return;
    }
    final names = [...await _listFolder(folder)]..sort();
    for (final name in derivedNameCandidates(original.name, names)) {
      final path = p.join(folder, name);
      if (seen.add(p.canonicalize(path))) {
        final found = await _versionAt(path, folder, original);
        if (found != null) {
          yield found;
        }
      }
    }
  }

  /// The first version of [original] made with [settingsKey] (see [versionSettingsKey]), null when there is none; see
  /// [versionsOf] for [folder] and [onlyInFolder]
  Future<ExistingVersion?> withSettings(
    DerivedRuleOriginal original,
    String settingsKey, {
    String? folder,
    bool onlyInFolder = false,
  }) async {
    await for (final version in versionsOf(original, folder: folder, onlyInFolder: onlyInFolder)) {
      if (version.settingsKey == settingsKey) {
        return version;
      }
    }
    return null;
  }

  Future<ExistingVersion?> _versionAt(String path, String folder, DerivedRuleOriginal original) async {
    final head = await _readHead(path);
    if (head == null) {
      return null;
    }
    final xmp = StereoPhotoXmp.findIn(head);
    final candidate = DerivedRuleCandidate(name: p.basename(path), folder: folder, xmp: xmp);
    return xmp != null && isDerivedFrom(candidate, original) ? ExistingVersion(path: path, xmp: xmp) : null;
  }
}
