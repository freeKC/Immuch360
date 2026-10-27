// The 3D versions of a photo of a network share, found among the files of its folder (design-final 2026-10-26,
// sections 3.8 and 4.2): what "View the 3D version" opens on the Meta Quest, the 3D photo a computer saved next to the
// original on a NAS (route 9.1 of the specification). A share gives no SHA-1 of its files, so the rule of
// derived_file_rule.dart goes by the folder, the name, and the SourceName and SourceSize of the XMP of the version.
// Only the neighbours whose name starts like a version are read, five at most, the head of each (128 KiB): a folder
// without such a name costs no read at all. Shared code: the Quest reads it, the computers have their own index.

import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('ShareVersions');

/// How much of the head of a neighbour is read for its XMP: the window of the GPano tags, which the computers write
/// within
const shareVersionHeadLength = 128 * 1024;

/// A 3D version of a photo of a share: its file, and what its head says (the eyes, our XMP)
typedef ShareVersion = ({NetworkEntry entry, FlatStereoPhoto photo});

/// The folder of the share path [path], "/" for a file at the root
String shareFolderOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}

/// The 3D versions of [original] among [neighbours], the files of its folder (others are left out), the newest
/// first. [readerOf] reads a neighbour; a neighbour that cannot be read is skipped. Empty when the size of the
/// original is unknown: the rule needs it. Never throws.
Future<List<ShareVersion>> findShareVersions(
  NetworkEntry original,
  Iterable<NetworkEntry> neighbours, {
  required ByteRangeReader Function(NetworkEntry entry) readerOf,
}) async {
  final size = original.size;
  if (size == null || original.isDirectory) {
    return const [];
  }
  final folder = shareFolderOf(original.path);
  final files = {
    for (final entry in neighbours)
      if (!entry.isDirectory && entry.sourceId == original.sourceId && shareFolderOf(entry.path) == folder)
        entry.name: entry,
  };
  final names = derivedNameCandidates(original.name, files.keys);
  if (names.isEmpty) {
    return const [];
  }
  final rule = DerivedRuleOriginal(name: original.name, size: size, folder: folder);
  final versions = <ShareVersion>[];
  for (final name in names) {
    final entry = files[name]!;
    try {
      final head = await readerOf(entry)(0, shareVersionHeadLength);
      final xmp = holdsImmuch360Xmp(head) ? StereoPhotoXmp.findIn(head) : null;
      if (!isDerivedFrom(DerivedRuleCandidate(name: name, folder: folder, xmp: xmp), rule)) {
        _log.fine('$name is no version of ${original.name}');
        continue;
      }
      final photo = probeStereoPhotoHead(head, name: name, width: entry.width, height: entry.height);
      if (photo != null) {
        versions.add((entry: entry, photo: photo));
      }
    } catch (error) {
      _log.info('Could not read $name for the versions of ${original.name}: $error');
    }
  }
  versions.sort((a, b) {
    final aDate = a.entry.modified;
    final bDate = b.entry.modified;
    if (aDate == null || bDate == null) {
      return aDate == null ? (bDate == null ? 0 : 1) : -1;
    }
    return bDate.compareTo(aDate);
  });
  if (versions.isNotEmpty) {
    _log.info('${original.name} has ${versions.length} 3D versions: ${versions.map((v) => v.entry.name).join(', ')}');
  }
  return versions;
}
