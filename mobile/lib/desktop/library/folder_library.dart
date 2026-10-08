// The folder library of Immuch360 Desktop, as the rest of the app sees it: the roots the user chose, a scan on demand,
// and the file behind a local asset id. "On this device" becomes "On this computer": the photos and videos of these
// folders, fed to the same local tables as the gallery of a phone (see FolderLibrarySyncApi).
//
// For the other desktop parts that read files of the library: FolderLibrary.shared() then file(assetId) or
// files(assetIds) give the path, name, size, date and content type of each asset (thumbnails, the computer share,
// uploads). A file kept online only, or on a drive that is not connected, comes back with cloudOnly or !available:
// it must not be read.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_scanner.dart';
import 'package:immich_mobile/desktop/library/volume_id.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The index file in the support folder of the app, which on a computer is per user and never the Documents folder
Future<String> defaultLibraryIndexPath() async =>
    p.join((await getApplicationSupportDirectory()).path, libraryIndexFileName);

/// A photo or a video of the library, for the code that reads files
class LibraryFile {
  const LibraryFile({
    required this.assetId,
    required this.path,
    required this.name,
    required this.kind,
    required this.size,
    required this.modifiedMs,
    required this.createdSeconds,
    required this.mimeType,
    required this.cloudOnly,
    required this.available,
    this.width,
    this.height,
    this.durationMs = 0,
  });

  final String assetId;

  /// Where the file is now, in the separators of this computer
  final String path;
  final String name;
  final LibraryMediaKind kind;
  final int size;
  final int modifiedMs;
  final int createdSeconds;
  final String mimeType;

  /// Kept online only (OneDrive): reading it would download it
  final bool cloudOnly;

  /// False while the drive of its folder is not connected
  final bool available;

  final int? width;
  final int? height;
  final int durationMs;

  /// Whether the app may open the file now
  bool get readable => available && !cloudOnly;
}

/// Why a folder could not be added
class FolderNotAddedException implements Exception {
  const FolderNotAddedException(this.message);

  final String message;

  @override
  String toString() => 'FolderNotAddedException: $message';
}

/// Runs a scan of the index at a path, of every root or only of those due (see runLibraryScan), [cancel] stopping it
typedef LibraryScanRunner = Future<ScanSummary> Function(String indexPath, NativeCancelFlag? cancel, bool everyRoot);

Future<ScanSummary> _scanInIsolate(String indexPath, NativeCancelFlag? cancel, bool everyRoot) =>
    runLibraryScanInIsolate(indexPath, everyRoot: everyRoot, cancel: cancel);

class FolderLibrary {
  FolderLibrary(this.indexPath, {VolumeProbe? probe, LibraryPathRules? rules, LibraryScanRunner? scanner})
    : _givenProbe = probe,
      rules = rules ?? LibraryPathRules.thisComputer(),
      _scanner = scanner ?? _scanInIsolate;

  /// The library of this isolate at its default place, opened once
  static Future<FolderLibrary> shared() => _shared ??= () async {
    try {
      return FolderLibrary(await defaultLibraryIndexPath());
    } catch (_) {
      // Asked again next time rather than failing for the rest of the session
      _shared = null;
      rethrow;
    }
  }();

  static Future<FolderLibrary>? _shared;

  final String indexPath;
  final LibraryPathRules rules;
  final LibraryScanRunner _scanner;
  final VolumeProbe? _givenProbe;
  late final VolumeProbe _volumes = _givenProbe ?? VolumeProbe.thisComputer();
  LibraryIndex? _index;

  LibraryIndex get index => _index ??= LibraryIndex.open(indexPath);

  void close() {
    _index?.close();
    _index = null;
  }

  List<LibraryRoot> roots() => index.roots();

  bool get hasRoots => index.hasRoots;

  /// Adds the folder at [path]. A folder inside a root already there is already in the library: that root comes back.
  /// A folder around roots already there replaces them, and their files keep their ids (see libraryFileId).
  LibraryRoot addRoot(String path) {
    final absolute = rules.context.normalize(rules.context.absolute(path));
    if (!FileSystemEntity.isDirectorySync(absolute)) {
      throw FolderNotAddedException('Not a folder: $absolute');
    }
    final identity = _volumes.identify(absolute);
    if (identity == null) {
      throw FolderNotAddedException('The volume of $absolute cannot be read');
    }
    final id = identity.rootId(caseFold: rules.caseFold);
    final existing = index.roots(withCounts: false);
    for (final root in existing) {
      if (root.id == id || rootContains(root.id, id)) {
        return root;
      }
    }
    for (final root in existing) {
      if (rootContains(id, root.id)) {
        index.removeRoot(root.id);
      }
    }
    final root = LibraryRoot(
      id: id,
      path: absolute,
      volumeKey: identity.volumeKey,
      pathInVolume: identity.pathInVolume,
      isNetwork: identity.isNetwork,
      includeCloudOnly: false,
      available: true,
      addedAt: DateTime.now(),
    );
    index.addRoot(root);
    return root;
  }

  /// Takes the folder [rootId] out of the library; its files stay on the computer
  void removeRoot(String rootId) => index.removeRoot(rootId);

  /// "Download and include": the files of [rootId] kept online only are read at the next scan, which makes the cloud
  /// client download them
  void includeCloudOnly(String rootId, {bool include = true}) => index.setIncludeCloudOnly(rootId, include: include);

  /// Scans the roots in an isolate of its own: every one when [everyRoot] (the user asked), else the network folders
  /// only now and then (networkRescanInterval)
  Future<ScanSummary> scan({bool everyRoot = false, NativeCancelFlag? cancel}) =>
      _scanner(indexPath, cancel, everyRoot);

  /// When the last complete scan ended
  DateTime? get lastScanEnd {
    final ended = index.lastScan.endedMs;
    return ended == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ended);
  }

  /// The file behind the local asset [assetId], null when the library does not have it
  LibraryFile? file(String assetId) {
    final indexed = index.file(assetId);
    if (indexed == null) {
      return null;
    }
    final root = index.root(indexed.rootId);
    return root == null ? null : _toLibraryFile(indexed, root);
  }

  /// The files behind [assetIds] the library has, in no particular order
  List<LibraryFile> files(Iterable<String> assetIds) {
    final roots = {for (final root in index.roots(withCounts: false)) root.id: root};
    return [
      for (final indexed in index.files(assetIds))
        if (roots[indexed.rootId] case final root?) _toLibraryFile(indexed, root),
    ];
  }

  LibraryFile _toLibraryFile(IndexedFile indexed, LibraryRoot root) => LibraryFile(
    assetId: indexed.id,
    path: rules.context.joinAll([root.path, ...indexed.relativePath.split('/')]),
    name: indexed.name,
    kind: indexed.type == LibraryMediaKind.video.assetType ? LibraryMediaKind.video : LibraryMediaKind.image,
    size: indexed.size,
    modifiedMs: indexed.modifiedMs,
    createdSeconds: indexed.createdSeconds,
    mimeType: mimeTypeOfName(indexed.name),
    cloudOnly: indexed.cloudOnly,
    available: root.available,
    width: indexed.width,
    height: indexed.height,
    durationMs: indexed.durationMs,
  );
}
