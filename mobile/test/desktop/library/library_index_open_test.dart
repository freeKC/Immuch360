// The connections of the index of the folder library at the first start of the app: the scan, the sync API and the
// main isolate each open their own (see library_index.dart), and the first one to come switches the new file to WAL
// while the others open it. They wait for each other's locks instead of failing with "database is locked"
// (SQLITE_BUSY), which the Ubuntu 22.04 package container of the desktop CI met once when the video smoke opened its
// clip at startup (run 41632950614, 3 November 2026).
//
// The last test opens the index on a file system of its own, in memory, which sees what the connection does with its
// file: the time out set before its first statement.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Opens the index at [path] in an isolate of its own, as the scan and the sync API do, once [startAtUs] (microseconds
/// since the epoch) is reached; the number of its roots
Future<int> _openElsewhere(String path, {int startAtUs = 0}) => Isolate.run(() {
  while (DateTime.now().microsecondsSinceEpoch < startAtUs) {}
  final index = LibraryIndex.open(path);
  try {
    return index.roots().length;
  } finally {
    index.close();
  }
});

String _journalMode(String path) {
  final db = sqlite3.open(path);
  try {
    return db.select('PRAGMA journal_mode').single.values.single! as String;
  } finally {
    db.close();
  }
}

/// A file system for SQLite in memory that sees what the connections do with their files: the ones they keep open, the
/// shared locks it refuses them as another connection's exclusive lock would, and the waits SQLite's busy handler asks
/// for between two tries, recorded instead of slept. Nothing sleeps, so the profiler of flutter test, which cuts
/// SQLite's sleeps short, changes nothing here
final class _WatchedFileSystem extends BaseVirtualFileSystem {
  _WatchedFileSystem() : super(name: 'library-index-open-test');

  final _memory = InMemoryFileSystem();

  /// The files open now
  final open = <_WatchedFile>{};

  /// How many shared locks are still refused
  var locksToRefuse = 0;

  /// The waits of SQLite's busy handler, in the order it asked for them
  final waits = <Duration>[];

  @override
  XOpenResult xOpen(Sqlite3Filename path, int flags) {
    final opened = _memory.xOpen(path, flags);
    final file = _WatchedFile(this, opened.file as VirtualFileSystemFileV1, path.path);
    open.add(file);
    return (outFlags: opened.outFlags, file: file);
  }

  @override
  void xDelete(String path, int syncDir) => _memory.xDelete(path, syncDir);

  @override
  int xAccess(String path, int flags) => _memory.xAccess(path, flags);

  @override
  String xFullPathName(String path) => _memory.xFullPathName(path);

  @override
  void xSleep(Duration duration) => waits.add(duration);
}

final class _WatchedFile implements VirtualFileSystemFileV1 {
  _WatchedFile(this._files, this._file, this.path);

  final _WatchedFileSystem _files;
  final VirtualFileSystemFileV1 _file;
  final String? path;

  @override
  void xLock(int mode) {
    if (mode == SqlFileLockingLevels.SQLITE_LOCK_SHARED && _files.locksToRefuse > 0) {
      _files.locksToRefuse--;
      throw const VfsException(SqlError.SQLITE_BUSY);
    }
    _file.xLock(mode);
  }

  @override
  void xClose() {
    _files.open.remove(this);
    _file.xClose();
  }

  @override
  void xRead(Uint8List target, int fileOffset) => _file.xRead(target, fileOffset);

  @override
  void xWrite(Uint8List buffer, int fileOffset) => _file.xWrite(buffer, fileOffset);

  @override
  void xTruncate(int size) => _file.xTruncate(size);

  @override
  void xSync(int flags) => _file.xSync(flags);

  @override
  int xFileSize() => _file.xFileSize();

  @override
  void xUnlock(int mode) => _file.xUnlock(mode);

  @override
  int xCheckReservedLock() => _file.xCheckReservedLock();

  @override
  int get xDeviceCharacteristics => _file.xDeviceCharacteristics;

  @override
  int xFileControl(SqliteFileControl op, int ptr) => _file.xFileControl(op, ptr);

  @override
  int get xSectorSize => _file.xSectorSize;

  @override
  String toString() => path ?? '(a temporary file)';
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('library_index_open'));
  tearDown(() => dir.delete(recursive: true));

  test('a connection that opens the new index while another one holds its lock waits for it', () async {
    final path = p.join(dir.path, 'desktop_library.sqlite');
    // The first connection, in the middle of its write: an exclusive lock on the file, which no one may read meanwhile
    final first = sqlite3.open(path)..execute('BEGIN EXCLUSIVE');
    addTearDown(first.close);
    final release = Timer(const Duration(milliseconds: 400), () => first.execute('COMMIT'));
    addTearDown(release.cancel);

    final clock = Stopwatch()..start();
    final roots = await _openElsewhere(path);

    expect(roots, 0);
    // It met the lock and waited for it
    expect(clock.elapsed, greaterThan(const Duration(milliseconds: 200)));
    expect(_journalMode(path), 'wal');
  });

  test('the connections of the scan, the sync API and the app all open a new index they open together', () async {
    for (var round = 0; round < 25; round++) {
      final path = p.join(dir.path, 'desktop_library_$round.sqlite');
      // The three start at the same moment, as far as their isolates allow
      final startAtUs = DateTime.now().add(const Duration(milliseconds: 80)).microsecondsSinceEpoch;
      final roots = await Future.wait([for (var i = 0; i < 3; i++) _openElsewhere(path, startAtUs: startAtUs)]);

      expect(roots, [0, 0, 0], reason: 'round $round');
      expect(_journalMode(path), 'wal', reason: 'round $round');
    }
  });

  group('on a file system that sees the connection', () {
    late _WatchedFileSystem files;
    late String path;

    setUp(() {
      files = _WatchedFileSystem();
      // The default one while the test runs: LibraryIndex.open opens its file as the app does. Only this isolate may
      // call it, so the tests above, whose connections open in isolates of their own, keep the real one
      sqlite3.registerVirtualFileSystem(files, makeDefault: true);
      path = p.join(dir.path, 'desktop_library.sqlite');
    });
    tearDown(() => sqlite3.unregisterVirtualFileSystem(files));

    test('the first statement on the file already waits for the lock of another connection', () {
      // Another connection holds the new file: the first three tries to read it are refused
      files.locksToRefuse = 3;

      LibraryIndex.open(path).close();

      // SQLite's busy handler waited between the tries, inside the switch to WAL, the first statement that reads the
      // file: the time out was set before it. Set after it, the switch fails at once and only its own retry waits
      expect(files.waits, hasLength(3));
      expect(files.open, isEmpty);
    });
  });
}
