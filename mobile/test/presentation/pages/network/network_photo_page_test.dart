// The photo page against a tiny HTTP server standing in for the media bridge: the photo and its GPano tags come from
// it, with real HTTP requests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_button.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../../fixtures/raw/insta360.stub.dart';
import '../../widgets/ai_immersive/quest_relief_fakes.dart';
import 'network_viewer_fakes.dart';

/// Records what the immersive viewer is asked to open
class _RecordingImmersiveApi extends ImmersiveApi {
  final List<Map<String, Object?>> opened = [];

  /// Where each media opened was asked to start, in milliseconds
  final List<int> startPositions = [];

  /// The opening ids the viewer was given, which it sends back with its events
  final List<int> openingIds = [];

  /// The stereoPair JSON of each media opened, null for any but an Apple spatial photo
  final List<String?> stereoPairs = [];

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
  ) async {
    opened.add({'url': url, 'isVideo': isVideo, 'title': title, 'layout': stereoLayout, 'coverage': coverage});
    startPositions.add(startPositionMs);
    openingIds.add(openingId);
    stereoPairs.add(stereoPair);
  }

  /// What the viewer was asked to show in place, for previous and next
  final List<Map<String, Object?>> shown = [];

  @override
  Future<bool> showAdjacent(
    int requestId,
    String url,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair,
  ) async {
    shown.add({'url': url, 'isVideo': isVideo, 'title': title, 'layout': stereoLayout, 'coverage': coverage});
    return true;
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

  Future<void> pumpPhotoPage(
    WidgetTester tester,
    String path, {
    _RecordingImmersiveApi? immersiveApi,
    NetworkFolderMedia? folder,
    List<Override> extraOverrides = const [],
  }) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkPhotoPage(sourceId: _source.id, path: path, folder: folder),
      settle: false,
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share, baseUrl: server.baseUrl)),
        isHorizonOsProvider.overrideWith((ref) async => immersiveApi != null),
        if (immersiveApi != null) immersiveApiProvider.overrideWithValue(immersiveApi),
        appConfigProvider.overrideWithValue(const AppConfig()),
        // A fresh cache per test
        networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
        ...extraOverrides,
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

  testWidgets('a photo renamed from .insp gets a 360° button, and the viewer stitches it with its calibration', (
    tester,
  ) async {
    png = await makePng(tester);
    share.files['/IMG_20240908_133036_00_001.jpg'] = insta360File([
      insta360Record(1, x3Metadata(), format: 1),
    ], body: png);
    await pumpPhotoPage(tester, '/IMG_20240908_133036_00_001.jpg');
    await pumpRealIo(tester, shows360Button);

    await tester.tap(find.byTooltip('360°'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final label = find.text('Raw 360° file, stitched by the app (lens calibration read from the file)');
    await pumpRealIo(tester, () => label.evaluate().isNotEmpty);

    expect(label, findsOneWidget);
    expect(find.byTooltip('Field of view'), findsNothing, reason: 'a stitch covers the whole sphere');

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

  testWidgets('on a Meta Quest, the immersive viewer goes to the next 360° photo of the folder', (tester) async {
    final immersiveApi = _RecordingImmersiveApi();
    png = await makePng(tester);
    share.files['/vr180_trip.png'] = withXmp(png, equirectangularXmp);
    share.files['/flat.png'] = png;
    share.files['/pano.png'] = withXmp(png, equirectangularXmp);
    final entries = [
      for (final path in ['/vr180_trip.png', '/flat.png', '/pano.png']) share.file(path),
    ];
    final folder = NetworkFolderMedia(
      entries: entries,
      urls: {for (final entry in entries) entry.path: server.urlOf(entry.path)},
      index: 0,
    );
    await pumpPhotoPage(tester, '/vr180_trip.png', immersiveApi: immersiveApi, folder: folder);
    await pumpRealIo(tester, () => shows360Button() && showsDecodedPhoto());
    await tester.tap(find.byTooltip('360°'));
    await tester.pump();

    final session = ProviderScope.containerOf(
      tester.element(find.byType(NetworkPhotoPage)),
    ).read(immersiveSessionProvider);
    bool? shown;
    unawaited(
      session
          .requestAdjacent(
            immersiveApi.openingIds.single,
            1,
            1,
            ImmersiveStereoLayout.mono,
            ImmersiveSphereCoverage.full,
          )
          .then((result) => shown = result),
    );
    await pumpRealIo(tester, () => shown != null);

    expect(shown, isTrue);
    expect(immersiveApi.opened.map((media) => media['title']), ['vr180_trip.png']);
    expect(immersiveApi.startPositions, [0]);
    expect(immersiveApi.shown.map((media) => media['title']), ['pano.png']);
    expect(immersiveApi.shown.single['url'], server.urlOf('/pano.png').toString());

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

  group('Apple spatial photos', () {
    // The head of an Apple ImageIO spatial photo (MIT licensed, see the note next to it), then zeros for its image data
    final spatialPhoto = Uint8List.fromList([
      ...File('test/fixtures/apple_spatial/udibr_fisheye_0S9A9186_head.bin').readAsBytesSync(),
      ...List.filled(200 * 1024, 0),
    ]);
    final view3dButton = find.byKey(const Key('apple_spatial_view_3d'));

    testWidgets('on a Meta Quest, "View in 3D" opens both eyes in the immersive viewer from the media bridge', (
      tester,
    ) async {
      final immersiveApi = _RecordingImmersiveApi();
      share.files['/IMG_0001.HEIC'] = spatialPhoto;
      await pumpPhotoPage(tester, '/IMG_0001.HEIC', immersiveApi: immersiveApi);
      await pumpRealIo(tester, () => view3dButton.evaluate().isNotEmpty);

      expect(find.byTooltip('View in 3D'), findsOneWidget);
      expect(find.byTooltip('360°'), findsNothing, reason: 'a spatial photo is no 360° photo');

      await tester.tap(view3dButton);
      await tester.pump();

      expect(immersiveApi.opened.single['url'], server.urlOf('/IMG_0001.HEIC').toString());
      expect(immersiveApi.opened.single['isVideo'], isFalse);
      final pair = jsonDecode(immersiveApi.stereoPairs.single!) as Map<String, dynamic>;
      expect(pair['kind'], 'heicStereoPair');
      expect(pair['leftItemId'], 37);
      expect(pair['rightItemId'], 74);
      expect(pair['pitmIdOffset'], 129);

      await endRealIo(tester);
    });

    testWidgets('on a phone, a spatial photo gets no "View in 3D" button', (tester) async {
      share.files['/IMG_0001.HEIC'] = spatialPhoto;
      await pumpPhotoPage(tester, '/IMG_0001.HEIC');
      await pumpRealIo(tester, () => server.requests.any((request) => request.range != null));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();

      expect(view3dButton, findsNothing);

      await endRealIo(tester);
    });
  });

  group('flat 3D photos', () {
    final view3dButton = find.byKey(const Key('apple_spatial_view_3d'));
    final versionButton = find.byKey(const Key('ai_immersive_view_3d_version'));

    /// Waits until the head of the photo was read through the media bridge, and a little more for the page
    Future<void> settleDetection(WidgetTester tester) async {
      await pumpRealIo(tester, () => server.requests.any((request) => request.range != null));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    testWidgets('on a Meta Quest, one of ours opens on the stereo quad from the media bridge, said to be estimated', (
      tester,
    ) async {
      final immersiveApi = _RecordingImmersiveApi();
      share.files['/salon_3D_LRF_Full_SBS.jpg'] = jpegFile(width: 8000, height: 3000, xmp: ourXmp());
      await pumpPhotoPage(tester, '/salon_3D_LRF_Full_SBS.jpg', immersiveApi: immersiveApi);
      await pumpRealIo(tester, () => view3dButton.evaluate().isNotEmpty);

      expect(find.byTooltip('View in 3D'), findsOneWidget);
      expect(find.byTooltip('360°'), findsNothing, reason: 'two eyes side by side are no 360° photo');
      expect(find.byKey(const Key('network_photo_rotate')), findsNothing, reason: 'the eyes stay where they are');

      await tester.tap(view3dButton);
      await pumpRealIo(tester, () => immersiveApi.opened.isNotEmpty);

      expect(immersiveApi.opened.single['url'], server.urlOf('/salon_3D_LRF_Full_SBS.jpg').toString());
      expect(immersiveApi.opened.single['title'], 'salon_3D_LRF_Full_SBS.jpg');
      expect(jsonDecode(immersiveApi.stereoPairs.single!), {
        'kind': 'sbsPhoto',
        'version': 1,
        'layout': 'leftRight',
        'eyes': 'full',
        'origin': 'estimatedDepth',
        'leftEye': 'original',
      });

      await endRealIo(tester);
    });

    testWidgets('on a Meta Quest, the file of another tool opens as its name says, without a word on its making', (
      tester,
    ) async {
      final immersiveApi = _RecordingImmersiveApi();
      share.files['/trip_LRF_Full_SBS.png'] = pngFile(width: 3000, height: 1000);
      await pumpPhotoPage(tester, '/trip_LRF_Full_SBS.png', immersiveApi: immersiveApi);
      await pumpRealIo(tester, () => view3dButton.evaluate().isNotEmpty);

      await tester.tap(view3dButton);
      await pumpRealIo(tester, () => immersiveApi.opened.isNotEmpty);

      expect(jsonDecode(immersiveApi.stereoPairs.single!), {
        'kind': 'sbsPhoto',
        'version': 1,
        'layout': 'leftRight',
        'eyes': 'full',
        'origin': 'unknown',
        'leftEye': 'unknown',
      });

      await endRealIo(tester);
    });

    testWidgets('on a Meta Quest, an original opens the 3D version a computer saved next to it', (tester) async {
      final immersiveApi = _RecordingImmersiveApi();
      png = await makePng(tester);
      share.files['/Photos/salon.jpg'] = png;
      share.files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = jpegFile(
        width: 8000,
        height: 3000,
        xmp: ourXmp(sourceName: 'salon.jpg', sourceSize: png.length),
      );
      share.files['/Photos/cuisine.jpg'] = png;
      share.folders['/Photos'] = [
        for (final path in ['/Photos/cuisine.jpg', '/Photos/salon.jpg', '/Photos/salon_3D_LRF_Full_SBS.jpg'])
          share.file(path),
      ];
      await pumpPhotoPage(tester, '/Photos/salon.jpg', immersiveApi: immersiveApi);
      await pumpRealIo(tester, () => versionButton.evaluate().isNotEmpty);

      expect(find.byTooltip('View the 3D version'), findsOneWidget);
      expect(view3dButton, findsNothing, reason: 'the original itself is a flat photo');
      expect(share.listed, ['/Photos']);
      expect(
        share.reads.map((read) => read.$1),
        isNot(contains('/Photos/cuisine.jpg')),
        reason: 'only a neighbour named like a version is read',
      );

      await tester.tap(versionButton);
      await pumpRealIo(tester, () => immersiveApi.opened.isNotEmpty);

      expect(immersiveApi.opened.single['url'], server.urlOf('/Photos/salon_3D_LRF_Full_SBS.jpg').toString());
      expect(immersiveApi.opened.single['title'], 'salon_3D_LRF_Full_SBS.jpg');
      expect((jsonDecode(immersiveApi.stereoPairs.single!) as Map)['origin'], 'estimatedDepth');

      await endRealIo(tester);
    });

    testWidgets('a neighbour made from another photo of the same name is no version of it', (tester) async {
      final immersiveApi = _RecordingImmersiveApi();
      png = await makePng(tester);
      share.files['/Photos/salon.jpg'] = png;
      share.files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = jpegFile(
        width: 8000,
        height: 3000,
        xmp: ourXmp(sourceName: 'salon.jpg', sourceSize: png.length + 1),
      );
      share.folders['/Photos'] = [share.file('/Photos/salon.jpg'), share.file('/Photos/salon_3D_LRF_Full_SBS.jpg')];
      await pumpPhotoPage(tester, '/Photos/salon.jpg', immersiveApi: immersiveApi);
      await settleDetection(tester);
      await pumpRealIo(tester, () => share.reads.any((read) => read.$1 == '/Photos/salon_3D_LRF_Full_SBS.jpg'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(versionButton, findsNothing);

      await endRealIo(tester);
    });

    testWidgets('on a phone, neither "View in 3D" nor "View the 3D version", and no folder read for it', (
      tester,
    ) async {
      png = await makePng(tester);
      share.files['/Photos/salon.jpg'] = png;
      share.files['/Photos/salon_3D_LRF_Full_SBS.jpg'] = jpegFile(
        width: 8000,
        height: 3000,
        xmp: ourXmp(sourceName: 'salon.jpg', sourceSize: png.length),
      );
      share.folders['/Photos'] = [share.file('/Photos/salon.jpg'), share.file('/Photos/salon_3D_LRF_Full_SBS.jpg')];
      await pumpPhotoPage(tester, '/Photos/salon.jpg');
      await settleDetection(tester);

      expect(versionButton, findsNothing);
      expect(share.listed, isEmpty);

      await endRealIo(tester);
    });
  });
  group('AI relief', () {
    final reliefButton = find.byKey(aiReliefButtonKey);
    late InstalledModelService components;

    setUp(() {
      components = InstalledModelService()
        ..setStatus(depthModelTfliteComponent, const AiComponentStatus(AiComponentState.installed));
    });

    /// A Quest 3 with the quest flavour and the depth model installed, or the APK of [flavor]
    List<Override> headset({String? flavor = 'quest'}) => [
      appFlavorProvider.overrideWithValue(flavor),
      reliefDeviceFactsProvider.overrideWith((ref) async => const ReliefDeviceFacts(device: 'eureka', memoryMiB: 7600)),
      aiComponentsServiceProvider.overrideWithValue(components),
    ];

    testWidgets('on a Meta Quest, an ordinary photo asks for its relief from the media bridge, keyed by its place', (
      tester,
    ) async {
      final immersiveApi = _RecordingImmersiveApi();
      png = await makePng(tester);
      share.files['/Photos/salon.png'] = png;
      await pumpPhotoPage(tester, '/Photos/salon.png', immersiveApi: immersiveApi, extraOverrides: headset());
      await pumpRealIo(tester, () => reliefButton.evaluate().isNotEmpty);

      expect(find.byTooltip('AI relief'), findsOneWidget);

      await tester.tap(reliefButton);
      await pumpRealIo(tester, () => immersiveApi.opened.isNotEmpty);

      expect(immersiveApi.opened.single['url'], server.urlOf('/Photos/salon.png').toString());
      expect(immersiveApi.opened.single['title'], 'salon.png');
      final expected = questReliefRequest(
        modelPath: components.modelPath,
        identity: reliefIdentityOfShareFile(
          sourceId: _source.id,
          path: '/Photos/salon.png',
          size: png.length,
          modified: MemoryShare.modified,
        ),
        quarterTurns: 0,
      );
      expect(jsonDecode(immersiveApi.stereoPairs.single!), jsonDecode(expected.toJsonString()));

      await endRealIo(tester);
    });

    testWidgets('the turns the photo is seen with go in the request and its key', (tester) async {
      final immersiveApi = _RecordingImmersiveApi();
      png = await makePng(tester);
      share.files['/Photos/salon.png'] = png;
      await pumpPhotoPage(tester, '/Photos/salon.png', immersiveApi: immersiveApi, extraOverrides: headset());
      await pumpRealIo(tester, () => reliefButton.evaluate().isNotEmpty);

      // The one-key rotation of the page, kept on this device for the file
      await tester.tap(find.byKey(const Key('network_photo_rotate')));
      await tester.pump();
      await pumpRealIo(tester, () => tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns == 1);
      await tester.tap(reliefButton);
      await pumpRealIo(tester, () => immersiveApi.opened.isNotEmpty);

      final relief = jsonDecode(immersiveApi.stereoPairs.single!) as Map<String, dynamic>;
      expect(relief['quarterTurns'], 1);
      expect(
        relief['cacheKey'],
        questReliefRequest(
          modelPath: components.modelPath,
          identity: reliefIdentityOfShareFile(
            sourceId: _source.id,
            path: '/Photos/salon.png',
            size: png.length,
            modified: MemoryShare.modified,
          ),
          quarterTurns: 1,
        ).cacheKey,
      );

      await endRealIo(tester);
    });

    testWidgets('greyed with its reason in the APK of the phone flavour', (tester) async {
      final immersiveApi = _RecordingImmersiveApi();
      png = await makePng(tester);
      share.files['/Photos/salon.png'] = png;
      await pumpPhotoPage(
        tester,
        '/Photos/salon.png',
        immersiveApi: immersiveApi,
        extraOverrides: headset(flavor: 'phone'),
      );
      await pumpRealIo(tester, () => reliefButton.evaluate().isNotEmpty);

      expect(tester.widget<IconButton>(reliefButton).onPressed, isNull);
      expect(find.byTooltip('Not in this version of the app'), findsOneWidget);

      await endRealIo(tester);
    });

    testWidgets('not for two eyes side by side, which has "View in 3D"', (tester) async {
      final immersiveApi = _RecordingImmersiveApi();
      share.files['/salon_3D_LRF_Full_SBS.jpg'] = jpegFile(width: 8000, height: 3000, xmp: ourXmp());
      await pumpPhotoPage(tester, '/salon_3D_LRF_Full_SBS.jpg', immersiveApi: immersiveApi, extraOverrides: headset());
      await pumpRealIo(tester, () => find.byKey(const Key('apple_spatial_view_3d')).evaluate().isNotEmpty);

      expect(reliefButton, findsNothing);

      await endRealIo(tester);
    });

    testWidgets('not for a 360° photo', (tester) async {
      final immersiveApi = _RecordingImmersiveApi();
      png = await makePng(tester);
      share.files['/pano.png'] = withXmp(png, equirectangularXmp);
      await pumpPhotoPage(tester, '/pano.png', immersiveApi: immersiveApi, extraOverrides: headset());
      await pumpRealIo(tester, shows360Button);

      expect(reliefButton, findsNothing);

      await endRealIo(tester);
    });

    testWidgets('not on a phone', (tester) async {
      png = await makePng(tester);
      share.files['/Photos/salon.png'] = png;
      await pumpPhotoPage(tester, '/Photos/salon.png', extraOverrides: headset());
      await pumpRealIo(tester, showsDecodedPhoto);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(find.byKey(const Key('network_photo_rotate')), findsOneWidget, reason: 'the file was read');
      expect(reliefButton, findsNothing);

      await endRealIo(tester);
    });
  });
}
