// The photos of a share on Android that the engine has no codec of its own for (crash M1 of the Meta Quest store,
// 8 November 2026): a HEIC or a DNG of a share went whole to the engine, which decoded it at its full size with its
// fallback decoder and aborted the app on an OutOfMemoryError. Now the tiles, the photo page and the 360° view decode
// them with the native decoder within their own bounds, a JPEG stays with the engine, and a file the native decoder
// cannot decode shows the error view, read once in the session. Against a tiny HTTP server standing in for the media
// bridge, with real requests, and a stand in for the native decoder.

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';
import 'package:immich_mobile/presentation/widgets/network/network_tiff_image.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../widgets/images/guarded_image_fakes.dart';
import 'network_viewer_fakes.dart';

class _NoRecords extends UploadRecordStore {
  _NoRecords() : super(() => throw UnimplementedError('in memory'));

  @override
  Future<Map<String, UploadRecord>> load() async => {};

  @override
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt, bool inTrash = false}) async {}
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

/// A JPEG of [width] by [height] pixels
Uint8List _jpeg(int width, int height) => Uint8List.fromList(img.encodeJpg(img.Image(width: width, height: height)));

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late TestMediaServer server;
  late FakeNativeDecoder native;
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

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
    share = MemoryShare(_source);
    server.share = share;
    server.requests.clear();
    server.gate = null;
    native = FakeNativeDecoder();
    nativeImageDecodeApi = native;
    UndecodablePhotos.instance.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDown(() async {
    nativeImageDecodeApi = NativeImageDecodeApi();
    await store.dispose();
    await db.close();
  });

  /// The requests of the whole file at [path], not its ranges (the GPano tags, the stereo pairs)
  int wholeReads(String path) =>
      server.requests.where((request) => request.path == path && request.range == null).length;

  List<Override> overrides() => [
    storeServiceProvider.overrideWithValue(store),
    overrideConnections((ref) => FakeConnections(ref, share, baseUrl: server.baseUrl)),
    isHorizonOsProvider.overrideWith((ref) async => false),
    networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
    appConfigProvider.overrideWithValue(const AppConfig()),
    uploadRecordStoreProvider.overrideWithValue(_NoRecords()),
  ];

  Future<void> pumpPhotoPage(WidgetTester tester, String path) => pumpNetworkRouter(
    tester,
    home: NetworkPhotoPage(sourceId: _source.id, path: path),
    settle: false,
    overrides: overrides(),
  );

  /// Real time for the bridge and the decoders, frames for the page
  Future<void> run(WidgetTester tester, {int turns = 40}) async {
    for (var turn = 0; turn < turns; turn++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Iterable<RawImage> decodedPhotos() =>
      find.byType(RawImage).evaluate().map((element) => element.widget as RawImage).where((raw) => raw.image != null);

  bool showsDecodedPhoto() => decodedPhotos().isNotEmpty;

  Finder errorView() => find.textContaining('Could not open');

  testWidgets('the tiles of a folder of HEIC and DNG photos decode them natively at 800 pixels, each read once', (
    tester,
  ) async {
    share.files['/Photos/IMG_0001.HEIC'] = heic;
    share.files['/Photos/DSC_0002.DNG'] = dng;
    share.files['/Photos/beach.jpg'] = _jpeg(64, 32);
    share.folders['/Photos'] = [
      share.file('/Photos/IMG_0001.HEIC'),
      share.file('/Photos/DSC_0002.DNG'),
      share.file('/Photos/beach.jpg'),
    ];
    await pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: _source.id, path: '/Photos'),
      settle: false,
      overrides: overrides(),
    );
    await pumpRealIo(tester, () => native.calls.length == 2 && decodedPhotos().length == 3);
    await run(tester, turns: 10);

    expect(decodedPhotos(), hasLength(3), reason: 'the three tiles show their photo');
    expect(native.calls.map((call) => (call.kind, call.maxWidth, call.maxHeight)), unorderedEquals([
      (EncodedImageKind.heif, 800, 800),
      (EncodedImageKind.tiff, 800, 800),
    ]));
    for (final path in ['/Photos/IMG_0001.HEIC', '/Photos/DSC_0002.DNG', '/Photos/beach.jpg']) {
      expect(wholeReads(path), 1, reason: path);
    }

    await endRealIo(tester);
  });

  testWidgets('the page decodes a HEIC natively at 4096 pixels, a JPEG with the engine as before', (tester) async {
    share.files['/IMG_0001.HEIC'] = heic;
    await pumpPhotoPage(tester, '/IMG_0001.HEIC');
    await pumpRealIo(tester, showsDecodedPhoto);

    expect(showsDecodedPhoto(), isTrue);
    expect(errorView(), findsNothing);
    expect(native.calls.single.kind, EncodedImageKind.heif);
    expect((native.calls.single.maxWidth, native.calls.single.maxHeight), (4096, 4096));
    expect(wholeReads('/IMG_0001.HEIC'), 1);

    await tester.pumpWidget(const SizedBox());
    share.files['/beach.jpg'] = _jpeg(64, 32);
    await pumpPhotoPage(tester, '/beach.jpg');
    await pumpRealIo(tester, showsDecodedPhoto);

    final photo = decodedPhotos().single.image!;
    expect((photo.width, photo.height), (64, 32));
    expect(native.calls, hasLength(1), reason: 'the JPEG is not for the native decoder');

    await endRealIo(tester);
  });

  testWidgets('the 360° view decodes a HEIC natively within 8191 x 4095, 4095 x 2047 on a TV of little memory', (
    tester,
  ) async {
    share.files['/pano.heic'] = heic;
    Future<Object?> resolve(ImageProvider image) async {
      final done = Completer<Object?>();
      final stream = image.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (info, _) {
          if (!done.isCompleted) {
            done.complete(info.image.width);
          }
          info.dispose();
        },
        onError: (error, _) {
          if (!done.isCompleted) {
            done.complete(error);
          }
        },
      );
      stream.addListener(listener);
      await pumpRealIo(tester, () => done.isCompleted);
      stream.removeListener(listener);
      return done.isCompleted ? await done.future : null;
    }

    expect(await resolve(networkPanoramaImage(server.urlOf('/pano.heic'))), isA<int>());
    expect(await resolve(networkPanoramaImage(server.urlOf('/pano.heic'), lowRam: true)), isA<int>());

    expect(native.calls.map((call) => (call.maxWidth, call.maxHeight)), [(8191, 4095), (4095, 2047)]);

    await endRealIo(tester);
  });

  testWidgets('a photo the native decoder cannot decode shows the error view, and is read once in the session', (
    tester,
  ) async {
    native.error = outOfMemory();
    share.files['/huge.heic'] = heic;
    await pumpPhotoPage(tester, '/huge.heic');
    await pumpRealIo(tester, () => errorView().evaluate().isNotEmpty);

    expect(errorView(), findsOneWidget);
    expect(wholeReads('/huge.heic'), 1);
    expect(native.calls, hasLength(1));
    expect(
      UndecodablePhotos.instance.failureOf(undecodableShareKey(server.urlOf('/huge.heic'))),
      isNotNull,
      reason: 'the tile and the page share what did not decode',
    );

    // The page opened again: the error at once, the file not read again
    await tester.pumpWidget(const SizedBox());
    await pumpPhotoPage(tester, '/huge.heic');
    await run(tester);
    expect(errorView(), findsOneWidget);
    expect(wholeReads('/huge.heic'), 1);
    expect(native.calls, hasLength(1));

    await endRealIo(tester);
  });

  testWidgets('a file that is no image of this device shows the error view without any decoder', (tester) async {
    share.files['/page.jpg'] = Uint8List.fromList('<!DOCTYPE html><html><body>Not found</body></html>'.codeUnits);
    await pumpPhotoPage(tester, '/page.jpg');
    await pumpRealIo(tester, () => errorView().evaluate().isNotEmpty);

    expect(errorView(), findsOneWidget);
    expect(native.calls, isEmpty);
    expect(networkPhotoImage(server.urlOf('/page.jpg')), isA<GuardedNetworkImage>());

    await endRealIo(tester);
  });
}
