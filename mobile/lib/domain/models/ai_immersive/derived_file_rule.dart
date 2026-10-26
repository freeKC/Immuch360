// When a 3D photo is a version of an original (design-final 2026-10-26, section 4.2). Everything is in the files
// themselves, so any device can make the link again, after a copy or a rename: the XMP of the version carries the
// SHA-1 of its original. Where that sum is not known (a file of a share seen from the Quest, an original not hashed
// yet), the version must sit in the folder of the original, under a name that starts with the name of the original,
// and its XMP must name the original and give its size. Close names ("salon.jpg", "salon2.jpg",
// "salon_3D_LRF_Full_SBS (1).jpg") never mislead the rule. Pure: the callers read the files.

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// At most this many neighbours of an original are read to find its versions by name (128 KiB each)
const maxDerivedCandidates = 5;

/// An original, as the rule sees it
class DerivedRuleOriginal {
  const DerivedRuleOriginal({required this.name, required this.size, this.folder, this.sha1});

  /// The name of the file, "salon.jpg"
  final String name;

  /// Its size in bytes
  final int size;

  /// Its folder, in the form the caller gives every file (a path, or a folder of a share); null when unknown
  final String? folder;

  /// The SHA-1 of its bytes in base64, null when it is not known
  final String? sha1;
}

/// A file that may be a version, with the Immuch360 XMP read from its head (null when it has none). A kind this build
/// does not know is still a version: a later phase may add panoramas or scenes made from the same original.
class DerivedRuleCandidate {
  const DerivedRuleCandidate({required this.name, required this.xmp, this.folder});

  final String name;
  final String? folder;
  final StereoPhotoXmp? xmp;
}

/// Whether [candidate] is a version of [original]. The SHA-1 decides when both are known; otherwise the folder, the
/// name and the SourceName and SourceSize of the XMP must all agree.
bool isDerivedFrom(DerivedRuleCandidate candidate, DerivedRuleOriginal original) {
  final xmp = candidate.xmp;
  if (xmp == null) {
    return false;
  }
  final originalSum = original.sha1;
  final sourceSum = xmp.sourceSha1;
  if (originalSum != null && originalSum.isNotEmpty && sourceSum != null && sourceSum.isNotEmpty) {
    return originalSum == sourceSum;
  }
  final folder = original.folder;
  return folder != null &&
      candidate.folder == folder &&
      isDerivedNameCandidate(original.name, candidate.name) &&
      xmp.sourceName == original.name &&
      xmp.sourceSize == original.size;
}

/// Whether the name [candidate] starts like the name of a version of [originalName]: its name without extension, then
/// "_3D_LRF_Full_SBS". The name the computers give it may have the characters Windows refuses replaced by "_"; that
/// form is accepted too.
bool isDerivedNameCandidate(String originalName, String candidate) {
  final stem = fileStem(originalName);
  if (stem.isEmpty) {
    return false;
  }
  return candidate.startsWith('$stem$sbsFullNameSuffix') ||
      candidate.startsWith('${stem.replaceAll(_windowsForbidden, '_')}$sbsFullNameSuffix');
}

/// The names of [folderNames] that may be versions of [originalName], at most [maxDerivedCandidates], in the order
/// given; the original itself is never one of them
List<String> derivedNameCandidates(String originalName, Iterable<String> folderNames) => folderNames
    .where((name) => name != originalName && isDerivedNameCandidate(originalName, name))
    .take(maxDerivedCandidates)
    .toList();

/// The characters Windows refuses in a file name, and the control characters (safeFileName of the computers)
final _windowsForbidden = RegExp(r'[<>:"/\\|?*\x00-\x1F]');
