// The versions an original already has, so that a batch can skip a photo whose version with the same settings is
// there (design-final 2026-10-26, section 2.6.1), or replace that version on purpose. The library index is asked
// first: it knows the versions of the scanned folders by the sum of their original, wherever they were moved (lot A6a
// fills it). Then the neighbours of the destination folder whose name starts like a version are read, eight at most and
// 128 KiB each: that covers an external drive or a NAS not scanned again yet. A file only counts once its own XMP
// links it to the original (derived_file_rule.dart), so close names and stale rows of the index never mislead it.
//
// Every kind has its key of the settings (design-final 2026-10-27, section 8.6), read from the XMP of its file as that
// kind reads it (ImmersiveXmp). A job of one kind looks for the versions of that kind only, and among the neighbours
// for the names with the suffix of that kind only: eight 3D photos of a photo never hide its 3D scene.

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('ExistingVersionFinder');

/// What two 3D photos of one original are compared on, as [StereoPhotoXmp.settingsKey] gives it for a file: the model
/// file, the pipeline, the parallax, the convergence and the quarter turns. The other kinds have theirs, see the
/// settingsKey of SceneXmp, PanoramaXmp and StereoPanoramaXmp.
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

/// A version found, with the XMP read from its file as its kind reads it
class ExistingVersion {
  const ExistingVersion({required this.path, required this.xmp});

  final String path;
  final ImmersiveXmp xmp;

  /// Null for a kind this build does not know
  ImmersiveKind? get kind => xmp.kind;

  String? get settingsKey => xmp.settingsKey;
}

// The characters Windows refuses in a file name, and the control characters (safeFileName of the computers)
final _windowsForbidden = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

// What may follow the suffix of a version: " (2)" when the name was taken, then the extension
final _versionEnd = RegExp(r'^(?: \(\d+\))?(?:\.[^.]*)?$');

/// Whether [candidate] is named as a version of [kind] of [originalName]: the name of the original without its
/// extension (or the form the computers give it when Windows refuses a character), then the suffix of [kind]
/// (derivedNameEnd), then " (n)" and the extension at most. After "_3D_LRF_Full_SBS" anything may follow, as in phase
/// 1 (isDerivedNameCandidate).
bool isVersionNameOf(ImmersiveKind kind, String originalName, String candidate) {
  final stem = fileStem(originalName);
  if (stem.isEmpty || candidate == originalName) {
    return false;
  }
  final end = derivedNameEnd(kind, originalName);
  final suffix = end.substring(0, end.length - sbsFileExtension.length);
  for (final start in {stem, stem.replaceAll(_windowsForbidden, '_')}) {
    if (!candidate.startsWith('$start$suffix')) {
      continue;
    }
    final rest = candidate.substring(start.length + suffix.length);
    if (kind == ImmersiveKind.stereoPhoto || _versionEnd.hasMatch(rest)) {
      return true;
    }
  }
  return false;
}

/// The names of [folderNames] that may be versions of [kind] of [originalName], at most [maxDerivedCandidates], in the
/// order given
List<String> versionNameCandidates(ImmersiveKind kind, String originalName, Iterable<String> folderNames) =>
    folderNames.where((name) => isVersionNameOf(kind, originalName, name)).take(maxDerivedCandidates).toList();

/// The first [versionHeadLength] of the file at [path], null when it cannot be read
Future<Uint8List?> readFileHead(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    return await file.read(versionHeadLength);
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
  /// With [kind], only the versions of that kind, and only the neighbours named with its suffix. Each file is read
  /// once, when it is reached.
  Stream<ExistingVersion> versionsOf(
    DerivedRuleOriginal original, {
    String? folder,
    bool onlyInFolder = false,
    ImmersiveKind? kind,
  }) async* {
    final seen = <String>{};
    final sum = original.sha1;
    final known = index;
    final inFolder = folder == null ? null : p.canonicalize(folder);
    if (known != null && sum != null && sum.isNotEmpty) {
      var paths = const <String>[];
      try {
        paths = await known.versionPathsOf(sum);
      } catch (error, stack) {
        // The index closed or busy: the neighbours still tell
        _log.warning('The library index could not give the versions of ${original.name}', error, stack);
      }
      for (final path in paths) {
        if (onlyInFolder && p.canonicalize(p.dirname(path)) != inFolder) {
          continue;
        }
        if (seen.add(p.canonicalize(path))) {
          final found = await _versionAt(path, p.dirname(path), original);
          if (found != null && (kind == null || found.kind == kind)) {
            yield found;
          }
        }
      }
    }
    if (folder == null) {
      return;
    }
    final names = [...await _listFolder(folder)]..sort();
    final candidates = kind == null
        ? derivedNameCandidates(original.name, names)
        : versionNameCandidates(kind, original.name, names);
    for (final name in candidates) {
      final path = p.join(folder, name);
      if (seen.add(p.canonicalize(path))) {
        final found = await _versionAt(path, folder, original);
        if (found != null && (kind == null || found.kind == kind)) {
          yield found;
        }
      }
    }
  }

  /// The first version of [original] made with [settingsKey] (the settingsKey of the XMP of its kind, see
  /// [versionSettingsKey] for a 3D photo) for which [where] holds when given, null when there is none; see [versionsOf]
  /// for [folder], [onlyInFolder] and [kind]
  Future<ExistingVersion?> withSettings(
    DerivedRuleOriginal original,
    String settingsKey, {
    String? folder,
    bool onlyInFolder = false,
    ImmersiveKind? kind,
    bool Function(ExistingVersion version)? where,
  }) async {
    await for (final version in versionsOf(original, folder: folder, onlyInFolder: onlyInFolder, kind: kind)) {
      if (version.settingsKey == settingsKey && (where == null || where(version))) {
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
    final xmp = ImmersiveXmp.findIn(head);
    if (xmp == null) {
      return null;
    }
    final candidate = DerivedRuleCandidate(name: p.basename(path), folder: folder, xmp: _ruleXmpOf(xmp));
    return isDerivedFrom(candidate, original) ? ExistingVersion(path: path, xmp: xmp) : null;
  }
}

/// The fields of [xmp] the rule of the versions reads (the original: its sum, its name and its size), whatever its
/// kind
StereoPhotoXmp _ruleXmpOf(ImmersiveXmp xmp) => switch (xmp) {
  final StereoPhotoXmp stereo => stereo,
  _ => StereoPhotoXmp(
    kind: xmp.kind,
    sourceName: xmp.sourceName,
    sourceSize: xmp.sourceSize,
    sourceSha1: xmp.sourceSha1,
    derivativeId: xmp.derivativeId,
  ),
};
