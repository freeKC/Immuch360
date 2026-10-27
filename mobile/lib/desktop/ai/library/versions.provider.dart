// The 3D versions of a photo of the folder library, and the photo a version was made from, as the details panel of the
// viewer shows them (design-final 2026-10-26, section 4.2). Everything comes from the files themselves: the scan keeps
// what the XMP of a version says (library_index.dart), among which the SHA-1 of its original, so a version moved to
// another folder of the library stays linked, a deleted one leaves the index with the next scan, and one on a drive
// that is not connected is still listed, greyed. Where the sum of the original is not known yet (it is computed for
// the folders chosen for the backup only), the rule of derived_file_rule.dart falls back to the folder, the name and
// the SourceName and SourceSize of the XMP, reading the head of five neighbours at most.

import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhotoVersions');

/// A file of the library as the versions section shows it: its name, its folder, whether it can be opened now, and the
/// asset its thumbnail is read for
class VersionFile {
  const VersionFile({required this.file, this.origin});

  final LibraryFile file;

  /// Where its content comes from, for a version; null for an original
  final IndexedOrigin? origin;

  String get name => file.name;

  String get path => file.path;

  /// Its relief was estimated by AI from one photo: "3D photo, relief estimated by AI"
  bool get isEstimatedRelief => origin == IndexedOrigin.estimated;

  /// False on a drive that is not connected, or kept online only: listed greyed, never opened
  bool get available => file.readable;

  /// The local asset of the file, for its thumbnail: the id the folder library gives it
  LocalAsset get asset => LocalAsset(
    id: file.assetId,
    name: file.name,
    type: file.kind == LibraryMediaKind.video ? AssetType.video : AssetType.image,
    createdAt: DateTime.fromMillisecondsSinceEpoch(file.createdSeconds * 1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(file.modifiedMs),
    width: file.width,
    height: file.height,
    playbackStyle: file.kind == LibraryMediaKind.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
    isEdited: false,
  );
}

/// What the details of a photo of the library tell of its 3D versions
class PhotoVersions {
  const PhotoVersions({this.versions = const [], this.self, this.original});

  /// Nothing to show: no version, and the photo is none
  static const none = PhotoVersions();

  /// The versions of an original, in every folder of the library, those that can be opened first
  final List<VersionFile> versions;

  /// The photo itself when it is a version, null for any other photo
  final VersionFile? self;

  /// The original a version was made from, null when it is not found ("Original not found") or the photo is no version
  final VersionFile? original;

  bool get isVersion => self != null;
}

/// Reads the head of the file at a path for its XMP, null when it cannot be read
typedef VersionHeadReader = Future<Uint8List?> Function(String path);

/// Finds the versions of a photo of [_library], and the original of a version
class PhotoVersionsFinder {
  PhotoVersionsFinder(this._library, {VersionHeadReader? readHead}) : _readHead = readHead ?? readFileHead;

  final FolderLibrary _library;
  final VersionHeadReader _readHead;

  LibraryIndex get _index => _library.index;

  /// What to show for the photo of the library whose asset is [assetId]. [checksum] is the SHA-1 in base64 the local
  /// tables know for it, used when the index has none for the file as it is now.
  Future<PhotoVersions> find(String assetId, {String? checksum}) async {
    final indexed = _index.file(assetId);
    if (indexed == null || indexed.type != LibraryMediaKind.image.assetType) {
      return PhotoVersions.none;
    }
    return indexed.isGenerated ? _ofVersion(indexed) : _ofOriginal(indexed, checksum: checksum);
  }

  Future<PhotoVersions> _ofOriginal(IndexedFile original, {String? checksum}) async {
    final sha1 = original.currentChecksum ?? checksum;
    final List<IndexedFile> found;
    if (sha1 != null && sha1.isNotEmpty) {
      found = _index.filesDerivedFrom(sha1).where((file) => file.id != original.id).toList();
    } else {
      found = await _byName(original);
    }
    if (found.isEmpty) {
      return PhotoVersions.none;
    }
    final origins = {for (final file in found) file.id: file.origin};
    final versions = [
      for (final file in _library.files(found.map((file) => file.id)))
        VersionFile(file: file, origin: origins[file.assetId]),
    ]..sort(_availableFirst);
    return PhotoVersions(versions: versions);
  }

  // The original's sum is not known: the neighbours named like its versions, whose XMP names it and gives its size
  Future<List<IndexedFile>> _byName(IndexedFile original) async {
    final candidates =
        _index
            .generatedFilesOfAlbum(original.albumId)
            .where((file) => isDerivedNameCandidate(original.name, file.name))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final rule = DerivedRuleOriginal(name: original.name, size: original.size, folder: original.albumId);
    final read = candidates.take(maxDerivedCandidates).toList();
    final paths = {
      for (final file in _library.files(read.map((file) => file.id)))
        if (file.readable) file.assetId: file.path,
    };
    final found = <IndexedFile>[];
    for (final candidate in read) {
      final path = paths[candidate.id];
      if (path == null) {
        continue;
      }
      final xmp = await _xmpOf(path);
      if (isDerivedFrom(DerivedRuleCandidate(name: candidate.name, folder: candidate.albumId, xmp: xmp), rule)) {
        found.add(candidate);
      }
    }
    return found;
  }

  Future<PhotoVersions> _ofVersion(IndexedFile version) async {
    final self = _library.file(version.id);
    if (self == null) {
      return PhotoVersions.none;
    }
    final selfFile = VersionFile(file: self, origin: version.origin);
    final original = await _originalOf(version, self);
    return PhotoVersions(
      self: selfFile,
      original: original == null ? null : VersionFile(file: original),
    );
  }

  Future<LibraryFile?> _originalOf(IndexedFile version, LibraryFile self) async {
    final sha1 = version.sourceSha1;
    if (sha1 != null && sha1.isNotEmpty) {
      final matches =
          _index.filesWithChecksum(sha1).where((file) => file.id != version.id && !file.isGenerated).toList()
            // The one beside the version first
            ..sort((a, b) => (a.albumId == version.albumId ? 0 : 1).compareTo(b.albumId == version.albumId ? 0 : 1));
      for (final match in matches) {
        if (_library.file(match.id) case final file?) {
          return file;
        }
      }
    }
    // Not hashed yet, or gone: the photo the XMP names, in the folder of the version, with the size it gives
    final xmp = self.readable ? await _xmpOf(self.path) : null;
    final name = xmp?.sourceName;
    if (xmp == null || name == null || name.isEmpty || name.contains('/') || name.contains(r'\')) {
      return null;
    }
    final relativePath = version.relativeDir.isEmpty ? name : '${version.relativeDir}/$name';
    final candidate = _index.file(_index.ids.file(version.rootId, _library.rules.key(relativePath)));
    if (candidate == null || candidate.isGenerated) {
      return null;
    }
    final linked = isDerivedFrom(
      DerivedRuleCandidate(name: version.name, folder: version.albumId, xmp: xmp),
      DerivedRuleOriginal(
        name: candidate.name,
        size: candidate.size,
        folder: candidate.albumId,
        sha1: candidate.currentChecksum,
      ),
    );
    return linked ? _library.file(candidate.id) : null;
  }

  Future<StereoPhotoXmp?> _xmpOf(String path) async {
    try {
      final head = await _readHead(path);
      return head == null ? null : StereoPhotoXmp.findIn(head);
    } catch (error) {
      // A damaged packet costs only itself
      _log.fine('Could not read the XMP of $path: $error');
      return null;
    }
  }

  static int _availableFirst(VersionFile a, VersionFile b) {
    if (a.available != b.available) {
      return a.available ? -1 : 1;
    }
    return a.path.compareTo(b.path);
  }
}

/// The finder of the app, on the library of the window; replaced in tests
final photoVersionsFinderProvider = FutureProvider<PhotoVersionsFinder>(
  (ref) async => PhotoVersionsFinder(await ref.watch(folderLibraryProvider.future)),
);

/// The versions of [asset], or the original it was made from, when it is a photo of the folder library; nothing for
/// any other asset. Read each time the details open.
final photoVersionsProvider = FutureProvider.autoDispose.family<PhotoVersions, BaseAsset>((ref, asset) async {
  final localId = asset.localId;
  if (localId == null || !asset.isImage) {
    return PhotoVersions.none;
  }
  final finder = await ref.watch(photoVersionsFinderProvider.future);
  try {
    return await finder.find(localId, checksum: asset.checksum);
  } catch (error, stackTrace) {
    _log.warning('Could not read the versions of ${asset.name}', error, stackTrace);
    return PhotoVersions.none;
  }
});
