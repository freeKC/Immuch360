// The index of the folder library: a SQLite file of its own, desktop_library.sqlite in the support folder of the app,
// never part of the main Drift schema, so that the database of the phones and its migrations stay exactly as they are.
//
// It keeps the roots the user added, every photo and video found under them with what the scan read of it, and the
// checksums already computed, by size and modification date. Changes are numbered by generation, as MediaStore numbers
// them on Android: every write that changes files takes the next number ("seq"), deleted files leave a tombstone with
// theirs, and the local tables of the app hold everything up to the generation of the last checkpoint. A delta is then
// what lies between the checkpoint and the current generation, read in one transaction, so a scan that writes during a
// sync only adds generations the next delta will carry.
//
// The scanner (its own isolate), the sync API (the isolate of the sync services) and the folders page (the main
// isolate) each open their own connection; WAL lets them read while one writes, and a lease in the meta table keeps
// two scans from running at once.

import 'dart:io';

import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const _schemaVersion = 1;

/// The name of the index file, in the support folder of the app
const libraryIndexFileName = 'desktop_library.sqlite';

/// A photo or a video of the library, as the index keeps it
class IndexedFile {
  const IndexedFile({
    required this.id,
    required this.rootId,
    required this.albumId,
    required this.relativePath,
    required this.type,
    required this.size,
    required this.modifiedMs,
    required this.addedSeconds,
    required this.createdSeconds,
    this.width,
    this.height,
    this.durationMs = 0,
    this.playbackStyle = 0,
    this.latitude,
    this.longitude,
    this.projection,
    this.cloudOnly = false,
    this.checksum,
    this.checksumSize,
    this.checksumModifiedMs,
    this.changeSeq = 0,
  });

  final String id;
  final String rootId;
  final String albumId;

  /// The path under the root, with "/" separators, in the case of the file system
  final String relativePath;

  /// 1 image, 2 video (AssetType)
  final int type;
  final int size;
  final int modifiedMs;

  /// When the index first saw the file: stands for DATE_ADDED of the Android gallery, which the sync services ask
  /// "what was added since" by
  final int addedSeconds;

  /// When it was taken, else when the file was made
  final int createdSeconds;

  /// As shown, the orientation applied
  final int? width;
  final int? height;
  final int durationMs;

  /// PlatformAssetPlaybackStyle index
  final int playbackStyle;
  final double? latitude;
  final double? longitude;

  /// GPano projection type of a photo
  final String? projection;

  /// Kept online only by a cloud client: counted, never read, never published
  final bool cloudOnly;

  /// SHA-1 in base64, valid while the file keeps [checksumSize] and [checksumModifiedMs]
  final String? checksum;
  final int? checksumSize;
  final int? checksumModifiedMs;

  final int changeSeq;

  String get name => relativePath.substring(relativePath.lastIndexOf('/') + 1);

  /// The folder of the file under its root, "" for the root itself
  String get relativeDir {
    final slash = relativePath.lastIndexOf('/');
    return slash < 0 ? '' : relativePath.substring(0, slash);
  }

  int get modifiedSeconds => modifiedMs ~/ 1000;

  /// The checksum, when it was computed on the file as it is now
  String? get currentChecksum => checksumSize == size && checksumModifiedMs == modifiedMs ? checksum : null;
}

/// An album of the library: a folder that holds at least one photo or video the library shows
class IndexedAlbum {
  const IndexedAlbum({
    required this.id,
    required this.rootId,
    required this.relativeDir,
    required this.assetCount,
    required this.updatedSeconds,
  });

  final String id;
  final String rootId;
  final String relativeDir;
  final int assetCount;

  /// The latest of the modification and addition dates of its files, as the Android gallery dates a bucket
  final int updatedSeconds;
}

/// The size, date and state a scan compares a file with
typedef KnownFile = ({String relativePath, int size, int modifiedMs, bool cloudOnly});

/// What a delta carries: the published files changed since the checkpoint, the ids gone, and the generation it reaches
typedef IndexDelta = ({List<IndexedFile> updates, List<String> deletes, int seq});

class LibraryIndex {
  LibraryIndex._(this._db, this.path) {
    _migrate();
  }

  /// Opens (or creates) the index at [path]
  factory LibraryIndex.open(String path) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final db = sqlite3.open(path);
    db
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('PRAGMA synchronous = NORMAL')
      ..execute('PRAGMA busy_timeout = 10000');
    return LibraryIndex._(db, path);
  }

  final Database _db;

  /// Where the index file is, for the isolates that open their own connection
  final String path;

  void close() => _db.close();

  void _migrate() {
    final version = _db.select('PRAGMA user_version').first.values.first! as int;
    if (version >= _schemaVersion) {
      return;
    }
    _write(() {
      _db
        ..execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value)')
        ..execute('''
          CREATE TABLE IF NOT EXISTS roots (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            volume_key TEXT NOT NULL,
            path_in_volume TEXT NOT NULL,
            network INTEGER NOT NULL DEFAULT 0,
            include_cloud_only INTEGER NOT NULL DEFAULT 0,
            available INTEGER NOT NULL DEFAULT 1,
            added_ms INTEGER NOT NULL,
            scanned_ms INTEGER
          )''')
        ..execute('''
          CREATE TABLE IF NOT EXISTS files (
            id TEXT PRIMARY KEY,
            root_id TEXT NOT NULL,
            album_id TEXT NOT NULL,
            rel_path TEXT NOT NULL,
            type INTEGER NOT NULL,
            size INTEGER NOT NULL,
            modified_ms INTEGER NOT NULL,
            added_s INTEGER NOT NULL,
            created_s INTEGER NOT NULL,
            width INTEGER,
            height INTEGER,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            playback_style INTEGER NOT NULL DEFAULT 0,
            latitude REAL,
            longitude REAL,
            projection TEXT,
            cloud_only INTEGER NOT NULL DEFAULT 0,
            checksum TEXT,
            checksum_size INTEGER,
            checksum_modified_ms INTEGER,
            change_seq INTEGER NOT NULL
          )''')
        ..execute('CREATE INDEX IF NOT EXISTS files_by_album ON files (album_id)')
        ..execute('CREATE INDEX IF NOT EXISTS files_by_root ON files (root_id)')
        ..execute('CREATE INDEX IF NOT EXISTS files_by_change ON files (change_seq)')
        ..execute('CREATE TABLE IF NOT EXISTS tombstones (id TEXT PRIMARY KEY, change_seq INTEGER NOT NULL)')
        ..execute('PRAGMA user_version = $_schemaVersion');
    });
  }

  /// Runs [action] in a write transaction, taken at once so that two writers queue instead of failing on upgrade
  T _write<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  T _read<T>(T Function() action) {
    _db.execute('BEGIN');
    try {
      return action();
    } finally {
      _db.execute('COMMIT');
    }
  }

  // --- meta ---

  Object? _meta(String key) => _db.select('SELECT value FROM meta WHERE key = ?', [key]).firstOrNull?['value'];

  int _metaInt(String key) => (_meta(key) as int?) ?? 0;

  void _setMeta(String key, Object? value) => _db.execute(
    'INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  /// Takes the next generation, inside a write transaction
  int _nextSeq() {
    final seq = _metaInt('seq') + 1;
    _setMeta('seq', seq);
    return seq;
  }

  /// The last generation written
  int get seq => _metaInt('seq');

  /// The generation the local tables of the app hold
  int get checkpoint => _metaInt('checkpoint');

  /// Records that the local tables now hold everything up to [seq]; the tombstones up to it are no longer needed
  void setCheckpoint(int seq) => _write(() {
    _setMeta('checkpoint', seq);
    _setMeta('full_sync', 0);
    _db.execute('DELETE FROM tombstones WHERE change_seq <= ?', [seq]);
  });

  /// Forgets the checkpoint: the next sync is a full one
  void clearCheckpoint() => _write(() {
    _setMeta('checkpoint', 0);
    _setMeta('full_sync', 1);
  });

  /// After the roots changed, or before anything was ever synced
  bool get fullSyncNeeded => _metaInt('full_sync') == 1 || checkpoint == 0;

  /// Bumped whenever the roots change, so that a scan made before is no longer fresh
  int get rootsVersion => _metaInt('roots_version');

  void _rootsChanged() {
    _setMeta('roots_version', _metaInt('roots_version') + 1);
    _setMeta('full_sync', 1);
  }

  /// When the last complete scan ended (milliseconds since the epoch) and the roots version it saw
  ({int endedMs, int rootsVersion}) get lastScan =>
      (endedMs: _metaInt('last_scan_end_ms'), rootsVersion: _metaInt('scanned_roots_version'));

  void recordScanEnd({required int endedMs, required int rootsVersion}) => _write(() {
    _setMeta('last_scan_end_ms', endedMs);
    _setMeta('scanned_roots_version', rootsVersion);
  });

  // --- scan lease ---

  /// Takes the right to scan for [ttl] unless another scan holds it; renewed by calling again with the same [owner]
  bool tryAcquireScanLease(String owner, Duration ttl, {DateTime? now}) => _write(() {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final holder = _meta('lease_owner') as String?;
    final until = _metaInt('lease_until_ms');
    if (holder != null && holder != owner && until > at) {
      return false;
    }
    _setMeta('lease_owner', owner);
    _setMeta('lease_until_ms', at + ttl.inMilliseconds);
    return true;
  });

  void releaseScanLease(String owner) => _write(() {
    if (_meta('lease_owner') == owner) {
      _setMeta('lease_owner', null);
      _setMeta('lease_until_ms', 0);
    }
  });

  // --- roots ---

  /// The roots in the order they were added; [withCounts] adds how many files each shows and leaves out, which reads
  /// every file of the index
  List<LibraryRoot> roots({bool withCounts = true}) {
    final counts = <String, (int, int)>{
      if (withCounts)
        for (final row in _db.select(
          'SELECT root_id, SUM(cloud_only = 0) AS shown, SUM(cloud_only = 1) AS cloud FROM files GROUP BY root_id',
        ))
          row['root_id'] as String: ((row['shown'] as int?) ?? 0, (row['cloud'] as int?) ?? 0),
    };
    return [
      for (final row in _db.select('SELECT * FROM roots ORDER BY added_ms, id'))
        LibraryRoot(
          id: row['id'] as String,
          path: row['path'] as String,
          volumeKey: row['volume_key'] as String,
          pathInVolume: row['path_in_volume'] as String,
          isNetwork: row['network'] == 1,
          includeCloudOnly: row['include_cloud_only'] == 1,
          available: row['available'] == 1,
          addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_ms'] as int),
          scannedAt: row['scanned_ms'] == null ? null : DateTime.fromMillisecondsSinceEpoch(row['scanned_ms'] as int),
          fileCount: counts[row['id']]?.$1 ?? 0,
          cloudOnlyCount: counts[row['id']]?.$2 ?? 0,
        ),
    ];
  }

  bool get hasRoots => _db.select('SELECT 1 FROM roots LIMIT 1').isNotEmpty;

  void addRoot(LibraryRoot root) => _write(() {
    _db.execute(
      'INSERT OR IGNORE INTO roots (id, path, volume_key, path_in_volume, network, include_cloud_only, available, '
      'added_ms) VALUES (?, ?, ?, ?, ?, ?, 1, ?)',
      [
        root.id,
        root.path,
        root.volumeKey,
        root.pathInVolume,
        root.isNetwork ? 1 : 0,
        root.includeCloudOnly ? 1 : 0,
        root.addedAt.millisecondsSinceEpoch,
      ],
    );
    _rootsChanged();
  });

  /// Removes the root [id]: its files leave the library (a tombstone each), the files themselves stay where they are
  void removeRoot(String id) => _write(() {
    final seq = _nextSeq();
    _db
      ..execute('INSERT OR REPLACE INTO tombstones (id, change_seq) SELECT id, ? FROM files WHERE root_id = ?', [
        seq,
        id,
      ])
      ..execute('DELETE FROM files WHERE root_id = ?', [id])
      ..execute('DELETE FROM roots WHERE id = ?', [id]);
    _rootsChanged();
  });

  /// "Download and include" for the files of [id] kept online only, or the way back; the root counts as never scanned,
  /// so that the next scan reads it whatever kind of folder it is
  void setIncludeCloudOnly(String id, {required bool include}) => _write(() {
    _db.execute('UPDATE roots SET include_cloud_only = ?, scanned_ms = NULL WHERE id = ?', [include ? 1 : 0, id]);
    _rootsChanged();
  });

  /// Where the root is now, and whether its drive is connected; the files keep their ids either way
  void updateRootLocation(String id, {required String path, required bool available}) =>
      _db.execute('UPDATE roots SET path = ?, available = ? WHERE id = ?', [path, available ? 1 : 0, id]);

  // --- scan ---

  /// What the index has of the files of [rootId], by id, for a scan to compare against
  Map<String, KnownFile> knownFiles(String rootId) => {
    for (final row in _db.select('SELECT id, rel_path, size, modified_ms, cloud_only FROM files WHERE root_id = ?', [
      rootId,
    ]))
      row['id'] as String: (
        relativePath: row['rel_path'] as String,
        size: row['size'] as int,
        modifiedMs: row['modified_ms'] as int,
        cloudOnly: row['cloud_only'] == 1,
      ),
  };

  /// Writes [files], new or changed, as one generation; the checksum of a changed file is kept with its size and date,
  /// so it stops counting as soon as either differs
  void writeFiles(List<IndexedFile> files) {
    if (files.isEmpty) {
      return;
    }
    _write(() {
      final seq = _nextSeq();
      final statement = _db.prepare('''
        INSERT INTO files (id, root_id, album_id, rel_path, type, size, modified_ms, added_s, created_s, width, height,
          duration_ms, playback_style, latitude, longitude, projection, cloud_only, change_seq)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET album_id = excluded.album_id, rel_path = excluded.rel_path, type = excluded.type,
          size = excluded.size, modified_ms = excluded.modified_ms, created_s = excluded.created_s,
          width = excluded.width, height = excluded.height, duration_ms = excluded.duration_ms,
          playback_style = excluded.playback_style, latitude = excluded.latitude, longitude = excluded.longitude,
          projection = excluded.projection, cloud_only = excluded.cloud_only, change_seq = excluded.change_seq''');
      // A file that comes back before the app learnt it was gone is a change, not a deletion followed by an addition
      final revive = _db.prepare('DELETE FROM tombstones WHERE id = ?');
      try {
        for (final file in files) {
          revive.execute([file.id]);
          statement.execute([
            file.id,
            file.rootId,
            file.albumId,
            file.relativePath,
            file.type,
            file.size,
            file.modifiedMs,
            file.addedSeconds,
            file.createdSeconds,
            file.width,
            file.height,
            file.durationMs,
            file.playbackStyle,
            file.latitude,
            file.longitude,
            file.projection,
            file.cloudOnly ? 1 : 0,
            seq,
          ]);
        }
      } finally {
        statement.close();
        revive.close();
      }
    });
  }

  /// Removes the files [ids] of a root, gone from its folders, as one generation
  void removeFiles(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) {
      return;
    }
    _write(() {
      final seq = _nextSeq();
      final tombstone = _db.prepare('INSERT OR REPLACE INTO tombstones (id, change_seq) VALUES (?, ?)');
      final delete = _db.prepare('DELETE FROM files WHERE id = ?');
      try {
        for (final id in list) {
          tombstone.execute([id, seq]);
          delete.execute([id]);
        }
      } finally {
        tombstone.close();
        delete.close();
      }
    });
  }

  void markRootScanned(String id, DateTime at) =>
      _db.execute('UPDATE roots SET scanned_ms = ? WHERE id = ?', [at.millisecondsSinceEpoch, id]);

  // --- queries of the sync API ---

  IndexedFile _fileOf(Row row) => IndexedFile(
    id: row['id'] as String,
    rootId: row['root_id'] as String,
    albumId: row['album_id'] as String,
    relativePath: row['rel_path'] as String,
    type: row['type'] as int,
    size: row['size'] as int,
    modifiedMs: row['modified_ms'] as int,
    addedSeconds: row['added_s'] as int,
    createdSeconds: row['created_s'] as int,
    width: row['width'] as int?,
    height: row['height'] as int?,
    durationMs: row['duration_ms'] as int,
    playbackStyle: row['playback_style'] as int,
    latitude: (row['latitude'] as num?)?.toDouble(),
    longitude: (row['longitude'] as num?)?.toDouble(),
    projection: row['projection'] as String?,
    cloudOnly: row['cloud_only'] == 1,
    checksum: row['checksum'] as String?,
    checksumSize: row['checksum_size'] as int?,
    checksumModifiedMs: row['checksum_modified_ms'] as int?,
    changeSeq: row['change_seq'] as int,
  );

  /// The changes after the checkpoint [after], up to the current generation, read in one transaction
  IndexDelta changesSince(int after) => _read(() {
    final upTo = seq;
    final updates = [
      for (final row in _db.select(
        'SELECT * FROM files WHERE change_seq > ? AND change_seq <= ? AND cloud_only = 0 ORDER BY id',
        [after, upTo],
      ))
        _fileOf(row),
    ];
    final deletes = [
      for (final row in _db.select(
        'SELECT id FROM tombstones WHERE change_seq > ?1 AND change_seq <= ?2 '
        'UNION SELECT id FROM files WHERE change_seq > ?1 AND change_seq <= ?2 AND cloud_only = 1',
        [after, upTo],
      ))
        row['id'] as String,
    ];
    return (updates: updates, deletes: deletes, seq: upTo);
  });

  /// The albums of the library, by id; the files kept online only make no album
  List<IndexedAlbum> albums() => [
    for (final row in _db.select('''
      SELECT album_id, root_id, MIN(rel_path) AS sample, COUNT(*) AS assets,
        MAX(MAX(modified_ms / 1000, added_s)) AS updated
      FROM files WHERE cloud_only = 0 GROUP BY album_id ORDER BY album_id'''))
      IndexedAlbum(
        id: row['album_id'] as String,
        rootId: row['root_id'] as String,
        relativeDir: _dirOf(row['sample'] as String),
        assetCount: row['assets'] as int,
        updatedSeconds: row['updated'] as int,
      ),
  ];

  static String _dirOf(String relativePath) {
    final slash = relativePath.lastIndexOf('/');
    return slash < 0 ? '' : relativePath.substring(0, slash);
  }

  List<IndexedFile> filesOfAlbum(String albumId, {int? changedAfterSeconds}) => [
    for (final row
        in changedAfterSeconds == null
            ? _db.select('SELECT * FROM files WHERE album_id = ? AND cloud_only = 0 ORDER BY id', [albumId])
            : _db.select(
                'SELECT * FROM files WHERE album_id = ? AND cloud_only = 0 AND (modified_ms / 1000 > ?2 OR added_s > ?2) '
                'ORDER BY id',
                [albumId, changedAfterSeconds],
              ))
      _fileOf(row),
  ];

  List<String> fileIdsOfAlbum(String albumId) => [
    for (final row in _db.select('SELECT id FROM files WHERE album_id = ? AND cloud_only = 0 ORDER BY id', [albumId]))
      row['id'] as String,
  ];

  /// Files of [albumId] the index first saw after [seconds]
  int countAddedSince(String albumId, int seconds) =>
      _db.select('SELECT COUNT(*) AS n FROM files WHERE album_id = ? AND cloud_only = 0 AND added_s > ?', [
            albumId,
            seconds,
          ]).first['n']
          as int;

  IndexedFile? file(String id) {
    final rows = _db.select('SELECT * FROM files WHERE id = ?', [id]);
    return rows.isEmpty ? null : _fileOf(rows.first);
  }

  /// The files among [ids] the index has, in no particular order
  List<IndexedFile> files(Iterable<String> ids) {
    final result = <IndexedFile>[];
    final list = ids.toList();
    // SQLite takes up to 32766 parameters; chunks keep each statement small
    for (var start = 0; start < list.length; start += 500) {
      final chunk = list.sublist(start, start + 500 > list.length ? list.length : start + 500);
      final marks = List.filled(chunk.length, '?').join(', ');
      result.addAll(_db.select('SELECT * FROM files WHERE id IN ($marks)', chunk).map(_fileOf));
    }
    return result;
  }

  /// The root [id] as the index has it, without its counts
  LibraryRoot? root(String id) => roots(withCounts: false).where((root) => root.id == id).firstOrNull;

  /// Keeps the checksums computed, each with the size and date of the file it was computed on
  void storeChecksums(List<({String id, String checksum, int size, int modifiedMs})> checksums) {
    if (checksums.isEmpty) {
      return;
    }
    _write(() {
      final statement = _db.prepare(
        'UPDATE files SET checksum = ?, checksum_size = ?, checksum_modified_ms = ? WHERE id = ?',
      );
      try {
        for (final entry in checksums) {
          statement.execute([entry.checksum, entry.size, entry.modifiedMs, entry.id]);
        }
      } finally {
        statement.close();
      }
    });
  }
}
