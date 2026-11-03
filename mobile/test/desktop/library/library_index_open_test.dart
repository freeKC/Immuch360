// The connections of the index of the folder library at the first start of the app: the scan, the sync API and the
// main isolate each open their own (see library_index.dart), and the first one to come switches the new file to WAL
// while the others open it. They wait for each other's locks instead of failing with "database is locked"
// (SQLITE_BUSY), which the Ubuntu 22.04 package container of the desktop CI met once when the video smoke opened its
// clip at startup (run 41632950614, 3 November 2026).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
}
