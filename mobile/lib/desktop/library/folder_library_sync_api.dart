import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_hasher.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_scanner.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';

/// Brings the index at a path up to date unless a scan just did, [cancel] stopping it
typedef FreshScan = Future<void> Function(String indexPath, NativeCancelFlag cancel);

/// Hashes files, [cancel] stopping the run
typedef FileHasher =
    Future<List<HashOutcome>> Function(List<HashJob> jobs, {required bool network, required NativeCancelFlag cancel});

Future<void> _freshScanInIsolate(String indexPath, NativeCancelFlag cancel) {
  final address = cancel.address;
  return Isolate.run(
    () => scanIfStale(indexPath, isCancelled: NativeCancelFlag.readerOf(address)),
    debugName: 'folder-library-scan',
  );
}

Future<List<HashOutcome>> _hashInIsolates(
  List<HashJob> jobs, {
  required bool network,
  required NativeCancelFlag cancel,
}) => hashFiles(
  jobs,
  workers: hashWorkerCount(jobs.length, network: network),
  cancel: cancel,
);

// The codes the sync services recognise as a cancel rather than a failure (local_sync.service.dart, hash.service.dart)
const _syncCancelledCode = 'SYNC_CANCELLED';
const _hashCancelledCode = 'HASH_CANCELLED';

/// NativeSyncApi on the computers: the folders the user chose stand for the device gallery. Each folder holding
/// media is an album, like a MediaStore bucket, and its photos and videos are the assets, so the sync services, the
/// timeline, the backup and the computer share use the same local tables as on a phone. Hashing goes to the
/// operating system's SHA-1; there is no trash and no cloud id on a computer.
///
/// It runs in the isolate of the sync services (runInIsolateGentle), a new object there, so it opens the index from
/// its file; the scan and the hashing run in isolates of their own. The answers follow the Android implementation
/// (MessagesImpl30.kt): albums sorted by id, dates in seconds, the size as shown with orientation 0, a delta of the
/// generations since the checkpoint, and the same cancel codes.
class FolderLibrarySyncApi implements NativeSyncApi {
  FolderLibrarySyncApi({
    Future<String> Function()? indexPath,
    FreshScan? freshScan,
    FileHasher? hasher,
    LibraryPathRules? rules,
  }) : _indexPathOf = indexPath ?? defaultLibraryIndexPath,
       _freshScan = freshScan ?? _freshScanInIsolate,
       _hasher = hasher ?? _hashInIsolates,
       _pathRules = rules;

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  final Future<String> Function() _indexPathOf;
  final FreshScan _freshScan;
  final FileHasher _hasher;
  final LibraryPathRules? _pathRules;

  FolderLibrary? _library;

  /// The generation the last delta or album list reached, which the next checkpoint commits
  int? _pendingSeq;

  NativeCancelFlag? _syncCancel;
  NativeCancelFlag? _hashCancel;

  Future<FolderLibrary> _open() async => _library ??= FolderLibrary(await _indexPathOf(), rules: _pathRules);

  /// A fresh scan before the sync services read the library, unless one just ended
  Future<FolderLibrary> _openFresh() async {
    final library = await _open();
    final cancel = NativeCancelFlag();
    _syncCancel = cancel;
    try {
      await _freshScan(library.indexPath, cancel);
      if (cancel.isCancelled) {
        throw PlatformException(code: _syncCancelledCode, message: 'Sync cancelled');
      }
    } finally {
      if (identical(_syncCancel, cancel)) {
        _syncCancel = null;
      }
      cancel.free();
    }
    return library;
  }

  /// Closes the connection to the index; the next call opens it again
  void close() {
    _library?.close();
    _library = null;
  }

  @override
  Future<bool> shouldFullSync() async => (await _open()).index.fullSyncNeeded;

  @override
  Future<SyncDelta> getMediaChanges() async {
    final index = (await _openFresh()).index;
    final delta = index.changesSince(index.checkpoint);
    _pendingSeq = delta.seq;
    return SyncDelta(
      hasChanges: delta.updates.isNotEmpty || delta.deletes.isNotEmpty,
      updates: [for (final file in delta.updates) _asset(file)],
      deletes: delta.deletes,
      assetAlbums: {
        for (final file in delta.updates) file.id: [file.albumId],
      },
    );
  }

  @override
  Future<void> checkpointSync() async {
    final index = (await _open()).index;
    index.setCheckpoint(_pendingSeq ?? index.seq);
    _pendingSeq = null;
  }

  @override
  Future<void> clearSyncCheckpoint() async {
    (await _open()).index.clearCheckpoint();
    _pendingSeq = null;
  }

  @override
  Future<List<String>> getAssetIdsForAlbum(String albumId) async => (await _open()).index.fileIdsOfAlbum(albumId);

  @override
  Future<List<PlatformAlbum>> getAlbums() async {
    final library = await _openFresh();
    final index = library.index;
    // A full sync commits what it read here; a delta sync already took its generation from getMediaChanges
    _pendingSeq ??= index.seq;
    final albums = index.albums();
    final rootNames = {for (final root in index.roots(withCounts: false)) root.id: root.displayName};
    final names = albumDisplayNames({
      for (final album in albums)
        album.id: [rootNames[album.rootId] ?? '', ...album.relativeDir.split('/').where((part) => part.isNotEmpty)],
    });
    return [
      for (final album in albums)
        PlatformAlbum(
          id: album.id,
          name: names[album.id] ?? album.id,
          updatedAt: album.updatedSeconds,
          isCloud: false,
          assetCount: album.assetCount,
        ),
    ];
  }

  @override
  Future<int> getAssetsCountSince(String albumId, int timestamp) async =>
      (await _open()).index.countAddedSince(albumId, timestamp);

  @override
  Future<List<PlatformAsset>> getAssetsForAlbum(String albumId, {int? updatedTimeCond}) async => [
    for (final file in (await _open()).index.filesOfAlbum(albumId, changedAfterSeconds: updatedTimeCond)) _asset(file),
  ];

  @override
  Future<List<HashResult>> hashAssets(List<String> assetIds, {bool allowNetworkAccess = false}) async {
    if (assetIds.isEmpty) {
      return const [];
    }
    final library = await _open();
    final roots = {for (final root in library.index.roots(withCounts: false)) root.id: root};
    final files = {for (final file in library.index.files(assetIds)) file.id: file};
    final outcomes = <String, HashResult>{};
    final jobs = <HashJob>[];
    var network = false;
    for (final id in assetIds) {
      final file = files[id];
      final root = file == null ? null : roots[file.rootId];
      if (file == null || root == null) {
        outcomes[id] = HashResult(assetId: id, error: 'Not in the folders of this computer');
      } else if (file.cloudOnly) {
        // Never read without the user's "Download and include"
        outcomes[id] = HashResult(assetId: id, error: 'The file is kept online only: not read');
      } else if (!root.available) {
        outcomes[id] = HashResult(assetId: id, error: 'The drive of this file is not connected');
      } else if (file.currentChecksum case final checksum?) {
        outcomes[id] = HashResult(assetId: id, hash: checksum);
      } else {
        network = network || root.isNetwork;
        jobs.add((
          id: id,
          path: library.rules.context.joinAll([root.path, ...file.relativePath.split('/')]),
          size: file.size,
        ));
      }
    }

    if (jobs.isNotEmpty) {
      final cancel = NativeCancelFlag();
      _hashCancel = cancel;
      try {
        final hashed = await _hasher(jobs, network: network, cancel: cancel);
        if (cancel.isCancelled) {
          throw PlatformException(code: _hashCancelledCode, message: 'Hashing operation was cancelled');
        }
        final toStore = <({String id, String checksum, int size, int modifiedMs})>[];
        for (final outcome in hashed) {
          outcomes[outcome.id] = HashResult(assetId: outcome.id, hash: outcome.hash, error: outcome.error);
          final file = files[outcome.id]!;
          if (outcome.hash case final hash?) {
            toStore.add((id: outcome.id, checksum: hash, size: file.size, modifiedMs: file.modifiedMs));
          }
        }
        library.index.storeChecksums(toStore);
      } on HashRunCancelled {
        throw PlatformException(code: _hashCancelledCode, message: 'Hashing operation was cancelled');
      } finally {
        if (identical(_hashCancel, cancel)) {
          _hashCancel = null;
        }
        cancel.free();
      }
    }
    return [for (final id in assetIds) outcomes[id]!];
  }

  @override
  Future<void> cancelHashing() async => _hashCancel?.cancel();

  @override
  Future<void> cancelSync() async => _syncCancel?.cancel();

  /// No system trash is read on a computer
  @override
  Future<Map<String, List<PlatformAsset>>> getTrashedAssets() async => const {};

  @override
  Future<bool> restoreFromTrashById(String mediaId, int type) async => false;

  /// iCloud ids are an iOS matter
  @override
  Future<List<CloudIdResult>> getCloudIdForAssetIds(List<String> assetIds) async => const [];

  static PlatformAsset _asset(IndexedFile file) => PlatformAsset(
    id: file.id,
    name: file.name,
    type: file.type,
    createdAt: file.createdSeconds,
    updatedAt: file.modifiedSeconds,
    width: file.width,
    height: file.height,
    durationMs: file.durationMs,
    // The size is already the one shown, as Android gives it
    orientation: 0,
    isFavorite: false,
    // The modification date stands for the edit date the iOS comparison reads (LocalSyncService._assetsEqual on a
    // platform other than Android), so an edited file is seen in a full diff too
    adjustmentTime: file.modifiedSeconds,
    // From the EXIF, as iOS gives the location of the photo library; Android leaves it to the server
    latitude: file.latitude,
    longitude: file.longitude,
    playbackStyle:
        PlatformAssetPlaybackStyle.values.elementAtOrNull(file.playbackStyle) ?? PlatformAssetPlaybackStyle.unknown,
  );
}
