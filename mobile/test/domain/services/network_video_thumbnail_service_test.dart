import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/network_video_thumbnail.service.dart';
import 'package:immich_mobile/infrastructure/network/video_thumbnail_disk_cache.dart';

import 'video_thumbnail_fakes.dart';

void main() {
  late Directory directory;
  late FakeVideoThumbnailHost host;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('video_thumbnails_');
    host = FakeVideoThumbnailHost();
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  VideoThumbnailDiskCache diskCache({int maxBytes = VideoThumbnailDiskCache.defaultMaxBytes}) =>
      VideoThumbnailDiskCache(() async => directory, maxBytes: maxBytes);

  /// Lets the calls under way go as far as they can
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('takes a frame at 1 s, 400 pixels wide, from the media bridge URL of the video', () async {
    final service = NetworkVideoThumbnailService(api: host, diskCache: diskCache());

    final bytes = await service.thumbnail(videoKey('/trip.mp4'), bridgeUrl('/trip.mp4'));

    expect(bytes, host.frameOf(bridgeUrl('/trip.mp4').toString()));
    expect(host.calls, hasLength(1));
    final call = host.calls.single;
    expect(call.url, 'http://127.0.0.1:1234/token/nas/trip.mp4');
    expect(call.headers, isEmpty, reason: 'the media bridge needs none, its token is in the URL');
    expect(call.timeMs, 1000);
    expect(call.maxWidth, 400);
  });

  test('keeps the frame on disk: shown again, even after the app starts again, the video is not read', () async {
    final first = NetworkVideoThumbnailService(api: host, diskCache: diskCache());
    final bytes = await first.thumbnail(videoKey('/trip.mp4'), bridgeUrl('/trip.mp4'));
    expect(await first.thumbnail(videoKey('/trip.mp4'), bridgeUrl('/trip.mp4')), bytes);

    final restarted = NetworkVideoThumbnailService(api: host, diskCache: diskCache());
    expect(await restarted.thumbnail(videoKey('/trip.mp4'), bridgeUrl('/trip.mp4')), bytes);

    expect(host.calls, hasLength(1));
  });

  test('takes the frame again when the video changed on its share', () async {
    final service = NetworkVideoThumbnailService(api: host, diskCache: diskCache());

    await service.thumbnail(videoKey('/trip.mp4'), bridgeUrl('/trip.mp4'));
    await service.thumbnail(videoKey('/trip.mp4', size: 2000), bridgeUrl('/trip.mp4'));
    await service.thumbnail(videoKey('/trip.mp4', modified: DateTime.utc(2026, 10, 3)), bridgeUrl('/trip.mp4'));

    expect(host.calls, hasLength(3));
  });

  test('a video whose frame cannot be taken is tried once more, then gets none and is not read again', () async {
    host.frameOf = (_) => null;
    final service = NetworkVideoThumbnailService(api: host, diskCache: diskCache(), retryDelay: Duration.zero);

    expect(await service.thumbnail(videoKey('/broken.mp4'), bridgeUrl('/broken.mp4')), isNull);
    expect(await service.thumbnail(videoKey('/broken.mp4'), bridgeUrl('/broken.mp4')), isNull);

    expect(host.calls, hasLength(2));
    expect(directory.listSync(), isEmpty);
  });

  test('a read cut short (the media bridge bound again) is tried again after a while, and gives the frame', () async {
    final frame = host.frameOf;
    var cut = true;
    host.frameOf = (url) => cut ? null : frame(url);
    final service = NetworkVideoThumbnailService(api: host, retryDelay: const Duration(milliseconds: 50));

    final bytes = service.thumbnail(videoKey('/trip.mp4'), bridgeUrl('/trip.mp4'));
    await settle();
    expect(host.calls, hasLength(1));
    cut = false;

    expect(await bytes, isNotNull);
    expect(host.calls, hasLength(2));
  });

  test('a video that failed is tried again after a while, or once its failures are forgotten', () async {
    host.frameOf = (_) => null;
    final service = NetworkVideoThumbnailService(
      api: host,
      retryDelay: Duration.zero,
      retryFailedAfter: const Duration(milliseconds: 100),
    );

    expect(await service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4')), isNull);
    expect(await service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4')), isNull);
    expect(host.calls, hasLength(2), reason: 'not asked again right away');

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4')), isNull);
    expect(host.calls, hasLength(4));

    service.forgetFailures();
    host.frameOf = FakeVideoThumbnailHost().frameOf;
    expect(await service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4')), isNotNull);
    expect(host.calls, hasLength(5));
  });

  test('a host that does not answer in time gives no frame, and its turn goes to the next video', () async {
    host.gated = true;
    final service = NetworkVideoThumbnailService(
      api: host,
      maxConcurrent: 1,
      timeout: const Duration(milliseconds: 10),
      retryDelay: Duration.zero,
    );

    expect(await service.thumbnail(videoKey('/slow.mp4'), bridgeUrl('/slow.mp4')), isNull);
    expect(host.calls, hasLength(2));

    host.gated = false;
    expect(await service.thumbnail(videoKey('/next.mp4'), bridgeUrl('/next.mp4')), isNotNull);
  });

  test('works without a disk cache', () async {
    final service = NetworkVideoThumbnailService(api: host);

    expect(await service.thumbnail(videoKey('/trip.mp4'), bridgeUrl('/trip.mp4')), isNotNull);
  });

  test('takes the frames after the photo thumbnails, two at a time, in the order asked', () async {
    host.gated = true;
    final photos = Completer<void>();
    final service = NetworkVideoThumbnailService(api: host, waitForPhotos: () => photos.future);
    final paths = ['/a.mp4', '/b.mp4', '/c.mp4', '/d.mp4'];
    final results = <String, Uint8List?>{};
    for (final path in paths) {
      unawaited(service.thumbnail(videoKey(path), bridgeUrl(path)).then((bytes) => results[path] = bytes));
    }

    await settle();
    expect(host.calls, isEmpty, reason: 'the photos first');

    photos.complete();
    await settle();
    expect(host.urls, ['/a.mp4', '/b.mp4'].map((path) => bridgeUrl(path).toString()));

    host.answer(bridgeUrl('/b.mp4').toString());
    await settle();
    expect(host.urls.last, bridgeUrl('/c.mp4').toString());
    expect(host.inFlight, 2);

    host.answer(bridgeUrl('/a.mp4').toString());
    await settle();
    host.answer(bridgeUrl('/c.mp4').toString());
    host.answer(bridgeUrl('/d.mp4').toString());
    await settle();

    expect(host.urls, paths.map((path) => bridgeUrl(path).toString()));
    expect(host.maxInFlight, 2);
    expect(results.keys.toSet(), paths.toSet());
    expect(results.values, everyElement(isNotNull));
  });

  test('skips a video no longer wanted when its turn comes, and takes it when asked again', () async {
    host.gated = true;
    final service = NetworkVideoThumbnailService(api: host, maxConcurrent: 1);
    var wanted = true;

    final first = service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4'));
    final gone = service.thumbnail(videoKey('/b.mp4'), bridgeUrl('/b.mp4'), isWanted: () => wanted);
    await settle();
    wanted = false;
    host.answer(bridgeUrl('/a.mp4').toString());

    expect(await first, isNotNull);
    expect(await gone, isNull);
    expect(host.urls, [bridgeUrl('/a.mp4').toString()]);

    host.gated = false;
    expect(await service.thumbnail(videoKey('/b.mp4'), bridgeUrl('/b.mp4')), isNotNull, reason: 'not a failure');
  });

  test('takes the frame once for tiles asking for the same video meanwhile', () async {
    host.gated = true;
    final service = NetworkVideoThumbnailService(api: host);

    final one = service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4'), isWanted: () => false);
    final two = service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4'), isWanted: () => true);
    await settle();
    host.answer(bridgeUrl('/a.mp4').toString());

    expect(await one, isNotNull, reason: 'the second tile still wants it');
    expect(await two, await one);
    expect(host.calls, hasLength(1));
  });

  test('keeps at most the bytes allowed on disk, the frames used the longest ago going first', () async {
    // Each fake frame is some 40 bytes: room for two
    final service = NetworkVideoThumbnailService(api: host, diskCache: diskCache(maxBytes: 100));

    await service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4'));
    await service.thumbnail(videoKey('/b.mp4'), bridgeUrl('/b.mp4'));
    // Shown again: used more recently than b
    await service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4'));
    await service.thumbnail(videoKey('/c.mp4'), bridgeUrl('/c.mp4'));
    expect(host.calls, hasLength(3));

    await service.thumbnail(videoKey('/a.mp4'), bridgeUrl('/a.mp4'));
    await service.thumbnail(videoKey('/c.mp4'), bridgeUrl('/c.mp4'));
    expect(host.calls, hasLength(3), reason: 'a and c kept');

    await service.thumbnail(videoKey('/b.mp4'), bridgeUrl('/b.mp4'));
    expect(host.calls, hasLength(4), reason: 'b dropped');
  });
}
