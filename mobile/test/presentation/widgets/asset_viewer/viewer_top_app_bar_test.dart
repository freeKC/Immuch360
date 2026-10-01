import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spatial_video.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/routes.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

class _MockTimelineService extends Mock implements TimelineService {}

class _MockSphericalVideoApi extends Mock implements SphericalVideoApi {}

class _MockSpatialVideoApi extends Mock implements SpatialVideoApi {}

/// Records the viewer's player calls in the same list as the native player calls, to check their order
class _RecordingVideoPlayer extends VideoPlayerNotifier {
  _RecordingVideoPlayer(this._calls, {VideoPlayerState? initial}) {
    if (initial != null) {
      state = initial;
    }
  }

  final List<String> _calls;

  @override
  Future<void> pause() async => _calls.add('pause');

  @override
  Future<void> suspendForExternalPlayer() async => _calls.add('suspend');

  @override
  Future<void> resumeAfterExternalPlayer() async => _calls.add('resume');

  @override
  Future<void> resumeAfterExternalPlayerAt(Duration position, {required bool play}) async =>
      _calls.add('resume at ${position.inMilliseconds} ${play ? 'playing' : 'paused'}');
}

class _MockImmersiveApi extends Mock implements ImmersiveApi {}

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._initial);

  final AssetViewerState _initial;

  @override
  AssetViewerState build() {
    super.build();
    return _initial;
  }
}

class _FixedReadonlyModeNotifier extends ReadOnlyModeNotifier {
  _FixedReadonlyModeNotifier(this._enabled);

  final bool _enabled;

  @override
  bool build() => _enabled;
}

class _NoAlbumNotifier extends CurrentAlbumNotifier {
  @override
  RemoteAlbum? build() => null;
}

/// What the files of the videos declare (see [SphericalProbeService]): [result] for every video, nothing by default.
/// Records the probes, with the file on the device they were given.
class _FakeSphericalProbes extends SphericalProbeService {
  _FakeSphericalProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  SphericalProbe? result;
  final probed = <(BaseAsset, File?)>[];

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async {
    probed.add((asset, localFile));
    return asset.isVideo ? result : null;
  }
}

/// The assets the user chose to view as 360°, seeded rather than read from the store. Changes still go to the store.
class _SeededForcedPanoramas extends ForcedPanoramaAssets {
  _SeededForcedPanoramas(this._keys);

  final Set<String> _keys;

  @override
  Set<String> build() => _keys;
}

void main() {
  late PresentationContext context;
  late _MockTimelineService timeline;
  late _MockSphericalVideoApi sphericalVideoApi;
  late _MockSpatialVideoApi spatialVideoApi;
  late MockStorageRepository storage;
  late _FakeSphericalProbes probes;
  late List<String> calls;
  // Preview requests of the immersive viewer, and the XMP the preview carries: none by default
  late List<Uri> previewRequests;
  String? previewXmp;

  setUpAll(() => registerFallbackValue(<String, String>{}));
  late _MockImmersiveApi immersiveApi;

  setUpAll(() {
    registerFallbackValue(<String, String>{});
    registerFallbackValue(StereoLayout.mono);
    registerFallbackValue(ImmersiveStereoLayout.mono);
    registerFallbackValue(SphereCoverage.full);
    registerFallbackValue(ImmersiveSphereCoverage.full);
    registerFallbackValue(
      SpatialOpenRequest(
        url: '',
        headers: const {},
        title: '',
        layout: SpatialStereoLayout.auto,
        projection: SpatialProjection.flat,
        startPositionMs: 0,
        autoplay: false,
        debugOverlay: false,
        labels: const {},
      ),
    );
  });

  const englishCoverageLabels = {
    'coverage': 'Field of view',
    'coverage_full': '360°, full sphere',
    'coverage_half': '180°, half sphere (VR180)',
  };
  const englishViewerLabels = {
    'stereo': '3D layout',
    'mono': 'Mono (not 3D)',
    'topBottom': '3D, top and bottom',
    'leftRight': '3D, side by side',
    ...englishCoverageLabels,
  };

  setUp(() async {
    context = await PresentationContext.create();
    timeline = _MockTimelineService();
    when(() => timeline.origin).thenReturn(TimelineOrigin.main);
    calls = [];
    sphericalVideoApi = _MockSphericalVideoApi();
    when(
      () => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any()),
    ).thenAnswer((_) async => calls.add('open'));
    spatialVideoApi = _MockSpatialVideoApi();
    when(
      spatialVideoApi.capabilities,
    ).thenAnswer((_) async => SpatialCapabilities(supported: true, frontCamera: true, cameraPermissionGranted: false));
    when(() => spatialVideoApi.open(any())).thenAnswer((_) async => calls.add('spatial'));
    storage = MockStorageRepository();
    probes = _FakeSphericalProbes();
    immersiveApi = _MockImmersiveApi();
    when(
      () => immersiveApi.open(any(), any(), any(), any(), any(), any(), any()),
    ).thenAnswer((_) async => calls.add('immersive'));
    previewRequests = [];
    previewXmp = null;
  });

  tearDown(() async {
    await StoreService.I.delete(StoreKey.spatialLayoutOverrides);
    await StoreService.I.delete(StoreKey.forcedPanoramaAssets);
    await StoreService.I.delete(StoreKey.sphereCoverageOverrides);
    await StoreService.I.delete(StoreKey.advancedTroubleshooting);
    await context.dispose();
  });

  final panoramaButton = find.byTooltip('360°');
  final kebabMenu = find.byIcon(Icons.more_vert_rounded);
  final favoriteButton = find.byType(ImmichIconButton);

  RemoteAsset owned({AssetType type = .image, String? localId, int? width, int? height, String? name}) =>
      RemoteAssetFactory.create(
        ownerId: context.currentUser.id,
        type: type,
        localId: localId,
        width: width,
        height: height,
        name: name,
      );

  /// Pumps the top bar under a real router whose panorama route renders a stub page, so a push can be observed.
  /// [panoramaVideoSupported] tells whether the platform has the native 360° video player. [forcedPanoramas], when
  /// given, are the keys of the assets the user chose to view as 360°, else they come from the store.
  Future<RootStackRouter> pumpTopBar(
    WidgetTester tester,
    BaseAsset asset, {
    ProjectionType? projectionType,
    Set<String>? forcedPanoramas,
    bool readonly = false,
    bool locked = false,
    bool showingDetails = false,
    bool panoramaVideoSupported = false,
    AppConfig? appConfig,
    bool horizonOs = false,
    VideoPlayerState? playerState,
  }) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('Viewer', builder: (_) => const Scaffold(appBar: ViewerTopAppBar())),
        ),
        AutoRoute(
          path: '/panorama',
          page: PageInfo(
            PanoramaViewerRoute.name,
            builder: (data) => Text('panorama ${data.argsAs<PanoramaViewerRouteArgs>().asset.id}'),
          ),
        ),
      ],
    );

    // Starts from an empty tree so a second pump in the same test gets a fresh ProviderScope
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            ...context.overrides,
            timelineServiceProvider.overrideWithValue(timeline),
            assetViewerProvider.overrideWith(
              () => _SeededAssetViewerNotifier(AssetViewerState(currentAsset: asset, showingDetails: showingDetails)),
            ),
            assetExifProvider(asset).overrideWith((ref) => Stream.value(ExifInfo(projectionType: projectionType))),
            currentRemoteAlbumProvider.overrideWith(_NoAlbumNotifier.new),
            readonlyModeProvider.overrideWith(() => _FixedReadonlyModeNotifier(readonly)),
            // Listed after the context overrides so it replaces their default of false
            inLockedViewProvider.overrideWithValue(locked),
            panorama360VideoSupportedProvider.overrideWithValue(panoramaVideoSupported),
            sphericalVideoApiProvider.overrideWithValue(sphericalVideoApi),
            storageRepositoryProvider.overrideWithValue(storage),
            sphericalProbeServiceProvider.overrideWithValue(probes),
            videoPlayerProvider(asset.id).overrideWith((ref) => _RecordingVideoPlayer(calls, initial: playerState)),
            spatialVideoApiProvider.overrideWithValue(spatialVideoApi),
            if (appConfig != null) appConfigProvider.overrideWithValue(appConfig),
            isHorizonOsProvider.overrideWith((ref) => horizonOs),
            immersiveApiProvider.overrideWithValue(immersiveApi),
            if (forcedPanoramas != null)
              forcedPanoramaAssetsProvider.overrideWith(() => _SeededForcedPanoramas(forcedPanoramas)),
            immersiveGPanoClientProvider.overrideWithValue(
              MockClient((request) async {
                previewRequests.add(request.url);
                return http.Response.bytes((previewXmp ?? '').codeUnits, 206);
              }),
            ),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  group('ViewerTopAppBar 360 button', () {
    testWidgets('is shown for an equirectangular image, next to the regular actions', (tester) async {
      await pumpTopBar(tester, owned(), projectionType: .equirectangular);

      expect(panoramaButton, findsOneWidget);
      expect(find.byIcon(Icons.threesixty_rounded), findsOneWidget);
      expect(kebabMenu, findsOneWidget);
      expect(favoriteButton, findsOneWidget);
    });

    testWidgets('is hidden for an image that is not a panorama', (tester) async {
      for (final projectionType in [null, ProjectionType.none, ProjectionType.cubemap]) {
        await pumpTopBar(tester, owned(), projectionType: projectionType);

        expect(panoramaButton, findsNothing, reason: 'projection type $projectionType');
        expect(kebabMenu, findsOneWidget, reason: 'projection type $projectionType');
      }
    });

    testWidgets('is hidden for an equirectangular video where the platform has no 360° video player', (tester) async {
      await pumpTopBar(tester, owned(type: .video), projectionType: .equirectangular);

      expect(panoramaButton, findsNothing);
      expect(kebabMenu, findsOneWidget);
    });

    testWidgets('is shown for an equirectangular video where the platform has a 360° video player', (tester) async {
      await pumpTopBar(tester, owned(type: .video), projectionType: .equirectangular, panoramaVideoSupported: true);

      expect(panoramaButton, findsOneWidget);
      expect(kebabMenu, findsOneWidget);
      expect(favoriteButton, findsOneWidget);
    });

    testWidgets('is hidden for a video that is not a panorama', (tester) async {
      for (final projectionType in [null, ProjectionType.none, ProjectionType.cubemap]) {
        await pumpTopBar(tester, owned(type: .video), projectionType: projectionType, panoramaVideoSupported: true);

        expect(panoramaButton, findsNothing, reason: 'projection type $projectionType');
        expect(kebabMenu, findsOneWidget, reason: 'projection type $projectionType');
      }
    });

    testWidgets('stays available in readonly mode while the other actions are hidden', (tester) async {
      await pumpTopBar(tester, owned(), projectionType: .equirectangular, readonly: true);

      expect(panoramaButton, findsOneWidget);
      expect(kebabMenu, findsNothing);
      expect(favoriteButton, findsNothing);
    });

    testWidgets('leaves no actions in readonly mode for an image that is not a panorama', (tester) async {
      await pumpTopBar(tester, owned(), readonly: true);

      expect(panoramaButton, findsNothing);
      expect(kebabMenu, findsNothing);
      expect(favoriteButton, findsNothing);
    });

    testWidgets('is shown next to the kebab menu in the locked view', (tester) async {
      await pumpTopBar(tester, owned(), projectionType: .equirectangular, locked: true);

      expect(panoramaButton, findsOneWidget);
      expect(kebabMenu, findsOneWidget);
      expect(favoriteButton, findsNothing, reason: 'the locked view only keeps the kebab menu');
      final row = find.ancestor(of: panoramaButton, matching: find.byType(Row)).first;
      expect(find.descendant(of: row, matching: kebabMenu), findsOneWidget);
    });

    testWidgets('is hidden with every other action while the details are showing', (tester) async {
      await pumpTopBar(tester, owned(), projectionType: .equirectangular, showingDetails: true);

      expect(panoramaButton, findsNothing);
      expect(kebabMenu, findsNothing);
      expect(favoriteButton, findsNothing);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget, reason: 'the back button stays');
    });

    testWidgets('opens the panorama viewer for the current asset', (tester) async {
      final asset = owned();
      final router = await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(router.current.name, PanoramaViewerRoute.name);
      expect(router.current.argsAs<PanoramaViewerRouteArgs>().asset, asset);
      expect(find.text('panorama ${asset.id}'), findsOneWidget);
      verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any()));
      verifyNever(() => immersiveApi.open(any(), any(), any(), any(), any(), any(), any()));
    });

    testWidgets('stops a video, then plays its transcoded stream in the native 360° player', (tester) async {
      final asset = owned(type: .video);
      final router = await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'open'], reason: 'the viewer must not play nor buffer behind the 360° player');
      final captured = verify(
        () => sphericalVideoApi.open(
          captureAny(),
          captureAny(),
          captureAny(),
          captureAny(),
          captureAny(),
          captureAny(),
          captureAny(),
          captureAny(),
        ),
      ).captured;
      expect(captured, [
        '${PresentationContext.serverEndpoint}/assets/${asset.id}/video/playback',
        <String, String>{},
        asset.name,
        'Close',
        'Unable to play video',
        StereoLayout.mono,
        englishViewerLabels,
        SphereCoverage.full,
      ]);
      expect(router.current.name, isNot(PanoramaViewerRoute.name), reason: 'the photo viewer is for images only');
      verifyNever(() => storage.getFileForAsset(any()));
    });

    testWidgets('plays the copy on the phone in the native 360° player, like the viewer', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      final file = File('/storage/emulated/0/DCIM/Camera/VID_360.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final url = verify(
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any()),
      ).captured.single;
      expect(url, file.uri.toString());
      expect(url, startsWith('file:///'));
    });

    testWidgets('streams from the server when the copy on the phone cannot be read', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => null);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final url = verify(
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any()),
      ).captured.single;
      expect(url, '${PresentationContext.serverEndpoint}/assets/${asset.id}/video/playback');
    });

    testWidgets('gives the viewer its video back when the native 360° player cannot open', (tester) async {
      when(
        () => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any()),
      ).thenThrow(PlatformException(code: 'channel-error'));
      await pumpTopBar(tester, owned(type: .video), projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'resume']);
    });

    testWidgets('plays the original video in the native 360° player when the settings ask for it', (tester) async {
      final asset = owned(type: .video);
      await pumpTopBar(
        tester,
        asset,
        projectionType: .equirectangular,
        panoramaVideoSupported: true,
        appConfig: const AppConfig(viewer: ViewerConfig(loadOriginalVideo: true)),
      );

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final url = verify(
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any()),
      ).captured.single;
      expect(url, '${PresentationContext.serverEndpoint}/assets/${asset.id}/original');
    });

    testWidgets('tells the native 360° player the 3D layout the video dimensions suggest', (tester) async {
      for (final (width, height, expected) in [
        (5760, 5760, StereoLayout.topBottom),
        (7680, 1920, StereoLayout.leftRight),
        (5760, 2880, StereoLayout.mono),
      ]) {
        clearInteractions(sphericalVideoApi);
        final asset = owned(type: .video, width: width, height: height);
        await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

        await tester.tap(panoramaButton);
        await tester.pumpAndSettle();

        final captured = verify(
          () => sphericalVideoApi.open(any(), any(), any(), any(), any(), captureAny(), captureAny(), captureAny()),
        ).captured;
        expect(captured, [expected, englishViewerLabels, SphereCoverage.full], reason: '$width x $height');
      }
    });

    testWidgets('tells the native 360° player a VR180 video by its name: two eyes side by side, the front half', (
      tester,
    ) async {
      final asset = owned(type: .video, width: 5760, height: 2880, name: 'trip_VR180.mp4');
      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final captured = verify(
        () => sphericalVideoApi.open(any(), any(), any(), any(), any(), captureAny(), any(), captureAny()),
      ).captured;
      expect(captured, [StereoLayout.leftRight, SphereCoverage.half]);
    });

    testWidgets('tells the native 360° player what the file declares, read from the copy on the phone', (tester) async {
      final asset = owned(type: .video, localId: 'local-1', width: 4096, height: 2048);
      final file = File('/storage/emulated/0/DCIM/Camera/VID_VR.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      probes.result = const SphericalProbe(
        stereo: StereoLayout.topBottom,
        halfSphere: true,
        hasSphericalMetadata: true,
      );
      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final captured = verify(
        () => sphericalVideoApi.open(any(), any(), any(), any(), any(), captureAny(), any(), captureAny()),
      ).captured;
      expect(captured, [StereoLayout.topBottom, SphereCoverage.half]);
      expect(probes.probed, [(asset, file)]);
    });

    testWidgets('prefers the coverage the user picked for the asset', (tester) async {
      final asset = owned(type: .video, width: 5760, height: 2880, name: 'trip_VR180.mp4');
      await StoreService.I.put(StoreKey.sphereCoverageOverrides, '{"${asset.id}":"full"}');
      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final captured = verify(
        () => sphericalVideoApi.open(any(), any(), any(), any(), any(), captureAny(), any(), captureAny()),
      ).captured;
      expect(captured, [StereoLayout.mono, SphereCoverage.full]);
    });

    testWidgets('remembers the coverage picked in the native 360° player, and forgets it back on the guess', (
      tester,
    ) async {
      final asset = owned(type: .video, width: 5760, height: 2880);
      Future<void> closePlayer(SphereCoverage coverage) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'dev.flutter.pigeon.immich_mobile.SphericalVideoEvents.closed',
          SphericalVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[StereoLayout.leftRight, coverage]),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);
      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();
      await closePlayer(SphereCoverage.half);

      expect(StoreService.I.tryGet(StoreKey.sphereCoverageOverrides), '{"${asset.id}":"half"}');

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();
      expect(
        verify(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), captureAny())).captured,
        [SphereCoverage.full, SphereCoverage.half],
        reason: 'opens with the coverage picked last time',
      );
      await closePlayer(SphereCoverage.full);

      expect(StoreService.I.tryGet(StoreKey.sphereCoverageOverrides), '{}');
    });
  });

  group('ViewerTopAppBar 360 button on a Meta Quest', () {
    const server = PresentationContext.serverEndpoint;

    testWidgets('is also shown for an equirectangular video', (tester) async {
      await pumpTopBar(tester, owned(type: .video), projectionType: .equirectangular, horizonOs: true);

      expect(panoramaButton, findsOneWidget);
      expect(kebabMenu, findsOneWidget);
    });

    testWidgets('stays hidden for media that are not panoramas', (tester) async {
      for (final type in [AssetType.image, AssetType.video]) {
        await pumpTopBar(tester, owned(type: type), projectionType: .none, horizonOs: true);

        expect(panoramaButton, findsNothing, reason: 'type $type');
      }
    });

    testWidgets('opens a photo in the immersive viewer with its original', (tester) async {
      final asset = owned();
      final router = await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(
        () => immersiveApi.open(
          '$server/assets/${asset.id}/original?edited=true',
          any(),
          false,
          asset.name,
          any(),
          any(),
          any(),
        ),
      ).called(1);
      expect(router.current.name, isNot(PanoramaViewerRoute.name), reason: 'the 2D panorama viewer is not used');
    });

    testWidgets('tells the immersive viewer the 3D layout the dimensions suggest, with the labels', (tester) async {
      for (final (type, width, height, expected) in [
        (AssetType.image, 4096, 4096, ImmersiveStereoLayout.topBottom),
        (AssetType.video, 7680, 1920, ImmersiveStereoLayout.leftRight),
        (AssetType.image, 6080, 3040, ImmersiveStereoLayout.mono),
        (AssetType.video, null, null, ImmersiveStereoLayout.mono),
      ]) {
        clearInteractions(immersiveApi);
        previewRequests.clear();
        final asset = owned(type: type, width: width, height: height);
        await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

        await tester.tap(panoramaButton);
        await tester.pumpAndSettle();

        final captured = verify(
          () => immersiveApi.open(any(), any(), any(), any(), captureAny(), captureAny(), captureAny()),
        ).captured;
        expect(captured, [
          expected,
          englishViewerLabels,
          ImmersiveSphereCoverage.full,
        ], reason: '$type $width x $height');
        // Only a photo that looks 3D is checked for a partial panorama
        final checked = type == AssetType.image && expected != ImmersiveStereoLayout.mono;
        expect(previewRequests, hasLength(checked ? 1 : 0), reason: '$type $width x $height');
      }
    });

    testWidgets('opens a partial panorama mono, whatever its aspect ratio', (tester) async {
      // A 4:1 band of the sphere, which its dimensions alone would take for a side by side 3D photo
      previewXmp =
          '<rdf:Description GPano:FullPanoWidthPixels="8704" GPano:FullPanoHeightPixels="4352" '
          'GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="1088" '
          'GPano:CroppedAreaImageWidthPixels="8704" GPano:CroppedAreaImageHeightPixels="2176"/>';
      final asset = owned(width: 8704, height: 2176);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final layout = verify(
        () => immersiveApi.open(any(), any(), any(), any(), captureAny(), any(), any()),
      ).captured.single;
      expect(layout, ImmersiveStereoLayout.mono);
      expect(previewRequests, [Uri.parse('$server/assets/${asset.id}/thumbnail?size=preview&edited=true')]);
    });

    testWidgets('keeps the 3D layout of a full sphere whose crop tags cover all of it', (tester) async {
      previewXmp =
          '<rdf:Description GPano:FullPanoWidthPixels="4096" GPano:FullPanoHeightPixels="2048" '
          'GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="0" '
          'GPano:CroppedAreaImageWidthPixels="4096" GPano:CroppedAreaImageHeightPixels="2048"/>';
      await pumpTopBar(tester, owned(width: 4096, height: 4096), projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final layout = verify(
        () => immersiveApi.open(any(), any(), any(), any(), captureAny(), any(), any()),
      ).captured.single;
      expect(layout, ImmersiveStereoLayout.topBottom);
    });

    testWidgets('tells the immersive viewer the coverage: a VR180 photo by its name, a video by its file', (
      tester,
    ) async {
      const declaredHalf = SphericalProbe(halfSphere: true, hasSphericalMetadata: true);
      for (final (asset, probe, layout, coverage) in [
        (
          owned(width: 5760, height: 2880, name: 'IMG_VR180.jpg'),
          null,
          ImmersiveStereoLayout.leftRight,
          ImmersiveSphereCoverage.half,
        ),
        (
          owned(type: .video, width: 4096, height: 2048),
          declaredHalf,
          ImmersiveStereoLayout.leftRight,
          ImmersiveSphereCoverage.half,
        ),
        (
          owned(type: .video, width: 4096, height: 2048),
          null,
          ImmersiveStereoLayout.mono,
          ImmersiveSphereCoverage.full,
        ),
        // A half sphere crop: the left eye of a Google VR180 photo
        (owned(width: 4096, height: 4096), null, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.half),
      ]) {
        clearInteractions(immersiveApi);
        probes.result = probe;
        previewXmp = asset.width == asset.height
            ? '<rdf:Description GPano:FullPanoWidthPixels="8192" GPano:FullPanoHeightPixels="4096" '
                  'GPano:CroppedAreaLeftPixels="2048" GPano:CroppedAreaTopPixels="0" '
                  'GPano:CroppedAreaImageWidthPixels="4096" GPano:CroppedAreaImageHeightPixels="4096"/>'
            : null;
        await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

        await tester.tap(panoramaButton);
        await tester.pumpAndSettle();

        final captured = verify(
          () => immersiveApi.open(any(), any(), any(), any(), captureAny(), any(), captureAny()),
        ).captured;
        expect(captured, [layout, coverage], reason: asset.name);
      }
    });

    testWidgets('prefers the coverage the user picked for the asset in the immersive viewer', (tester) async {
      final asset = owned(type: .video, width: 5760, height: 2880, name: 'trip_VR180.mp4');
      await StoreService.I.put(StoreKey.sphereCoverageOverrides, '{"${asset.id}":"full"}');
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final captured = verify(
        () => immersiveApi.open(any(), any(), any(), any(), captureAny(), any(), captureAny()),
      ).captured;
      expect(captured, [ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full]);
    });

    testWidgets('stops a video, then opens its original in the immersive viewer whatever the setting', (tester) async {
      for (final loadOriginalVideo in [false, true]) {
        calls.clear();
        clearInteractions(immersiveApi);
        final asset = owned(type: .video);
        await pumpTopBar(
          tester,
          asset,
          projectionType: .equirectangular,
          horizonOs: true,
          appConfig: AppConfig(viewer: ViewerConfig(loadOriginalVideo: loadOriginalVideo)),
        );

        await tester.tap(panoramaButton);
        await tester.pumpAndSettle();

        expect(calls, ['suspend', 'immersive'], reason: 'loadOriginalVideo $loadOriginalVideo');
        verify(
          () => immersiveApi.open('$server/assets/${asset.id}/original', any(), true, asset.name, any(), any(), any()),
        ).called(1);
        verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any()));
      }
    });

    testWidgets('plays the copy on the headset in the immersive viewer, like the viewer', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      final file = File('/storage/emulated/0/Oculus/VideoShots/VID_360.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(() => immersiveApi.open(file.uri.toString(), any(), true, asset.name, any(), any(), any())).called(1);
    });

    testWidgets('opens the original when the copy on the headset cannot be read', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => null);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(
        () => immersiveApi.open('$server/assets/${asset.id}/original', any(), true, asset.name, any(), any(), any()),
      ).called(1);
    });

    testWidgets('gives the viewer its video back when the immersive viewer cannot open', (tester) async {
      when(
        () => immersiveApi.open(any(), any(), any(), any(), any(), any(), any()),
      ).thenThrow(PlatformException(code: 'channel-error'));
      await pumpTopBar(tester, owned(type: .video), projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'resume']);
      expect(find.text('Could not open the immersive viewer'), findsOneWidget);
    });
  });

  group('ViewerTopAppBar 360 button for an asset the user chose to view as 360°', () {
    testWidgets('is shown for a photo whose exif says nothing, and opens the panorama viewer', (tester) async {
      final asset = owned();
      final router = await pumpTopBar(tester, asset, forcedPanoramas: {asset.id});

      expect(panoramaButton, findsOneWidget);
      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(router.current.name, PanoramaViewerRoute.name);
      expect(router.current.argsAs<PanoramaViewerRouteArgs>().asset, asset);
    });

    testWidgets('plays such a video in the native 360° player', (tester) async {
      final asset = owned(type: .video);
      await pumpTopBar(tester, asset, projectionType: .none, forcedPanoramas: {asset.id}, panoramaVideoSupported: true);

      expect(panoramaButton, findsOneWidget);
      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'open']);
    });

    testWidgets('opens such a photo in the immersive viewer on a Meta Quest', (tester) async {
      final asset = owned();
      await pumpTopBar(tester, asset, forcedPanoramas: {asset.id}, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(() => immersiveApi.open(any(), any(), false, asset.name, any(), any(), any())).called(1);
    });

    testWidgets('stays hidden for the other assets', (tester) async {
      await pumpTopBar(tester, owned(), forcedPanoramas: {'another-asset'});

      expect(panoramaButton, findsNothing);
    });
  });

  group('ViewerTopAppBar "View as 360°" action', () {
    final viewAs360 = find.text('View as 360°');
    final stopViewingAs360 = find.text('Stop treating as 360°');

    Future<void> openKebabMenu(WidgetTester tester) async {
      await tester.tap(kebabMenu);
      await tester.pumpAndSettle();
      expect(find.text('Slideshow'), findsOneWidget, reason: 'the menu is open');
    }

    String? stored() => StoreService.I.tryGet(StoreKey.forcedPanoramaAssets);

    testWidgets('is offered for a photo and a video the server does not flag as 360°', (tester) async {
      for (final (type, projectionType) in [
        (AssetType.image, null),
        (AssetType.image, ProjectionType.none),
        (AssetType.video, null),
      ]) {
        await pumpTopBar(tester, owned(type: type), projectionType: projectionType, panoramaVideoSupported: true);
        await openKebabMenu(tester);

        expect(viewAs360, findsOneWidget, reason: '$type $projectionType');
        expect(stopViewingAs360, findsNothing, reason: '$type $projectionType');
      }
    });

    testWidgets('is not offered for what the server flags as 360°, even once chosen', (tester) async {
      for (final type in [AssetType.image, AssetType.video]) {
        final asset = owned(type: type);
        for (final forced in [
          <String>{},
          {asset.id},
        ]) {
          await pumpTopBar(
            tester,
            asset,
            projectionType: .equirectangular,
            forcedPanoramas: forced,
            panoramaVideoSupported: true,
          );
          await openKebabMenu(tester);

          expect(viewAs360, findsNothing, reason: '$type forced $forced');
          expect(stopViewingAs360, findsNothing, reason: '$type forced $forced');
        }
      }
    });

    testWidgets('is not offered for a video where the device has no 360° view', (tester) async {
      await pumpTopBar(tester, owned(type: .video));
      await openKebabMenu(tester);

      expect(viewAs360, findsNothing);
    });

    testWidgets('views a photo as 360° from now on and opens it in the panorama viewer', (tester) async {
      final asset = owned();
      final router = await pumpTopBar(tester, asset);
      expect(panoramaButton, findsNothing);

      await openKebabMenu(tester);
      await tester.tap(viewAs360);
      await tester.pumpAndSettle();

      expect(stored(), '["${asset.id}"]');
      expect(router.current.name, PanoramaViewerRoute.name);
      expect(router.current.argsAs<PanoramaViewerRouteArgs>().asset, asset);

      await router.maybePop();
      await tester.pumpAndSettle();
      expect(panoramaButton, findsOneWidget, reason: 'the 360° button is there from now on');
    });

    testWidgets('views a video as 360° and plays it in the native 360° player', (tester) async {
      final asset = owned(type: .video);
      await pumpTopBar(tester, asset, panoramaVideoSupported: true);

      await openKebabMenu(tester);
      await tester.tap(viewAs360);
      await tester.pumpAndSettle();

      expect(stored(), '["${asset.id}"]');
      expect(calls, ['suspend', 'open']);
      expect(panoramaButton, findsOneWidget);
      expect(viewAs360, findsNothing, reason: 'the menu closes');
    });

    testWidgets('plays a video only on the phone from its file', (tester) async {
      final asset = LocalAsset(
        id: 'local-1',
        name: 'VID_360.mp4',
        type: AssetType.video,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: AssetPlaybackStyle.video,
        isEdited: false,
      );
      final file = File('/storage/emulated/0/DCIM/Camera/VID_360.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      await pumpTopBar(tester, asset, panoramaVideoSupported: true);

      await openKebabMenu(tester);
      await tester.tap(viewAs360);
      await tester.pumpAndSettle();

      expect(stored(), '["local-1"]');
      final url = verify(
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any()),
      ).captured.single;
      expect(url, file.uri.toString());
    });

    testWidgets('opens a photo in the immersive viewer on a Meta Quest', (tester) async {
      final asset = owned();
      final router = await pumpTopBar(tester, asset, horizonOs: true);

      await openKebabMenu(tester);
      await tester.tap(viewAs360);
      await tester.pumpAndSettle();

      expect(stored(), '["${asset.id}"]');
      verify(() => immersiveApi.open(any(), any(), false, asset.name, any(), any(), any())).called(1);
      expect(router.current.name, isNot(PanoramaViewerRoute.name));
    });

    testWidgets('offers to stop once chosen, which hides the 360° button again', (tester) async {
      final asset = owned();
      final other = owned();
      await pumpTopBar(tester, asset, forcedPanoramas: {other.id, asset.id});
      expect(panoramaButton, findsOneWidget);

      await openKebabMenu(tester);
      expect(viewAs360, findsNothing);
      await tester.tap(stopViewingAs360);
      await tester.pumpAndSettle();

      expect(stored(), '["${other.id}"]');
      expect(panoramaButton, findsNothing);
      await openKebabMenu(tester);
      expect(viewAs360, findsOneWidget);
    });

    testWidgets('is offered in the locked view too', (tester) async {
      await pumpTopBar(tester, owned(), locked: true);
      await openKebabMenu(tester);

      expect(viewAs360, findsOneWidget);
    });
  });

  group('ViewerTopAppBar Spatial 2.5D button', () {
    const server = PresentationContext.serverEndpoint;
    const spatialOn = AppConfig(viewer: ViewerConfig(spatial25d: true));
    final spatialButton = find.byTooltip('Spatial 2.5D');
    const englishSpatialLabels = {
      'spatial': 'Spatial 2.5D',
      'normal': 'Normal',
      'layout': 'Stereo layout',
      'layoutAuto': 'Auto',
      'layoutSideBySide': 'Side by side',
      'layoutTopBottom': 'Top and bottom',
      'layoutSideBySideSwapped': 'Side by side, eyes swapped',
      'layoutTopBottomSwapped': 'Top and bottom, eyes swapped',
      'layoutNone': 'Not stereoscopic',
      'recenter': 'Recenter',
      'trackingLost': 'Face not found, looking for it',
      'cameraDenied': 'Camera access refused: use the slider to move the viewpoint',
      'unavailable': 'Spatial 2.5D is not available on this device',
      'sensitivity': 'Head sensitivity',
      'close': 'Close',
      'error': 'Unable to play video',
      ...englishCoverageLabels,
    };

    SpatialOpenRequest openedRequest() =>
        verify(() => spatialVideoApi.open(captureAny())).captured.single as SpatialOpenRequest;

    testWidgets('is hidden while the experimental setting is off', (tester) async {
      await pumpTopBar(
        tester,
        owned(type: .video),
        appConfig: const AppConfig(viewer: ViewerConfig(spatial25d: false)),
      );

      expect(spatialButton, findsNothing);
      expect(kebabMenu, findsOneWidget);
    });

    testWidgets('is shown for a video when the setting is on, next to the regular actions', (tester) async {
      await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn);

      expect(spatialButton, findsOneWidget);
      expect(find.byIcon(Icons.threed_rotation_rounded), findsOneWidget);
      expect(kebabMenu, findsOneWidget);
      expect(favoriteButton, findsOneWidget);
      expect(panoramaButton, findsNothing);
    });

    testWidgets('is hidden for a photo', (tester) async {
      for (final projectionType in [null, ProjectionType.equirectangular]) {
        await pumpTopBar(tester, owned(), projectionType: projectionType, appConfig: spatialOn);

        expect(spatialButton, findsNothing, reason: 'projection type $projectionType');
      }
    });

    testWidgets('is hidden on a Meta Quest, which keeps its immersive viewer', (tester) async {
      await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn, horizonOs: true);
      expect(spatialButton, findsNothing);

      await pumpTopBar(
        tester,
        owned(type: .video),
        projectionType: .equirectangular,
        appConfig: spatialOn,
        horizonOs: true,
      );
      expect(spatialButton, findsNothing);
      expect(panoramaButton, findsOneWidget);
    });

    testWidgets('sits next to the 360° button of a 360° video', (tester) async {
      await pumpTopBar(
        tester,
        owned(type: .video),
        projectionType: .equirectangular,
        panoramaVideoSupported: true,
        appConfig: spatialOn,
      );

      expect(spatialButton, findsOneWidget);
      expect(panoramaButton, findsOneWidget);
    });

    testWidgets('stays available in readonly mode and in the locked view', (tester) async {
      await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn, readonly: true);
      expect(spatialButton, findsOneWidget);
      expect(kebabMenu, findsNothing);

      await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn, locked: true);
      expect(spatialButton, findsOneWidget);
      expect(favoriteButton, findsNothing);
    });

    testWidgets('is hidden while the details are showing', (tester) async {
      await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn, showingDetails: true);

      expect(spatialButton, findsNothing);
    });

    testWidgets('stops the video, then opens the player where the viewer was, playing, with the labels', (
      tester,
    ) async {
      final asset = owned(type: .video);
      await pumpTopBar(
        tester,
        asset,
        appConfig: spatialOn,
        playerState: const VideoPlayerState(
          position: Duration(milliseconds: 83500),
          duration: Duration(minutes: 3),
          status: VideoPlaybackStatus.playing,
        ),
      );

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'spatial'], reason: 'the viewer must not play nor buffer behind the Spatial player');
      final request = openedRequest();
      expect(request.url, '$server/assets/${asset.id}/video/playback');
      expect(request.headers, <String, String>{});
      expect(request.title, asset.name);
      expect(request.layout, SpatialStereoLayout.auto);
      expect(request.projection, SpatialProjection.flat);
      expect(request.startPositionMs, 83500);
      expect(request.autoplay, isTrue);
      expect(request.debugOverlay, isFalse);
      expect(request.labels, englishSpatialLabels);
      verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any()));
    });

    testWidgets('keeps a paused video paused in the player', (tester) async {
      await pumpTopBar(
        tester,
        owned(type: .video),
        appConfig: spatialOn,
        playerState: const VideoPlayerState(
          position: Duration(seconds: 12),
          duration: Duration(minutes: 1),
          status: VideoPlaybackStatus.paused,
        ),
      );

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      final request = openedRequest();
      expect(request.startPositionMs, 12000);
      expect(request.autoplay, isFalse);
    });

    testWidgets('shows the diagnostics with the advanced troubleshooting setting', (tester) async {
      await StoreService.I.put(StoreKey.advancedTroubleshooting, true);
      await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      expect(openedRequest().debugOverlay, isTrue);
    });

    testWidgets('plays the original or the copy on the phone, like the viewer', (tester) async {
      final asset = owned(type: .video);
      await pumpTopBar(
        tester,
        asset,
        appConfig: const AppConfig(viewer: ViewerConfig(spatial25d: true, loadOriginalVideo: true)),
      );
      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      expect(openedRequest().url, '$server/assets/${asset.id}/original');

      final onPhone = owned(type: .video, localId: 'local-1');
      final file = File('/storage/emulated/0/DCIM/Camera/VID_3D.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      await pumpTopBar(tester, onPhone, appConfig: spatialOn);
      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      expect(openedRequest().url, file.uri.toString());
    });

    testWidgets('guesses the stereo layout from the frame and the file name', (tester) async {
      for (final (width, height, name, projection, expected) in [
        (3840, 1080, 'clip.mp4', null, SpatialStereoLayout.sideBySide),
        (1920, 2160, 'clip.mp4', null, SpatialStereoLayout.topBottom),
        (1920, 1080, 'Movie.Half-OU.mp4', null, SpatialStereoLayout.topBottom),
        (1920, 1080, 'VID_20240101.mp4', null, SpatialStereoLayout.auto),
        (5760, 5760, 'clip.mp4', ProjectionType.equirectangular, SpatialStereoLayout.topBottom),
        (7680, 1920, 'clip.mp4', ProjectionType.equirectangular, SpatialStereoLayout.sideBySide),
      ]) {
        clearInteractions(spatialVideoApi);
        final asset = owned(type: .video, width: width, height: height, name: name);
        await pumpTopBar(tester, asset, projectionType: projection, appConfig: spatialOn);

        await tester.tap(spatialButton);
        await tester.pumpAndSettle();

        final request = openedRequest();
        final reason = '$width x $height $name $projection';
        expect(request.layout, expected, reason: reason);
        expect(
          request.projection,
          projection == ProjectionType.equirectangular ? SpatialProjection.equirectangular : SpatialProjection.flat,
          reason: reason,
        );
      }
    });

    testWidgets('prefers the layout the user picked last time for the asset', (tester) async {
      final asset = owned(type: .video, width: 3840, height: 1080);
      await SpatialLayoutOverrides(StoreService.I).set(asset.id, SpatialStereoLayout.sideBySideSwapped);
      await pumpTopBar(tester, asset, appConfig: spatialOn);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      expect(openedRequest().layout, SpatialStereoLayout.sideBySideSwapped);
    });

    testWidgets('leaves the video alone and says so where the device cannot run the player', (tester) async {
      for (final unsupported in [true, false]) {
        calls.clear();
        if (unsupported) {
          when(spatialVideoApi.capabilities).thenAnswer(
            (_) async => SpatialCapabilities(
              supported: false,
              frontCamera: false,
              cameraPermissionGranted: false,
              reason: 'no front camera',
            ),
          );
        } else {
          when(spatialVideoApi.capabilities).thenThrow(PlatformException(code: 'channel-error'));
        }
        await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn);

        await tester.tap(spatialButton);
        await tester.pumpAndSettle();

        expect(calls, isEmpty, reason: 'unsupported $unsupported: the viewer goes on playing');
        verifyNever(() => spatialVideoApi.open(any()));
        expect(find.text('Spatial 2.5D is not available on this device'), findsOneWidget);
      }
    });

    testWidgets('gives the viewer its video back where and as it was when the player cannot open', (tester) async {
      when(() => spatialVideoApi.open(any())).thenThrow(PlatformException(code: 'channel-error'));
      await pumpTopBar(tester, owned(type: .video), appConfig: spatialOn);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'resume at 0 paused']);
      expect(find.text('Could not open the Spatial 2.5D player'), findsOneWidget);

      calls.clear();
      await pumpTopBar(
        tester,
        owned(type: .video),
        appConfig: spatialOn,
        playerState: const VideoPlayerState(
          position: Duration(milliseconds: 83500),
          duration: Duration(minutes: 3),
          status: VideoPlaybackStatus.playing,
        ),
      );

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'resume at 83500 playing'], reason: 'not back at the start, nor paused');
    });

    testWidgets('leaves the viewer\'s video alone when there is no file to play', (tester) async {
      // Opened with "Open with", but the temporary copy is gone
      final transient = LocalAsset(
        id: '-1234567',
        name: 'clip.mp4',
        type: AssetType.video,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: .video,
        isEdited: false,
      );
      when(() => storage.getFileForAsset(transient.id)).thenAnswer((_) async => null);
      await pumpTopBar(tester, transient, appConfig: spatialOn);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: 'nothing stopped it, so nothing resumes it');
      verifyNever(() => spatialVideoApi.open(any()));
      expect(find.text('Could not open the Spatial 2.5D player'), findsOneWidget);
    });

    testWidgets('plays a video opened with "Open with" from the file the viewer plays', (tester) async {
      // Not in the library: a transient asset, played from a temporary copy (see ViewIntentAssetResolver)
      const path = '/data/user/0/app.alextran.immich/cache/view_intent/clip 3D #1.sbs.mp4';
      final transient = LocalAsset(
        id: '-1234567',
        name: 'clip 3D #1.sbs.mp4',
        type: AssetType.video,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: .video,
        isEdited: false,
      );
      when(() => timeline.origin).thenReturn(TimelineOrigin.deepLink);
      await pumpTopBar(tester, transient, appConfig: spatialOn);
      ProviderScope.containerOf(
        tester.element(find.byType(ViewerTopAppBar)),
      ).read(viewIntentFilePathProvider.notifier).setPath(path);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'spatial']);
      final request = openedRequest();
      expect(request.url, File(path).uri.toString());
      expect(request.title, transient.name);
      expect(request.layout, SpatialStereoLayout.sideBySide);
      verifyNever(() => storage.getFileForAsset(any()));
      expect(find.text('Could not open the Spatial 2.5D player'), findsNothing);
    });

    testWidgets('takes the video back where the player closed, and remembers the layout picked there', (tester) async {
      final asset = owned(type: .video);
      await pumpTopBar(tester, asset, appConfig: spatialOn);
      // The video viewer keeps its player alive meanwhile
      final container = ProviderScope.containerOf(tester.element(find.byType(ViewerTopAppBar)));
      final subscription = container.listen(videoPlayerProvider(asset.id), (_, _) {});
      addTearDown(subscription.close);
      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      // The native player closes: it calls the Flutter API it was given
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed',
        SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[
          42000,
          true,
          SpatialStereoLayout.topBottom,
          SpatialProjection.flat,
        ]),
        (_) {},
      );
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'spatial', 'resume at 42000 playing']);
      expect(SpatialLayoutOverrides(StoreService.I).get(asset.id), SpatialStereoLayout.topBottom);
    });

    testWidgets('remembers Auto picked over a wrong guess, and opens with it next time', (tester) async {
      // Guessed side by side from its frame
      final asset = owned(type: .video, width: 3840, height: 1080);
      await pumpTopBar(tester, asset, appConfig: spatialOn);
      final container = ProviderScope.containerOf(tester.element(find.byType(ViewerTopAppBar)));
      final subscription = container.listen(videoPlayerProvider(asset.id), (_, _) {});
      addTearDown(subscription.close);
      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      expect(openedRequest().layout, SpatialStereoLayout.sideBySide);

      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed',
        SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[
          0,
          false,
          SpatialStereoLayout.auto,
          SpatialProjection.flat,
        ]),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(SpatialLayoutOverrides(StoreService.I).get(asset.id), SpatialStereoLayout.auto);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      expect(openedRequest().layout, SpatialStereoLayout.auto);
    });

    testWidgets('opens a VR180 video over the front half, and remembers the coverage picked in the player', (
      tester,
    ) async {
      final asset = owned(type: .video, width: 5760, height: 2880, name: 'trip_vr180.mp4');
      await pumpTopBar(tester, asset, projectionType: .equirectangular, appConfig: spatialOn);
      final container = ProviderScope.containerOf(tester.element(find.byType(ViewerTopAppBar)));
      final subscription = container.listen(videoPlayerProvider(asset.id), (_, _) {});
      addTearDown(subscription.close);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      final request = openedRequest();
      expect(request.projection, SpatialProjection.equirectangular180);
      expect(request.layout, SpatialStereoLayout.sideBySide);

      // The user tells the player that the video covers the whole sphere
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed',
        SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[
          0,
          false,
          SpatialStereoLayout.sideBySide,
          SpatialProjection.equirectangular,
        ]),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(StoreService.I.tryGet(StoreKey.sphereCoverageOverrides), '{"${asset.id}":"full"}');
      expect(SpatialLayoutOverrides(StoreService.I).get(asset.id), isNull, reason: 'the layout did not change');

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      expect(openedRequest().projection, SpatialProjection.equirectangular);
    });

    testWidgets('reads what a 360° video declares, and nothing of a flat one', (tester) async {
      probes.result = const SphericalProbe(halfSphere: true, hasSphericalMetadata: true);
      await pumpTopBar(tester, owned(type: .video, width: 5760, height: 2880), appConfig: spatialOn);

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      expect(openedRequest().projection, SpatialProjection.flat);
      expect(probes.probed, isEmpty);

      final asset = owned(type: .video, width: 5760, height: 2880);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, appConfig: spatialOn);
      await tester.tap(spatialButton);
      await tester.pumpAndSettle();
      final request = openedRequest();
      expect(request.projection, SpatialProjection.equirectangular180);
      expect(request.layout, SpatialStereoLayout.sideBySide);
      expect(probes.probed.single.$1, asset);
    });
  });
}
