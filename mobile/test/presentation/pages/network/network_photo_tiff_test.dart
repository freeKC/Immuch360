// A TIFF of a share on a device without TIFF decoder (fix-tiff-android, the Meta Quest of 31 October 2026): the
// engine's decoder refused it ("Could not open this file: Exception: Invalid image data"), and every widget that
// resolved it again read the whole file through the media bridge and failed again. Now the page and the tiles decode
// it in Dart, say so while they do, say "This device cannot decode this TIFF" when it does not decode, and read it
// once in the session. Against a tiny HTTP server standing in for the media bridge, with real requests.

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
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_tiff.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import 'network_viewer_fakes.dart';

class _QuestApi extends ImmersiveApi {
  /// The URLs the immersive viewer was asked to open
  final List<String> opened = [];

  @override
  Future<bool> isHorizonOs() async => true;

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    ImmersiveSphereCoverage coverage,
    int startPositionMs,
    int openingId,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair,
    bool reverseThumbstickTurn,
    bool sharpFlatScreens, {
    String? kiosk,
    String? sourceNotice,
    String? sourceRefusal,
    bool gaussianSplats = true,
  }) async => opened.add(url);
}

class _NoRecords extends UploadRecordStore {
  _NoRecords() : super(() => throw UnimplementedError('in memory'));

  @override
  Future<Map<String, UploadRecord>> load() async => {};

  @override
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt, bool inTrash = false}) async {}
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

/// A TIFF of [width] by [height] pixels, as a scanner or an editor writes one
Uint8List _tiff(int width, int height) => Uint8List.fromList(img.encodeTiff(img.Image(width: width, height: height)));

/// The header of a TIFF and nothing the decoders read after it
final _brokenTiff = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, ...List.filled(200, 0x41)]);

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late TestMediaServer server;
  late _QuestApi quest;
  late Directory jpegs;
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
    quest = _QuestApi();
    jpegs = Directory.systemTemp.createTempSync('share_tiff_jpeg_');
    UndecodablePhotos.instance.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
    jpegs.deleteSync(recursive: true);
  });

  /// The requests of the whole file at [path], not its ranges (the GPano tags, the versions)
  int wholeReads(String path) =>
      server.requests.where((request) => request.path == path && request.range == null).length;

  List<Override> overrides() => [
    storeServiceProvider.overrideWithValue(store),
    overrideConnections((ref) => FakeConnections(ref, share, baseUrl: server.baseUrl)),
    isHorizonOsProvider.overrideWith((ref) async => true),
    immersiveApiProvider.overrideWithValue(quest),
    tiffJpegCacheProvider.overrideWithValue(TiffJpegCache(() async => jpegs)),
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

  /// Real time for the bridge and the decoder, frames for the page
  Future<void> run(WidgetTester tester, {int turns = 60}) async {
    for (var turn = 0; turn < turns; turn++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  bool showsDecodedPhoto() =>
      find.byWidgetPredicate((widget) => widget is RawImage && widget.image != null).evaluate().isNotEmpty;

  Finder engineError() => find.textContaining('Invalid image data');

  testWidgets('a TIFF of a share shows on the device, decoded once, without the error of the engine', (tester) async {
    share.files['/Scans/plan.tif'] = _tiff(64, 32);
    await pumpPhotoPage(tester, '/Scans/plan.tif');
    await pumpRealIo(tester, showsDecodedPhoto);

    expect(showsDecodedPhoto(), isTrue);
    expect(engineError(), findsNothing);
    expect(find.textContaining('Could not open this file'), findsNothing);
    expect(wholeReads('/Scans/plan.tif'), 1);

    await endRealIo(tester);
  });

  testWidgets('while the TIFF comes and decodes, the page says it is decoded on this device', (tester) async {
    share.files['/plan.tif'] = _tiff(64, 32);
    final gate = server.gate = Completer<void>();
    await pumpPhotoPage(tester, '/plan.tif');
    await pumpRealIo(tester, () => wholeReads('/plan.tif') == 1);
    await run(tester, turns: 5);

    expect(find.text('Decoding the TIFF on this device'), findsOneWidget);

    gate.complete();
    await pumpRealIo(tester, showsDecodedPhoto);
    expect(showsDecodedPhoto(), isTrue);
    expect(find.text('Decoding the TIFF on this device'), findsNothing);

    await endRealIo(tester);
  });

  testWidgets('a TIFF that does not decode says so, and is read once: not again for a new density nor a new page', (
    tester,
  ) async {
    share.files['/broken.tif'] = _brokenTiff;
    await pumpPhotoPage(tester, '/broken.tif');
    await pumpRealIo(tester, () => find.text('This device cannot decode this TIFF').evaluate().isNotEmpty);

    expect(find.text('This device cannot decode this TIFF'), findsOneWidget);
    expect(engineError(), findsNothing);
    expect(wholeReads('/broken.tif'), 1);

    // Whatever resolves the photo again (here the density of the window, as a widget of the image does) gets the
    // failure at once, without the file
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    await run(tester);
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await run(tester);
    expect(wholeReads('/broken.tif'), 1);
    expect(find.text('This device cannot decode this TIFF'), findsOneWidget);

    // The page opened again
    await tester.pumpWidget(const SizedBox());
    await pumpPhotoPage(tester, '/broken.tif');
    await run(tester);
    expect(find.text('This device cannot decode this TIFF'), findsOneWidget);
    expect(wholeReads('/broken.tif'), 1);

    await endRealIo(tester);
  });

  testWidgets('the tiles of a folder decode its TIFFs, and read one that does not decode once in the session', (
    tester,
  ) async {
    share.files['/Scans/good.tif'] = _tiff(64, 32);
    share.files['/Scans/broken.tif'] = _brokenTiff;
    share.folders['/Scans'] = [share.file('/Scans/good.tif'), share.file('/Scans/broken.tif')];
    Future<void> pumpFolder() => pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: _source.id, path: '/Scans'),
      settle: false,
      overrides: overrides(),
    );
    await pumpFolder();
    await pumpRealIo(tester, () => wholeReads('/Scans/broken.tif') == 1 && showsDecodedPhoto());
    await run(tester, turns: 20);

    expect(showsDecodedPhoto(), isTrue, reason: 'the good TIFF shows in its tile');
    expect(wholeReads('/Scans/good.tif'), 1);
    expect(wholeReads('/Scans/broken.tif'), 1);

    // The folder opened again, and the density changed: the broken one is not read again
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await pumpFolder();
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    await run(tester);
    expect(wholeReads('/Scans/broken.tif'), 1);

    // Nor by its page
    await tester.pumpWidget(const SizedBox());
    await pumpPhotoPage(tester, '/Scans/broken.tif');
    await run(tester);
    expect(find.text('This device cannot decode this TIFF'), findsOneWidget);
    expect(wholeReads('/Scans/broken.tif'), 1);

    await endRealIo(tester);
  });

  testWidgets('a JPEG of a share keeps the decoder of the engine', (tester) async {
    share.files['/beach.jpg'] = Uint8List.fromList(img.encodeJpg(img.Image(width: 64, height: 32)));
    await pumpPhotoPage(tester, '/beach.jpg');
    await pumpRealIo(tester, showsDecodedPhoto);

    expect(showsDecodedPhoto(), isTrue);
    expect(networkPhotoImage(server.urlOf('/beach.jpg')), isA<ResizeImage>());
    expect(networkPhotoImage(server.urlOf('/plan.TIFF')), isNot(isA<ResizeImage>()));

    await endRealIo(tester);
  });

  group('on a Meta Quest, whose immersive viewer decodes no TIFF', () {
    Future<void> openAs360(WidgetTester tester) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('View as 360°'));
      await tester.pump();
    }

    testWidgets('opens a TIFF of a share from a JPEG of the cache, made once, said while it is made', (tester) async {
      share.files['/pano.tif'] = _tiff(128, 64);
      await pumpPhotoPage(tester, '/pano.tif');
      await pumpRealIo(tester, showsDecodedPhoto);

      await openAs360(tester);
      await pumpRealIo(tester, () => quest.opened.isNotEmpty);
      expect(find.text('Decoding the TIFF on this device'), findsOneWidget);
      expect(quest.opened.single, startsWith('file://'));
      final jpeg = File.fromUri(Uri.parse(quest.opened.single)).readAsBytesSync();
      expect(jpeg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);

      // Opened again: the same JPEG, the file not read again for it
      final reads = wholeReads('/pano.tif');
      await tester.pump(const Duration(seconds: 6));
      await openAs360(tester);
      await pumpRealIo(tester, () => quest.opened.length == 2);
      expect(quest.opened.last, quest.opened.first);
      expect(wholeReads('/pano.tif'), reads);

      await endRealIo(tester);
    });

    testWidgets('a TIFF that does not decode says so instead of opening the viewer', (tester) async {
      share.files['/broken.tif'] = _brokenTiff;
      await pumpPhotoPage(tester, '/broken.tif');
      await pumpRealIo(tester, () => find.text('This device cannot decode this TIFF').evaluate().isNotEmpty);

      await openAs360(tester);
      await run(tester);
      expect(quest.opened, isEmpty);
      expect(find.text('This device cannot decode this TIFF'), findsWidgets);
      expect(wholeReads('/broken.tif'), 1, reason: 'known not to decode: not read again for the viewer');

      await endRealIo(tester);
    });
  });
}
