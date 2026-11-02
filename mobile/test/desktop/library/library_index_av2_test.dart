// Schema 5 of the index of the folder library: the scan reads the head of each .ivf and .obu once and keeps "av2" in
// the video_codec column of an AV2 stream, so that the badge of its thumbnail reads the index and never the file
// (store/m2/av2-2026-11-02/plan-2026-11-02.md, section 1.2). The fixtures are those of lot AD0 (test/fixtures/av2).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'library_test_support.dart';

const _fixtures = 'test/fixtures/av2';

Uint8List _fixture(String name) => File(p.join(_fixtures, name)).readAsBytesSync();

void main() {
  group('the metadata of a video file', () {
    test('an AV2 IVF says AV2, its frame and its length from its header (12 frames at 30 per second)', () {
      for (final name in ['av2-256x144-8bit.ivf', 'av2-256x144-10bit.ivf']) {
        final metadata = readMediaMetadata(BytesSource(_fixture(name)), LibraryMediaKind.video);
        expect(metadata.videoCodec, IndexedVideoCodec.av2, reason: name);
        expect((metadata.width, metadata.height, metadata.durationMs), (256, 144, 400), reason: name);
        expect(metadata.readFailed, isFalse, reason: name);
      }
    });

    test('a Section 5 stream says AV2, without a frame size nor a length, which only its decoder knows', () {
      for (final name in ['av2-256x144-8bit.obu', 'av2-256x144-10bit.obu']) {
        final metadata = readMediaMetadata(BytesSource(_fixture(name)), LibraryMediaKind.video);
        expect(metadata.videoCodec, IndexedVideoCodec.av2, reason: name);
        expect((metadata.width, metadata.height, metadata.durationMs), (null, null, 0), reason: name);
      }
    });

    test('an IVF of AV1, random bytes, a cut head and a photo are no AV2', () {
      expect(readMediaMetadata(BytesSource(_fixture('av1-256x144-8bit.ivf')), LibraryMediaKind.video).videoCodec, null);
      final random = Uint8List.fromList(List.generate(64, (i) => (i * 37 + 11) & 0xff));
      expect(readMediaMetadata(BytesSource(random), LibraryMediaKind.video).videoCodec, null);
      final cut = Uint8List.sublistView(_fixture('av2-256x144-8bit.ivf'), 0, 20);
      expect(readMediaMetadata(BytesSource(cut), LibraryMediaKind.video).videoCodec, null);
      expect(readMediaMetadata(BytesSource(_fixture('av2-256x144-8bit.ivf')), LibraryMediaKind.image).videoCodec, null);
    });

    test('a file cut after its header or damaged inside is still told AV2 by its head', () {
      for (final name in ['av2-256x144-8bit-cut.ivf', 'av2-256x144-8bit-damaged.ivf']) {
        expect(
          readMediaMetadata(BytesSource(_fixture(name)), LibraryMediaKind.video).videoCodec,
          IndexedVideoCodec.av2,
          reason: name,
        );
      }
    });
  });

  group('a scan', () {
    late TestLibrary fixture;
    late String rootId;

    setUp(() {
      fixture = TestLibrary();
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
      for (final name in [
        'av2-256x144-8bit.ivf',
        'av2-256x144-8bit.obu',
        'av2-256x144-10bit.ivf',
        'av1-256x144-8bit.ivf',
      ]) {
        fixture.write('Clips/$name', _fixture(name));
      }
      rootId = fixture.library().addRoot(p.join(fixture.files.path, 'Clips')).id;
    });
    tearDown(() => fixture.dispose());

    test('keeps AV2 in the index for the AV2 streams only, and lists them for the badges', () async {
      await fixture.scan();
      final index = fixture.index();

      for (final name in ['av2-256x144-8bit.ivf', 'av2-256x144-8bit.obu', 'av2-256x144-10bit.ivf']) {
        final file = index.file(fixture.ids.file(rootId, name))!;
        expect(file.videoCodec, IndexedVideoCodec.av2, reason: name);
        expect(file.type, 2, reason: name);
      }
      final ivf = index.file(fixture.ids.file(rootId, 'av2-256x144-8bit.ivf'))!;
      expect((ivf.width, ivf.height, ivf.durationMs), (256, 144, 400));
      // An IVF of AV1 is listed as a video, without the codec: no AV2 badge, no AV2 player
      expect(index.file(fixture.ids.file(rootId, 'av1-256x144-8bit.ivf'))!.videoCodec, isNull);

      expect(index.av2VideoIds(), {
        fixture.ids.file(rootId, 'av2-256x144-8bit.ivf'),
        fixture.ids.file(rootId, 'av2-256x144-8bit.obu'),
        fixture.ids.file(rootId, 'av2-256x144-10bit.ivf'),
      });
    });

    test('a stream that cannot be read at a scan keeps its codec until it is read again', () async {
      await fixture.scan();
      final path = p.join(fixture.files.path, 'Clips', 'av2-256x144-8bit.ivf');
      fixture.failing.add(path);
      File(path).setLastModifiedSync(DateTime(2026, 11, 3));
      await fixture.scan();

      final file = fixture.index().file(fixture.ids.file(rootId, 'av2-256x144-8bit.ivf'))!;
      expect(file.readFailed, isTrue);
      expect(file.videoCodec, IndexedVideoCodec.av2);
    });
  });

  group('an index of schema 4', () {
    late TestLibrary fixture;

    setUp(() {
      fixture = TestLibrary();
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    });
    tearDown(() => fixture.dispose());

    test('gets the video_codec column, its files kept as they were', () {
      // An index of schema 4 made by the current code, the column then taken away as the builds before AD5 had it
      LibraryIndex.open(fixture.indexPath).close();
      final db = sqlite3.open(fixture.indexPath)
        ..execute('ALTER TABLE files DROP COLUMN video_codec')
        ..execute(
          'INSERT INTO files (id, root_id, album_id, rel_path, type, size, modified_ms, added_s, created_s, '
          'change_seq) VALUES (?, ?, ?, ?, 2, 10, 1, 1, 1, 1)',
          ['a', 'win-0000beef:/Clips', 'album', 'clip.mp4'],
        )
        ..execute('PRAGMA user_version = 4');
      db.close();

      final index = fixture.index();
      final check = sqlite3.open(fixture.indexPath);
      addTearDown(check.close);
      expect(check.select('PRAGMA user_version').first.values.first, 5);
      final columns = {for (final row in check.select('PRAGMA table_info(files)')) row['name'] as String};
      expect(columns, contains('video_codec'));
      final file = index.file('a')!;
      expect((file.relativePath, file.videoCodec), ('clip.mp4', null));
    });

    test('an index made new has schema 5 at once', () {
      final index = fixture.index();
      expect(index.av2VideoIds(), isEmpty);
      final db = sqlite3.open(fixture.indexPath);
      addTearDown(db.close);
      expect(db.select('PRAGMA user_version').first.values.first, 5);
    });
  });
}
