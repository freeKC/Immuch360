// The photo page against a tiny HTTP server standing in for the media bridge: the photo and its GPano tags come from
// it, with real HTTP requests.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import 'network_viewer_fakes.dart';

/// Records what the immersive viewer is asked to open
class _RecordingImmersiveApi extends ImmersiveApi {
  final List<Map<String, Object?>> opened = [];

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
  ) async {
    opened.add({'url': url, 'isVideo': isVideo, 'title': title, 'layout': stereoLayout, 'coverage': coverage});
  }
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late TestMediaServer server;
  HttpOverrides? previousOverrides;
  // A real PNG, 64 x 32 pixels, decoded by the engine
  late Uint8List png;

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
    // Each test has its own image cache entries: the URLs are the same from one test to the next
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<Uint8List> makePng(WidgetTester tester) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: 64, height: 32);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    return bytes!;
  }

  Future<void> pumpPhotoPage(WidgetTester tester, String path, {_RecordingImmersiveApi? immersiveApi}) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkPhotoPage(sourceId: _source.id, path: path),
      settle: false,
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share, baseUrl: server.baseUrl)),
        isHorizonOsProvider.overrideWith((ref) async => immersiveApi != null),
        if (immersiveApi != null) immersiveApiProvider.overrideWithValue(immersiveApi),
        // A fresh cache per test
        networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
      ],
    );
  }

  /// A PNG with GPano tags after its end, where the GPano window still finds them and decoders do not look
  Uint8List withXmp(Uint8List image, String xmp) => Uint8List.fromList([...image, ...ascii.encode(xmp)]);

  bool shows360Button() => find.byTooltip('360°').evaluate().isNotEmpty;

  bool showsDecodedPhoto() =>
      find.byWidgetPredicate((widget) => widget is RawImage && widget.image != null).evaluate().isNotEmpty;

  testWidgets('shows the photo from the media bridge, with a 360° button when it declares a 360° projection', (
    tester,
  ) async {
    png = await makePng(tester);
    share.files['/pano.png'] = withXmp(png, equirectangularXmp);
    await pumpPhotoPage(tester, '/pano.png');
    await pumpRealIo(tester, () => shows360Button() && showsDecodedPhoto());

    expect(find.text('pano.png'), findsOneWidget);
    expect(showsDecodedPhoto(), isTrue);
    expect(find.byTooltip('360°'), findsOneWidget);
    expect(
      server.requests.where((request) => request.range != null).map((request) => request.path),
      contains('/pano.png'),
      reason: 'the GPano tags are read with range requests',
    );
    expect(
      server.requests.where((request) => request.range == null).map((request) => request.path),
      contains('/pano.png'),
      reason: 'the photo itself comes whole',
    );

    await endRealIo(tester);
  });

  testWidgets('opens the 360° viewer on the photo, with its GPano tags read through the media bridge', (tester) async {
    png = await makePng(tester);
    share.files['/pano.png'] = withXmp(png, equirectangularXmp);
    await pumpPhotoPage(tester, '/pano.png');
    await pumpRealIo(tester, shows360Button);

    await tester.tap(find.byTooltip('360°'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final viewer = tester.widget<PanoramaViewerPage>(find.byType(PanoramaViewerPage));
    expect(viewer.asset, isNull);
    final source = viewer.source!;
    expect(source.name, 'pano.png');
    expect(source.length, share.files['/pano.png']!.length);
    expect(source.image, networkPanoramaImage(server.urlOf('/pano.png')));
    final xmp = String.fromCharCodes((await tester.runAsync(() => source.read!(0, 131072)))!);
    expect(xmp, contains('GPano:ProjectionType="equirectangular"'));

    // The sphere shows once the image is decoded and the GPano tags read
    await pumpRealIo(tester, () => find.byTooltip('Field of view').evaluate().isNotEmpty);
    expect(find.byTooltip('Field of view'), findsOneWidget);
    expect(find.text('360°'), findsOneWidget, reason: 'a 2:1 photo with no other sign: the whole sphere');

    await endRealIo(tester);
  });

  testWidgets('offers any photo as 360° from the menu', (tester) async {
    png = await makePng(tester);
    share.files['/flat.png'] = png;
    await pumpPhotoPage(tester, '/flat.png');
    await pumpRealIo(tester, showsDecodedPhoto);
    // The read of the GPano tags found nothing
    await pumpRealIo(tester, () => server.requests.any((request) => request.range != null));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.byTooltip('360°'), findsNothing);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View as 360°'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PanoramaViewerPage), findsOneWidget);
    expect(tester.widget<PanoramaViewerPage>(find.byType(PanoramaViewerPage)).source?.name, 'flat.png');

    await endRealIo(tester);
  });

  testWidgets('on a Meta Quest, opens the photo in the immersive viewer from the media bridge', (tester) async {
    final immersiveApi = _RecordingImmersiveApi();
    png = await makePng(tester);
    share.files['/vr180_trip.png'] = withXmp(png, equirectangularXmp);
    await pumpPhotoPage(tester, '/vr180_trip.png', immersiveApi: immersiveApi);
    await pumpRealIo(tester, () => shows360Button() && showsDecodedPhoto());

    await tester.tap(find.byTooltip('360°'));
    await tester.pump();

    expect(find.byType(PanoramaViewerPage), findsNothing);
    expect(immersiveApi.opened, [
      {
        'url': server.urlOf('/vr180_trip.png').toString(),
        'isVideo': false,
        'title': 'vr180_trip.png',
        // A 2:1 frame named VR180: two square eyes side by side over the front half of the sphere
        'layout': ImmersiveStereoLayout.leftRight,
        'coverage': ImmersiveSphereCoverage.half,
      },
    ]);

    await endRealIo(tester);
  });

  testWidgets('tells why the photo could not be opened, and tries again', (tester) async {
    png = await makePng(tester);
    share.files['/pano.png'] = png;
    share.error = const NetworkFileSystemException('nas does not answer');
    await pumpPhotoPage(tester, '/pano.png');
    await pumpRealIo(tester, () => find.textContaining('Could not open this file').evaluate().isNotEmpty);

    expect(find.text('Could not open this file: nas does not answer'), findsOneWidget);

    share.error = null;
    await tester.tap(find.text('Retry'));
    await pumpRealIo(tester, showsDecodedPhoto);

    expect(find.textContaining('Could not open this file'), findsNothing);
    expect(showsDecodedPhoto(), isTrue);

    await endRealIo(tester);
  });

  testWidgets('tells a photo the media bridge cannot serve', (tester) async {
    png = await makePng(tester);
    share.files['/gone.png'] = png;
    // Gone from the share between the stat and the read: the media bridge answers 404
    server.share = MemoryShare(_source);
    await pumpPhotoPage(tester, '/gone.png');
    await pumpRealIo(tester, () => find.textContaining('Could not open this file').evaluate().isNotEmpty);

    expect(find.text('Could not open this file: HTTP 404'), findsOneWidget);

    await endRealIo(tester);
  });
}
