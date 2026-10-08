// The scan of the folder library: walks each root, compares what it finds with the index, reads the metadata of the
// files that are new or changed (size or date), and writes the differences as generations of the index (see
// library_index.dart). Files gone from a folder that was read completely leave the library; a folder that could not be
// read (no permission, a share that dropped) removes nothing below it, and a root whose drive is not connected keeps
// all its files as they were.
//
// The walk lists one folder at a time rather than recursively, so that a folder skipped by name or attribute (hidden
// folders, recycle bins, thumbnail caches) is never entered, an unreadable folder costs only itself, and symbolic links
// and junctions are never followed (no loops). On Windows the listing is FindFirstFileExW through dart:ffi: it gives
// the attributes of each entry with its size and dates, so a OneDrive placeholder is recognised without opening it.
// dart:io cannot do it there, as it lists every reparse point as a link, and OneDrive keeps its files, downloaded or
// not, as reparse points.
//
// A scan runs in its own isolate when the folders page or the watcher asks for it, and in the isolate of the sync
// services when they ask for changes; a lease in the index keeps two scans from running at once.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/desktop/library/volume_id.dart';
import 'package:path/path.dart' as p;

/// One entry of a folder
class ListedEntry {
  const ListedEntry({
    required this.name,
    required this.isDirectory,
    this.isLink = false,
    this.size = 0,
    this.modifiedMs = 0,
    this.createdMs = 0,
    this.attributes = 0,
  });

  final String name;
  final bool isDirectory;

  /// A symbolic link or a junction: never followed
  final bool isLink;
  final int size;
  final int modifiedMs;

  /// When the file was made, 0 when the system does not tell
  final int createdMs;

  /// The Windows attributes, 0 elsewhere
  final int attributes;
}

/// Lists one folder
abstract class FolderLister {
  /// The entries of [directory], without "." and ".."; null when it cannot be read
  List<ListedEntry>? list(String directory);

  /// FindFirstFileExW on Windows, dart:io elsewhere
  static FolderLister forThisComputer() => Platform.isWindows ? WindowsFolderLister() : const IoFolderLister();
}

/// dart:io: Directory.listSync without following links, then a stat per file. [attributesOf] stands for the Windows
/// attributes in tests, to mark placeholders.
class IoFolderLister implements FolderLister {
  const IoFolderLister({this.attributesOf});

  final FileAttributesReader? attributesOf;

  @override
  List<ListedEntry>? list(String directory) {
    final List<FileSystemEntity> entities;
    try {
      entities = Directory(directory).listSync(followLinks: false);
    } on FileSystemException {
      return null;
    }
    final entries = <ListedEntry>[];
    for (final entity in entities) {
      final name = p.basename(entity.path);
      final attributes = attributesOf?.call(entity.path) ?? 0;
      if (entity is Link) {
        entries.add(ListedEntry(name: name, isDirectory: false, isLink: true));
      } else if (entity is Directory) {
        entries.add(ListedEntry(name: name, isDirectory: true, attributes: attributes));
      } else {
        final FileStat stat;
        try {
          stat = entity.statSync();
        } on FileSystemException {
          continue;
        }
        if (stat.type != FileSystemEntityType.file) {
          continue;
        }
        final modified = stat.modified.millisecondsSinceEpoch;
        // "changed" is the creation date on Windows and the last change of the inode elsewhere, never earlier than
        // the content: the earlier of the two stands for when the file was made
        entries.add(
          ListedEntry(
            name: name,
            isDirectory: false,
            size: stat.size,
            modifiedMs: modified,
            createdMs: math.min(modified, stat.changed.millisecondsSinceEpoch),
            attributes: attributes,
          ),
        );
      }
    }
    return entries;
  }
}

typedef _FindFirstFileExNative =
    Pointer<Void> Function(Pointer<Utf16>, Int32, Pointer<Uint8>, Int32, Pointer<Void>, Uint32);
typedef _FindFirstFileEx = Pointer<Void> Function(Pointer<Utf16>, int, Pointer<Uint8>, int, Pointer<Void>, int);
typedef _FindNextFileNative = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _FindNextFile = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _FindCloseNative = Int32 Function(Pointer<Void>);
typedef _FindClose = int Function(Pointer<Void>);

// WIN32_FIND_DATAW: attributes, three FILETIMEs (creation, access, write), the size in two halves, the reparse tag
// (dwReserved0) and dwReserved1, then the name in 260 UTF-16 units and the short name in 14
const _findDataLength = 592;
const _findDataCreated = 4;
const _findDataWritten = 20;
const _findDataSizeHigh = 28;
const _findDataSizeLow = 32;
const _findDataReparseTag = 36;
const _findDataName = 44;

// FINDEX_INFO_LEVELS FindExInfoBasic (no short name) and FIND_FIRST_EX_LARGE_FETCH
const _findExInfoBasic = 1;
const _findFirstExLargeFetch = 2;

// The reparse points that lead elsewhere; the others (OneDrive and other cloud files, deduplicated files) are the
// file itself
const _linkReparseTags = {0xa000000c, 0xa0000003, 0xa000001d};

// 100 ns intervals between 1601-01-01 (FILETIME) and 1970-01-01
const _fileTimeEpochOffset = 116444736000000000;

int _fileTimeMs(ByteData data, int offset) {
  final ticks = data.getUint32(offset + 4, Endian.little) * 0x100000000 + data.getUint32(offset, Endian.little);
  return ticks == 0 ? 0 : (ticks - _fileTimeEpochOffset) ~/ 10000;
}

/// FindFirstFileExW and FindNextFileW of kernel32: one call per entry, with its attributes, size and dates
class WindowsFolderLister implements FolderLister {
  WindowsFolderLister() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _findFirst = kernel32.lookupFunction<_FindFirstFileExNative, _FindFirstFileEx>('FindFirstFileExW');
    _findNext = kernel32.lookupFunction<_FindNextFileNative, _FindNextFile>('FindNextFileW');
    _findClose = kernel32.lookupFunction<_FindCloseNative, _FindClose>('FindClose');
  }

  late final _FindFirstFileEx _findFirst;
  late final _FindNextFile _findNext;
  late final _FindClose _findClose;

  @override
  List<ListedEntry>? list(String directory) => using((arena) {
    final data = arena<Uint8>(_findDataLength);
    final pattern = win32LongPath(p.windows.join(directory, '*'));
    final handle = _findFirst(
      pattern.toNativeUtf16(allocator: arena),
      _findExInfoBasic,
      data,
      0,
      nullptr,
      _findFirstExLargeFetch,
    );
    if (handle.address == -1) {
      return null;
    }
    final entries = <ListedEntry>[];
    try {
      final view = ByteData.sublistView(data.asTypedList(_findDataLength));
      do {
        final name = (data + _findDataName).cast<Utf16>().toDartString();
        if (name == '.' || name == '..') {
          continue;
        }
        final attributes = view.getUint32(0, Endian.little);
        final isLink =
            attributes & fileAttributeReparsePoint != 0 &&
            _linkReparseTags.contains(view.getUint32(_findDataReparseTag, Endian.little));
        entries.add(
          ListedEntry(
            name: name,
            isDirectory: attributes & fileAttributeDirectory != 0,
            isLink: isLink,
            size:
                view.getUint32(_findDataSizeHigh, Endian.little) * 0x100000000 +
                view.getUint32(_findDataSizeLow, Endian.little),
            modifiedMs: _fileTimeMs(view, _findDataWritten),
            createdMs: _fileTimeMs(view, _findDataCreated),
            attributes: attributes,
          ),
        );
      } while (_findNext(handle, data) != 0);
    } finally {
      _findClose(handle);
    }
    return entries;
  });
}

/// What a scan did
class ScanSummary {
  const ScanSummary({
    this.busy = false,
    this.written = 0,
    this.removed = 0,
    this.cloudOnly = 0,
    this.moved = 0,
    this.unavailable = 0,
    this.cancelled = false,
  });

  /// Another scan was running: this one did nothing, the other one brings the index up to date
  final bool busy;

  /// Files new or changed, files gone
  final int written;
  final int removed;

  /// Files left out because they are online only
  final int cloudOnly;

  /// Roots found again elsewhere (a drive under another letter), roots whose drive is not connected
  final int moved;
  final int unavailable;

  final bool cancelled;

  /// Whether the local tables of the app have something to learn
  bool get hasChanges => written > 0 || removed > 0;

  ScanSummary operator +(ScanSummary other) => ScanSummary(
    busy: busy || other.busy,
    written: written + other.written,
    removed: removed + other.removed,
    cloudOnly: cloudOnly + other.cloudOnly,
    moved: moved + other.moved,
    unavailable: unavailable + other.unavailable,
    cancelled: cancelled || other.cancelled,
  );

  @override
  String toString() =>
      'ScanSummary(busy: $busy, written: $written, removed: $removed, cloudOnly: $cloudOnly, moved: $moved, '
      'unavailable: $unavailable, cancelled: $cancelled)';
}

/// Thrown out of a scan asked to stop
class ScanCancelled implements Exception {
  const ScanCancelled();
}

// Files written per generation, and entries between two turns of the event loop
const _batchLength = 200;
const _yieldEvery = 256;

// A scan holds its lease this long without renewing it; renewed at every folder
const _leaseLength = Duration(minutes: 10);

/// How long a network folder goes without a rescan, unless the user asks for one (Refresh). It is not watched, and
/// walking a share costs a round trip per folder, so the rescans that the watcher of a local folder or a sync start
/// pass it by in between.
const networkRescanInterval = Duration(minutes: 15);

var _scanCounter = 0;

/// Reads the metadata of a file; the scanner's is [readMediaMetadataSync], tests count the files it opens
typedef MetadataReader = MediaMetadata Function(String path, LibraryMediaKind kind);

/// Scans the roots of the index at [indexPath]: every local root, and the network roots not scanned for
/// [networkRescanInterval], or all of them when [everyRoot]. Returns a busy summary at once when another scan holds
/// the lease.
Future<ScanSummary> runLibraryScan(
  String indexPath, {
  bool everyRoot = false,
  VolumeProbe? probe,
  FolderLister? lister,
  LibraryPathRules? rules,
  MetadataReader? readMetadata,
  bool Function()? isCancelled,
  DateTime Function()? clock,
}) async {
  final index = LibraryIndex.open(indexPath);
  final owner = '${Isolate.current.hashCode}-$pid-${_scanCounter++}';
  final now = clock ?? DateTime.now;
  try {
    if (!index.tryAcquireScanLease(owner, _leaseLength, now: now())) {
      return const ScanSummary(busy: true);
    }
    final scan = _Scan(
      index: index,
      probe: probe ?? VolumeProbe.thisComputer(),
      lister: lister ?? FolderLister.forThisComputer(),
      rules: rules ?? LibraryPathRules.thisComputer(),
      readMetadata: readMetadata ?? readMediaMetadataSync,
      isCancelled: isCancelled ?? () => false,
      renewLease: () => index.tryAcquireScanLease(owner, _leaseLength, now: now()),
      now: now,
    );
    final rootsVersion = index.rootsVersion;
    var summary = const ScanSummary();
    try {
      for (final root in index.roots(withCounts: false)) {
        if (!everyRoot && _recentNetworkScan(root, now())) {
          continue;
        }
        summary += await scan.scanRoot(root);
      }
    } on ScanCancelled {
      return summary + const ScanSummary(cancelled: true);
    }
    index.recordScanEnd(endedMs: now().millisecondsSinceEpoch, rootsVersion: rootsVersion);
    return summary;
  } finally {
    index
      ..releaseScanLease(owner)
      ..close();
  }
}

// A network root scanned a short while ago. It is not even probed: a share that dropped can take the system's whole
// time out to answer, and its files stay as they were anyway. One already missing is looked for at every scan, as a
// local drive is.
bool _recentNetworkScan(LibraryRoot root, DateTime now) {
  final scanned = root.scannedAt;
  return root.isNetwork && root.available && scanned != null && now.difference(scanned) < networkRescanInterval;
}

/// A scan unless the last one ended less than [maxAge] ago with the same roots; while another scan runs, waits for it
/// instead. Null when the index was fresh.
Future<ScanSummary?> scanIfStale(
  String indexPath, {
  Duration maxAge = const Duration(seconds: 30),
  VolumeProbe? probe,
  FolderLister? lister,
  LibraryPathRules? rules,
  MetadataReader? readMetadata,
  bool Function()? isCancelled,
}) async {
  while (true) {
    if (isCancelled?.call() ?? false) {
      return const ScanSummary(cancelled: true);
    }
    final index = LibraryIndex.open(indexPath);
    final bool fresh;
    try {
      final last = index.lastScan;
      fresh =
          last.rootsVersion == index.rootsVersion &&
          DateTime.now().millisecondsSinceEpoch - last.endedMs < maxAge.inMilliseconds;
    } finally {
      index.close();
    }
    if (fresh) {
      return null;
    }
    final summary = await runLibraryScan(
      indexPath,
      probe: probe,
      lister: lister,
      rules: rules,
      readMetadata: readMetadata,
      isCancelled: isCancelled,
    );
    if (!summary.busy) {
      return summary;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

/// [runLibraryScan] in an isolate of its own, so that the window stays responsive; [cancel] stops it at the next file
Future<ScanSummary> runLibraryScanInIsolate(String indexPath, {bool everyRoot = false, NativeCancelFlag? cancel}) {
  final address = cancel?.address;
  return Isolate.run(
    () => runLibraryScan(
      indexPath,
      everyRoot: everyRoot,
      isCancelled: address == null ? null : NativeCancelFlag.readerOf(address),
    ),
    debugName: 'folder-library-scan',
  );
}

class _Scan {
  _Scan({
    required this.index,
    required this.probe,
    required this.lister,
    required this.rules,
    required this.readMetadata,
    required this.isCancelled,
    required this.renewLease,
    required this.now,
  });

  final LibraryIndex index;
  final VolumeProbe probe;
  final FolderLister lister;
  final LibraryPathRules rules;
  final MetadataReader readMetadata;
  final bool Function() isCancelled;
  final bool Function() renewLease;
  final DateTime Function() now;
  var _sinceYield = 0;

  Future<void> _tick() async {
    if (isCancelled()) {
      throw const ScanCancelled();
    }
    if (++_sinceYield >= _yieldEvery) {
      _sinceYield = 0;
      // Lets the isolate hear a cancel, and a busy machine breathe
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Where [root] is now: its path when the same volume is still there, else wherever the volume came back
  String? _locate(LibraryRoot root) {
    if (FileSystemEntity.isDirectorySync(root.path)) {
      final identity = probe.identify(root.path);
      if (identity != null && identity.rootId(caseFold: rules.caseFold) == root.id) {
        return root.path;
      }
    }
    return probe.locate(root.volumeKey, root.pathInVolume);
  }

  Future<ScanSummary> scanRoot(LibraryRoot root) async {
    final path = _locate(root);
    if (path == null) {
      index.updateRootLocation(root.id, path: root.path, available: false);
      return const ScanSummary(unavailable: 1);
    }
    final moved = path != root.path;
    index.updateRootLocation(root.id, path: path, available: true);

    final known = index.knownFiles(root.id);
    final seen = <String>{};
    final unreadable = <String>[];
    final batch = <IndexedFile>[];
    var written = 0;
    var cloudOnly = 0;
    final addedSeconds = now().millisecondsSinceEpoch ~/ 1000;

    void flush() {
      index.writeFiles(batch);
      written += batch.length;
      batch.clear();
    }

    final folders = <String>[''];
    while (folders.isNotEmpty) {
      final relativeDir = folders.removeLast();
      renewLease();
      final absoluteDir = relativeDir.isEmpty ? path : rules.context.joinAll([path, ...relativeDir.split('/')]);
      final entries = lister.list(absoluteDir);
      if (entries == null) {
        unreadable.add(relativeDir);
        continue;
      }
      for (final entry in entries) {
        await _tick();
        if (entry.isLink) {
          continue;
        }
        final relativePath = relativeDir.isEmpty ? entry.name : '$relativeDir/${entry.name}';
        if (entry.isDirectory) {
          if (!isSkippedFolderName(entry.name) && !isHiddenFolder(entry.attributes)) {
            folders.add(relativePath);
          }
          continue;
        }
        final kind = mediaKindOfName(entry.name);
        if (kind == null || isSkippedFileName(entry.name)) {
          continue;
        }
        final id = libraryFileId(root.id, rules.key(relativePath));
        seen.add(id);
        final isCloudOnly = isCloudPlaceholder(entry.attributes) && !root.includeCloudOnly;
        if (isCloudOnly) {
          cloudOnly++;
        }
        final before = known[id];
        if (before != null &&
            before.size == entry.size &&
            before.modifiedMs == entry.modifiedMs &&
            before.cloudOnly == isCloudOnly &&
            before.relativePath == relativePath) {
          continue;
        }
        // A placeholder is never opened: reading its head would download it
        final metadata = isCloudOnly
            ? MediaMetadata.none
            : readMetadata(rules.context.join(absoluteDir, entry.name), kind);
        batch.add(
          _record(
            root: root,
            id: id,
            relativeDir: relativeDir,
            relativePath: relativePath,
            kind: kind,
            entry: entry,
            metadata: metadata,
            addedSeconds: addedSeconds,
            cloudOnly: isCloudOnly,
          ),
        );
        if (batch.length >= _batchLength) {
          flush();
        }
      }
    }
    flush();

    final gone = [
      for (final MapEntry(key: id, value: file) in known.entries)
        if (!seen.contains(id) && !unreadable.any((dir) => _isUnder(file.relativePath, dir))) id,
    ];
    index
      ..removeFiles(gone)
      ..markRootScanned(root.id, now());
    return ScanSummary(written: written, removed: gone.length, cloudOnly: cloudOnly, moved: moved ? 1 : 0);
  }

  static bool _isUnder(String relativePath, String dir) => dir.isEmpty || relativePath.startsWith('$dir/');

  IndexedFile _record({
    required LibraryRoot root,
    required String id,
    required String relativeDir,
    required String relativePath,
    required LibraryMediaKind kind,
    required ListedEntry entry,
    required MediaMetadata metadata,
    required int addedSeconds,
    required bool cloudOnly,
  }) {
    final fileCreatedMs = entry.createdMs > 0 ? math.min(entry.createdMs, entry.modifiedMs) : entry.modifiedMs;
    final playbackStyle = switch (kind) {
      LibraryMediaKind.video => 2,
      LibraryMediaKind.image when metadata.animated => 3,
      LibraryMediaKind.image => 1,
    };
    return IndexedFile(
      id: id,
      rootId: root.id,
      albumId: libraryAlbumId(root.id, rules.key(relativeDir)),
      relativePath: relativePath,
      type: kind.assetType,
      size: entry.size,
      modifiedMs: entry.modifiedMs,
      addedSeconds: addedSeconds,
      createdSeconds: (metadata.takenAt?.millisecondsSinceEpoch ?? fileCreatedMs) ~/ 1000,
      width: metadata.displayWidth,
      height: metadata.displayHeight,
      durationMs: metadata.durationMs,
      playbackStyle: playbackStyle,
      latitude: metadata.latitude,
      longitude: metadata.longitude,
      projection: metadata.projection,
      cloudOnly: cloudOnly,
    );
  }
}
