// A folder library on temporary folders for the tests: the index in a temporary file, the volumes of a fake probe
// (so a "drive" can come back under another letter), Windows attributes from a map (so a file can be a OneDrive
// placeholder on Linux too), and the scan run in the test's own isolate.

import 'dart:io';

import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_library_sync_api.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_hasher.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/desktop/library/library_scanner.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/desktop/library/volume_id.dart';
import 'package:path/path.dart' as p;

/// Volumes mounted at folders of the test, each with a key
class FakeVolumeProbe extends VolumeProbe {
  final mounts = <String, String>{};

  Iterable<MapEntry<String, String>> get _longestFirst =>
      mounts.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length));

  @override
  VolumeIdentity? identify(String absolutePath) {
    for (final MapEntry(key: mount, value: volumeKey) in _longestFirst) {
      if (p.equals(mount, absolutePath) || p.isWithin(mount, absolutePath)) {
        final inside = p.relative(absolutePath, from: mount);
        return VolumeIdentity(
          volumeKey: volumeKey,
          mountPoint: mount,
          pathInVolume: inside == '.' ? '/' : '/${p.split(inside).join('/')}',
          isNetwork: volumeKey.startsWith('net-'),
        );
      }
    }
    return null;
  }

  @override
  String? locate(String volumeKey, String pathInVolume) {
    for (final MapEntry(key: mount, value: key) in mounts.entries) {
      if (key == volumeKey) {
        final path = p.joinAll([mount, ...pathInVolume.split('/').where((part) => part.isNotEmpty)]);
        if (Directory(path).existsSync()) {
          return path;
        }
      }
    }
    return null;
  }
}

class TestLibrary {
  TestLibrary() : dir = Directory.systemTemp.createTempSync('folder_library_test_') {
    files = Directory(p.join(dir.path, 'files'))..createSync();
  }

  final Directory dir;
  late final Directory files;
  final probe = FakeVolumeProbe();

  /// Windows attributes by path
  final attributes = <String, int>{};

  /// Every file whose metadata a scan read
  final opened = <String>[];

  /// Files whose content a scan cannot read, as when another program holds them
  final failing = <String>{};

  /// Called as a scan reads a file
  void Function(String path)? onRead;

  var rules = LibraryPathRules(context: p.context, caseFold: false);
  var scans = 0;

  String get indexPath => p.join(dir.path, 'desktop_library.sqlite');

  Future<ScanSummary> scan({bool everyRoot = false, DateTime Function()? clock}) {
    scans++;
    return runLibraryScan(
      indexPath,
      everyRoot: everyRoot,
      clock: clock,
      probe: probe,
      lister: IoFolderLister(attributesOf: (path) => attributes[path]),
      rules: rules,
      readMetadata: (path, kind) {
        opened.add(path);
        onRead?.call(path);
        return failing.contains(path) ? MediaMetadata.failedRead : readMediaMetadataSync(path, kind);
      },
    );
  }

  // Connections to close before the files go: Windows does not delete an open file
  final _toClose = <void Function()>[];

  FolderLibrary library() {
    final library = FolderLibrary(
      indexPath,
      probe: probe,
      rules: rules,
      scanner: (_, _, everyRoot) => scan(everyRoot: everyRoot),
    );
    _toClose.add(library.close);
    return library;
  }

  /// The ids of this library, built with the key of its index
  late final LibraryIds ids = index().ids;

  /// A connection of its own to the index
  LibraryIndex index() {
    final index = LibraryIndex.open(indexPath);
    _toClose.add(index.close);
    return index;
  }

  /// The sync API on this library: scans in this isolate, hashes in this isolate with the system's SHA-1
  FolderLibrarySyncApi syncApi({bool freshScan = true}) {
    final api = _syncApi(freshScan: freshScan);
    _toClose.add(api.close);
    return api;
  }

  FolderLibrarySyncApi _syncApi({required bool freshScan}) => FolderLibrarySyncApi(
    indexPath: () async => indexPath,
    rules: rules,
    freshScan: (_, cancel) async {
      if (freshScan) {
        await scanIfStale(
          indexPath,
          probe: probe,
          lister: IoFolderLister(attributesOf: (path) => attributes[path]),
          rules: rules,
          isCancelled: () => cancel.isCancelled,
        );
      }
    },
    hasher: (jobs, {required network, required cancel}) async => [
      for (final job in jobs)
        hashOneFile(
          job,
          engine: Sha1Engine.system(),
          attributes: (path) => attributes[path],
          isCancelled: () => cancel.isCancelled,
        ),
    ],
  );

  /// Writes [bytes] at [relative] under [base] (the files folder by default), dated [modified]
  File write(String relative, List<int> bytes, {Directory? base, DateTime? modified}) {
    final file = File(p.joinAll([(base ?? files).path, ...relative.split('/')]))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    if (modified != null) {
      file.setLastModifiedSync(modified);
    }
    return file;
  }

  void dispose() {
    for (final close in _toClose.reversed) {
      close();
    }
    _toClose.clear();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }
}
