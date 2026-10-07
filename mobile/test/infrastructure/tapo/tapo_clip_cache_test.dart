// The clips fetched from a camera live in one folder per camera under the cache directory of the app, deleted with the
// camera. Only the id of a source becomes a folder name, so that no stored value can point a deletion elsewhere.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_clip_cache.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('immuch360-tapo-cache');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Future<Directory> cacheRoot() async => root;

  test('a camera keeps its clips under tapo/<source id> of the cache, not created in advance', () async {
    final directory = await tapoCameraCacheDirectory('0123456789abcdef', cacheRoot: cacheRoot);

    expect(directory.path, '${root.path}/tapo/0123456789abcdef');
    expect(directory.existsSync(), isFalse);
  });

  test('deletes the clips of one camera only, and nothing when there are none', () async {
    final camera = await tapoCameraCacheDirectory('0123456789abcdef', cacheRoot: cacheRoot);
    final other = await tapoCameraCacheDirectory('fedcba9876543210', cacheRoot: cacheRoot);
    await File('${camera.path}/2026-10-06/1759730400-1759730460.mov').create(recursive: true);
    await File('${other.path}/2026-10-06/1759730400-1759730460.mov').create(recursive: true);

    await deleteTapoCameraCache('0123456789abcdef', cacheRoot: cacheRoot);

    expect(camera.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    await deleteTapoCameraCache('0123456789abcdef', cacheRoot: cacheRoot);
  });

  test('refuses anything but an id of 16 lower case hex digits', () async {
    for (final id in ['', '..', '../../files', '0123456789ABCDEF', '0123456789abcde', '0123456789abcdef0', 'a/b']) {
      await expectLater(tapoCameraCacheDirectory(id, cacheRoot: cacheRoot), throwsArgumentError, reason: id);
      await expectLater(deleteTapoCameraCache(id, cacheRoot: cacheRoot), throwsArgumentError, reason: id);
    }
    expect(root.existsSync(), isTrue);
  });
}
