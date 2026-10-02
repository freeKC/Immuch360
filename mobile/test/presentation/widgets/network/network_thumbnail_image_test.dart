// The photo thumbnails of the network share browser, against a tiny HTTP server standing in for the media bridge.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';

import '../../pages/network/network_viewer_fakes.dart';

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

void main() {
  late MemoryShare share;
  late TestMediaServer server;
  HttpOverrides? previousOverrides;

  setUpAll(() async {
    // Real HTTP to the test server: the widget tests answer every request with an error otherwise
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    share = MemoryShare(_source);
    server = await TestMediaServer.start(share);
  });

  tearDownAll(() async {
    await server.close();
    HttpOverrides.global = previousOverrides;
  });

  setUp(() {
    share = MemoryShare(_source);
    server
      ..share = share
      ..gate = null
      ..maxInFlight = 0
      ..requests.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  Future<Uint8List> png(WidgetTester tester, int width, int height) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: width, height: height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    return bytes!;
  }

  /// Loads [image], and gives what came: the size of the image, or the error
  Future<Object?> load(WidgetTester tester, ImageProvider image) async {
    Object? result;
    final stream = image.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      result = Size(info.image.width.toDouble(), info.image.height.toDouble());
      info.dispose();
    }, onError: (error, _) => result = error);
    stream.addListener(listener);
    await pumpRealIo(tester, () => result != null);
    stream.removeListener(listener);
    return result;
  }

  testWidgets('decodes a photo of the share at most 400 pixels wide, from the media bridge', (tester) async {
    share.files['/large.png'] = await png(tester, 800, 400);
    share.files['/small.png'] = await png(tester, 64, 32);

    expect(await load(tester, NetworkThumbnailImage(server.urlOf('/large.png'))), const Size(400, 200));
    expect(await load(tester, NetworkThumbnailImage(server.urlOf('/small.png'))), const Size(64, 32));
    expect(server.requests.map((request) => (request.path, request.range)), [
      ('/large.png', null),
      ('/small.png', null),
    ]);

    await endRealIo(tester);
  });

  testWidgets('tells a photo the media bridge cannot serve, and asks again next time', (tester) async {
    final image = NetworkThumbnailImage(server.urlOf('/gone.png'));

    final error = await load(tester, image);
    await tester.pump();

    expect(error, isA<NetworkImageLoadException>().having((e) => e.statusCode, 'statusCode', 404));
    expect(PaintingBinding.instance.imageCache.containsKey(image), isFalse);

    share.files['/gone.png'] = await png(tester, 64, 32);
    expect(await load(tester, image), const Size(64, 32));

    await endRealIo(tester);
  });

  testWidgets('loads a few photos at a time', (tester) async {
    for (var i = 0; i < 6; i++) {
      share.files['/$i.png'] = await png(tester, 16, 16);
    }
    server.gate = Completer<void>();
    final sizes = <Size>[];
    final streams = [
      for (var i = 0; i < 6; i++) NetworkThumbnailImage(server.urlOf('/$i.png')).resolve(ImageConfiguration.empty),
    ];
    final listener = ImageStreamListener((info, _) {
      sizes.add(Size(info.image.width.toDouble(), info.image.height.toDouble()));
      info.dispose();
    });
    for (final stream in streams) {
      stream.addListener(listener);
    }

    await pumpRealIo(tester, () => server.inFlight == NetworkThumbnailImage.maxConcurrent);
    // Time for more requests, were there any
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(server.requests, hasLength(NetworkThumbnailImage.maxConcurrent));

    server.gate!.complete();
    await pumpRealIo(tester, () => sizes.length == 6);

    expect(sizes, hasLength(6));
    expect(server.maxInFlight, NetworkThumbnailImage.maxConcurrent);
    for (final stream in streams) {
      stream.removeListener(listener);
    }

    await endRealIo(tester);
  });

  testWidgets('tells when no photo thumbnail is loading any more, for the video frames to come after', (tester) async {
    share.files['/a.png'] = await png(tester, 16, 16);
    share.files['/b.png'] = await png(tester, 16, 16);
    server.gate = Completer<void>();
    var loaded = 0;
    final listener = ImageStreamListener((info, _) {
      loaded++;
      info.dispose();
    });
    final streams = [
      for (final path in ['/a.png', '/b.png'])
        NetworkThumbnailImage(server.urlOf(path)).resolve(ImageConfiguration.empty)..addListener(listener),
    ];
    var idle = false;
    unawaited(NetworkThumbnailImage.whenIdle().then((_) => idle = true));

    await pumpRealIo(tester, () => server.inFlight == 2);
    // The end of the frame under way, whose photos it waits for too
    await tester.pump(Duration.zero);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(idle, isFalse);

    server.gate!.complete();
    await pumpRealIo(tester, () => idle);
    expect(idle, isTrue);
    await pumpRealIo(tester, () => loaded == 2);
    expect(loaded, 2);
    for (final stream in streams) {
      stream.removeListener(listener);
    }

    var idleAgain = false;
    unawaited(NetworkThumbnailImage.whenIdle().then((_) => idleAgain = true));
    await tester.pump(Duration.zero);
    expect(idleAgain, isTrue, reason: 'nothing loading');

    await endRealIo(tester);
  });

  group('NetworkVideoThumbnailImage', () {
    const key = (sourceId: 'nas', path: '/trip.mp4', size: 1000, modified: null);

    testWidgets('decodes the frame of a video at most 400 pixels wide', (tester) async {
      final bytes = await png(tester, 800, 400);

      expect(await load(tester, NetworkVideoThumbnailImage(key, bytes: bytes)), const Size(400, 200));
      expect(NetworkVideoThumbnailImage.isInMemory(key), isTrue);
      expect(const NetworkVideoThumbnailImage(key), NetworkVideoThumbnailImage(key, bytes: bytes), reason: 'by video');

      await endRealIo(tester);
    });

    testWidgets('fails without its bytes, and leaves the image cache', (tester) async {
      final error = await load(tester, const NetworkVideoThumbnailImage(key));
      await tester.pump();

      expect(error, isA<StateError>());
      expect(NetworkVideoThumbnailImage.isInMemory(key), isFalse);

      await endRealIo(tester);
    });
  });
}
