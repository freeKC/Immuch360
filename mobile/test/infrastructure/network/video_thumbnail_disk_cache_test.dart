import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/video_thumbnail_disk_cache.dart';
import 'package:path/path.dart' as p;

import '../../domain/services/video_thumbnail_fakes.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('video_thumbnail_cache_');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  VideoThumbnailDiskCache cache({int maxBytes = 1000, Directory? folder}) =>
      VideoThumbnailDiskCache(() async => folder ?? directory, maxBytes: maxBytes);

  Uint8List bytes(int length, [int value = 1]) => Uint8List.fromList(List.filled(length, value));

  List<String> files() => directory.listSync().map((entity) => p.basename(entity.path)).toList()..sort();

  test('gives back what it kept, by video', () async {
    final thumbnails = cache();
    await thumbnails.write(videoKey('/a.mp4'), bytes(10, 1));
    await thumbnails.write(videoKey('/b.mp4'), bytes(20, 2));

    expect(await thumbnails.read(videoKey('/a.mp4')), bytes(10, 1));
    expect(await thumbnails.read(videoKey('/b.mp4')), bytes(20, 2));
    expect(await thumbnails.read(videoKey('/c.mp4')), isNull);
    expect(await thumbnails.totalBytes, 30);
    expect(files(), hasLength(2));
  });

  test('a video changed on its share (size, date) or of another share is another thumbnail', () async {
    final thumbnails = cache();
    await thumbnails.write(videoKey('/a.mp4'), bytes(10));

    expect(await thumbnails.read(videoKey('/a.mp4', size: 1001)), isNull);
    expect(await thumbnails.read(videoKey('/a.mp4', modified: DateTime.utc(2026, 10, 3))), isNull);
    expect(
      await thumbnails.read((sourceId: 'other', path: '/a.mp4', size: 1000, modified: DateTime.utc(2026, 10, 2))),
      isNull,
    );
    expect(await thumbnails.read((sourceId: 'nas', path: '/a.mp4', size: null, modified: null)), isNull);
    expect(await thumbnails.read(videoKey('/a.mp4')), isNotNull);
  });

  test('replaces the thumbnail of a video written again', () async {
    final thumbnails = cache();
    await thumbnails.write(videoKey('/a.mp4'), bytes(10, 1));
    await thumbnails.write(videoKey('/a.mp4'), bytes(15, 2));

    expect(await thumbnails.read(videoKey('/a.mp4')), bytes(15, 2));
    expect(await thumbnails.totalBytes, 15);
  });

  test('drops the thumbnails used the longest ago past its size', () async {
    final thumbnails = cache(maxBytes: 250);
    await thumbnails.write(videoKey('/a.mp4'), bytes(100));
    await thumbnails.write(videoKey('/b.mp4'), bytes(100));
    await thumbnails.read(videoKey('/a.mp4'));
    await thumbnails.write(videoKey('/c.mp4'), bytes(100));

    expect(await thumbnails.read(videoKey('/b.mp4')), isNull);
    expect(await thumbnails.read(videoKey('/a.mp4')), isNotNull);
    expect(await thumbnails.read(videoKey('/c.mp4')), isNotNull);
    expect(await thumbnails.totalBytes, 200);
    expect(files(), hasLength(2));
  });

  test(
    'finds its files when the app starts again, oldest dropped first by their date, half written ones removed',
    () async {
      final before = cache();
      await before.write(videoKey('/old.mp4'), bytes(100));
      await before.write(videoKey('/recent.mp4'), bytes(100));
      await before.write(videoKey('/newest.mp4'), bytes(100));
      final now = DateTime.now();
      File(
        p.join(directory.path, VideoThumbnailDiskCache.fileNameOf(videoKey('/old.mp4'))),
      ).setLastModifiedSync(now.subtract(const Duration(days: 3)));
      File(
        p.join(directory.path, VideoThumbnailDiskCache.fileNameOf(videoKey('/recent.mp4'))),
      ).setLastModifiedSync(now.subtract(const Duration(days: 1)));
      File(p.join(directory.path, 'stopped.jpg.part')).writeAsBytesSync(bytes(50));

      final after = cache(maxBytes: 250);

      expect(await after.totalBytes, 200);
      expect(await after.read(videoKey('/old.mp4')), isNull);
      expect(await after.read(videoKey('/recent.mp4')), isNotNull);
      expect(await after.read(videoKey('/newest.mp4')), isNotNull);
      expect(files().where((name) => name.endsWith('.part')), isEmpty);
    },
  );

  test('a folder it cannot use is a cache that keeps nothing', () async {
    final file = File(p.join(directory.path, 'not_a_folder'))..writeAsStringSync('');
    final thumbnails = cache(folder: Directory(file.path));

    await thumbnails.write(videoKey('/a.mp4'), bytes(10));
    expect(await thumbnails.read(videoKey('/a.mp4')), isNull);
    expect(await thumbnails.totalBytes, 0);
  });

  test('a thumbnail removed behind its back is a miss', () async {
    final thumbnails = cache();
    await thumbnails.write(videoKey('/a.mp4'), bytes(10));
    for (final entity in directory.listSync()) {
      entity.deleteSync();
    }

    expect(await thumbnails.read(videoKey('/a.mp4')), isNull);
    expect(await thumbnails.totalBytes, 0);
  });
}
