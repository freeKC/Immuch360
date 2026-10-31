// What a folder browser shows of a listing, whatever the folder source: an SMB or WebDAV share, a DLNA or Plex media
// server, a folder of this device chosen in the system picker. Its subfolders, then its photos and videos, then the
// files that may be Gaussian splats of other tools (shown on a Meta Quest once their head says so); hidden entries and
// files of other kinds are left out, so that every source looks the same.

import 'package:immich_mobile/domain/models/network_source.dart';

/// Whether [entry] is hidden: ".DS_Store", the "._IMG.JPG" resource forks of a Mac, ".thumbnails", ".nomedia", and the
/// ".pending-..." and ".trashed-..." files Android is still writing or has put in its trash
bool isHiddenFolderEntry(NetworkEntry entry) => entry.name.startsWith('.');

/// The parts of a folder listing a browser shows, each in the order of the listing (folders first, then files, by
/// name, see NetworkFileSystem.list)
class FolderContents {
  const FolderContents({required this.folders, required this.media, required this.splatCandidates});

  factory FolderContents.of(Iterable<NetworkEntry> entries) {
    final shown = entries.where((entry) => !isHiddenFolderEntry(entry)).toList();
    return FolderContents(
      folders: shown.where((entry) => entry.isDirectory).toList(),
      media: shown.where((entry) => entry.isMedia).toList(),
      splatCandidates: shown.where((entry) => entry.isSplatCandidate).toList(),
    );
  }

  /// Every subfolder, with or without media in it
  final List<NetworkEntry> folders;

  /// The photos and videos
  final List<NetworkEntry> media;

  /// The .spz and .ply files, which may be Gaussian splats (see NetworkEntry.isSplatCandidate)
  final List<NetworkEntry> splatCandidates;

  /// Nothing to show: no folder, no photo or video, no splat file
  bool get isEmpty => folders.isEmpty && media.isEmpty && splatCandidates.isEmpty;
}
