import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/thumbnail_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  ThumbnailSource source(String id, {int length = 1000, DateTime? modified}) =>
      ThumbnailSource(assetId: id, length: length, modified: modified ?? DateTime.utc(2026, 10, 8, 12));

  Uint8List bytes(int length, [int value = 7]) => Uint8List(length)..fillRange(0, length, value);

  List<File> thumbs() => root.existsSync()
      ? root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith(ThumbnailCache.extension))
            .toList()
      : [];

  setUp(() => root = Directory(p.join(Directory.systemTemp.createTempSync('immuch360-thumbs').path, 'thumbs')));

  tearDown(() => root.parent.deleteSync(recursive: true));

  group('buckets', () {
    test('the timeline tiles, the larger small views, then the file itself', () {
      expect(ThumbnailCache.bucketFor(320, 320), 320);
      expect(ThumbnailCache.bucketFor(100, 50), 320);
      expect(ThumbnailCache.bucketFor(321, 10), 1024);
      expect(ThumbnailCache.bucketFor(1024, 1024), 1024);
      expect(ThumbnailCache.bucketFor(1025, 1), isNull);
      expect(ThumbnailCache.bucketFor(0, 0), isNull, reason: 'the whole image');
      expect(ThumbnailCache.bucketFor(-1, 300), isNull);
    });
  });

  group('names', () {
    test('a file edited in place (size or date) gets a new name, the same file keeps its name', () {
      final base = ThumbnailCache.relativePath(source('f1'), 320);
      expect(ThumbnailCache.relativePath(source('f1'), 320), base);
      expect(ThumbnailCache.relativePath(source('f1', length: 1001), 320), isNot(base));
      expect(
        ThumbnailCache.relativePath(source('f1', modified: DateTime.utc(2026, 10, 8, 12, 0, 1)), 320),
        isNot(base),
      );
      expect(ThumbnailCache.relativePath(source('f1'), 1024), isNot(base));
      expect(ThumbnailCache.relativePath(source('f2'), 320), isNot(base));
    });

    test('hold neither the asset id nor anything of the path, in one of 256 shard folders', () {
      const id = r'C:\Users\someone\Pictures\IMG_0001.JPG';
      final relative = ThumbnailCache.relativePath(source(id), 320);
      expect(relative, isNot(contains('someone')));
      expect(relative, isNot(contains('IMG_0001')));
      final parts = p.split(relative);
      expect(parts, hasLength(2));
      expect(parts.first, matches(RegExp(r'^[0-9a-f]{2}$')));
      expect(parts.last, matches(RegExp(r'^[0-9a-f]{40}-320-[0-9a-z]+-[0-9a-z]+\.thumb$')));
    });
  });

  group('reading and writing', () {
    test('what is written is read back, nothing half written stays', () async {
      final cache = ThumbnailCache(directory: () async => root);
      expect(await cache.read(source('f1'), 320), isNull);

      await cache.write(source('f1'), 320, bytes(64));
      expect(await cache.read(source('f1'), 320), bytes(64));
      expect(await cache.read(source('f1'), 1024), isNull);
      expect(await cache.read(source('f1', length: 2000), 320), isNull, reason: 'another version of the file');
      expect(root.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.part')), isEmpty);
    });

    test('clearing removes every thumbnail and tells the bytes freed', () async {
      final cache = ThumbnailCache(directory: () async => root);
      await cache.write(source('f1'), 320, bytes(100));
      await cache.write(source('f2'), 1024, bytes(300));
      expect(await cache.clear(), 400);
      expect(thumbs(), isEmpty);
      expect(await cache.read(source('f1'), 320), isNull);

      await cache.write(source('f3'), 320, bytes(10));
      expect(await cache.read(source('f3'), 320), bytes(10), reason: 'usable again after clearing');
    });
  });

  group('size limit', () {
    test('the thumbnails used longest ago go first, down to nine tenths of the limit', () async {
      final writer = ThumbnailCache(directory: () async => root);
      final now = DateTime.now();
      for (var index = 0; index < 10; index++) {
        await writer.write(source('f$index'), 320, bytes(100));
        File(
          p.join(root.path, ThumbnailCache.relativePath(source('f$index'), 320)),
        ).setLastModifiedSync(now.subtract(Duration(hours: 10 - index)));
      }

      final cache = ThumbnailCache(directory: () async => root, maxBytes: 500);
      expect(await cache.trimNow(), 400);
      final left = thumbs().map((file) => p.basename(file.path)).toSet();
      for (var index = 0; index < 10; index++) {
        final name = p.basename(ThumbnailCache.relativePath(source('f$index'), 320));
        expect(left.contains(name), index >= 6, reason: 'f$index');
      }
    });

    test('a cache under its limit is left alone, and old leftovers of interrupted writes go', () async {
      final cache = ThumbnailCache(directory: () async => root, maxBytes: 10000);
      await cache.write(source('f1'), 320, bytes(100));
      final leftover = File(p.join(root.path, 'ab', 'something.png.123.part'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes(50));
      leftover.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      final fresh = File(p.join(root.path, 'ab', 'other.png.456.part'))..writeAsBytesSync(bytes(50));

      expect(await cache.trimNow(), 100);
      expect(thumbs(), hasLength(1));
      expect(leftover.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue, reason: 'may be a write of this session');
    });

    test('the first write of a session measures the cache and trims it in the background when too large', () async {
      final earlier = ThumbnailCache(directory: () async => root);
      final old = DateTime.now().subtract(const Duration(days: 1));
      for (var index = 0; index < 5; index++) {
        await earlier.write(source('f$index'), 320, bytes(100));
        File(p.join(root.path, ThumbnailCache.relativePath(source('f$index'), 320))).setLastModifiedSync(old);
      }

      final cache = ThumbnailCache(directory: () async => root, maxBytes: 250);
      await cache.write(source('new'), 320, bytes(100));
      // The measuring and the trimming run in another isolate
      for (var wait = 0; wait < 200 && thumbs().length > 2; wait++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(thumbs(), hasLength(2));
      expect(await cache.read(source('new'), 320), bytes(100), reason: 'the newest stays');
    });
  });
}
