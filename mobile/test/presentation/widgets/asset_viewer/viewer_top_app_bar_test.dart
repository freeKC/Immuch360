import 'dart:async';
import 'dart:convert';
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
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spatial_video.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
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

class _MockVideoDecoderApi extends Mock implements VideoDecoderApi {}

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

/// The nominal calibration of an X3 for every raw file, recording the assets asked for
class _NominalCalibrations extends DualFisheyeCalibrationService {
  _NominalCalibrations()
    : super(
        store: DualFisheyeCalibrationStore(() async => null),
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  final asked = <BaseAsset>[];
  final askedInputs = <String>[];

  @override
  Future<DualFisheyeCalibration> forAsset(BaseAsset asset, {File? localFile}) async {
    asked.add(asset);
    return nominalX3(2880);
  }

  @override
  Future<DualFisheyeCalibration> forInput(RawVideoInput input, {int? frameSquare}) async {
    askedInputs.add(input.key);
    return nominalX3(frameSquare ?? 2880);
  }

  @override
  Future<RawFileReader?> openAsset(BaseAsset asset, {File? localFile}) async => null;
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
  late _NominalCalibrations calibrations;
  late MockLocalAssetRepository noSiblingsOnDevice;
  late MockRemoteAssetRepository noSiblingsOnServer;
  late _MockVideoDecoderApi decoderApi;
  late List<String> calls;
  // Preview requests of the immersive viewer, and the XMP the preview carries: none by default
  late List<Uri> previewRequests;
  String? previewXmp;
  // The size requests asked before a switch to the transcoded stream, and the sizes the server gives: a transcoded
  // stream of its own by default
  late List<http.Request> sizeRequests;
  var originalSize = 1000;
  var transcodedSize = 100;

  setUpAll(() => registerFallbackValue(<String, String>{}));
  late _MockImmersiveApi immersiveApi;
  // The URLs the immersive viewer was opened with, in order, and the opening ids it was given with them
  late List<String> immersiveUrls;
  late List<int> immersiveOpeningIds;

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
  // The audio track control of the native video players, with the language of the app to name the track languages in
  const englishAudioTrackLabels = {
    'audioTrack': 'Audio track',
    'audioTrackDefault': 'Default',
    'audioTrackNumber': 'Track {track}',
    'audioTrackMono': 'Mono',
    'audioTrackStereo': 'Stereo',
    'audioTrackChannels': '{channels} channels',
    'audioTrackLocale': 'en',
  };
  // The buffering indicator of the native video players, which fill in the percentage
  const englishBufferingLabels = {'buffering': 'Buffering {percent}%'};
  // The message of a switch to the transcoded stream of the native video players, which fill in the track they could
  // not decode
  const englishSourceLabels = {
    'sourceSwitched':
        'Playing the transcoded stream: the original ({codec} {width} x {height}) exceeds what this '
        'device decodes',
  };
  // The messages of the native 360° players about raw videos: the decoders may not keep up with the two streams, then
  // what the player shows when it falls back, the codec and the frame size of a lens left for it to fill in
  const englishRawLabels = {
    'rawHeavy':
        'This raw video needs two {width}x{height} video decoders at once: it may not play smoothly on this device.',
    'rawOneLensDecoder':
        'This device cannot decode the two lenses of this video at once ({codec} {width}x{height}, twice). It shows '
        'one lens: half of the sphere stays black.',
    'rawOneLensFile': 'The file of the other lens cannot be read. One lens shows: half of the sphere stays black.',
    'rawUnstitched': 'The 360° stitching failed on this device. The video shows as the camera recorded it.',
  };
  const englishVideoPlayerLabels = {
    ...englishViewerLabels,
    ...englishAudioTrackLabels,
    ...englishBufferingLabels,
    ...englishSourceLabels,
    ...englishRawLabels,
  };

  setUp(() async {
    context = await PresentationContext.create();
    timeline = _MockTimelineService();
    when(() => timeline.origin).thenReturn(TimelineOrigin.main);
    calls = [];
    sphericalVideoApi = _MockSphericalVideoApi();
    when(
      () => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
    ).thenAnswer((_) async => calls.add('open'));
    spatialVideoApi = _MockSpatialVideoApi();
    when(
      spatialVideoApi.capabilities,
    ).thenAnswer((_) async => SpatialCapabilities(supported: true, frontCamera: true, cameraPermissionGranted: false));
    when(() => spatialVideoApi.open(any())).thenAnswer((_) async => calls.add('spatial'));
    storage = MockStorageRepository();
    probes = _FakeSphericalProbes();
    calibrations = _NominalCalibrations();
    noSiblingsOnDevice = MockLocalAssetRepository();
    noSiblingsOnServer = MockRemoteAssetRepository();
    when(() => noSiblingsOnDevice.findSiblingByName(any(), any())).thenAnswer((_) async => null);
    when(() => noSiblingsOnServer.findSiblingByName(any(), any())).thenAnswer((_) async => null);
    // The device decodes every video, unless a test says otherwise
    decoderApi = _MockVideoDecoderApi();
    when(
      () => decoderApi.canDecode(any(), any(), any(), any(), any(), any(), any(), instances: any(named: 'instances')),
    ).thenAnswer((_) async => DecodeVerdict(supported: true, hardware: true, maxWidth: 8192, maxHeight: 4320));
    immersiveApi = _MockImmersiveApi();
    immersiveUrls = [];
    immersiveOpeningIds = [];
    Future<void> openImmersive(Invocation invocation) async {
      calls.add('immersive');
      immersiveUrls.add(invocation.positionalArguments[0] as String);
      immersiveOpeningIds.add(invocation.positionalArguments[8] as int);
    }

    when(
      () => immersiveApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
    ).thenAnswer(openImmersive);
    previewRequests = [];
    previewXmp = null;
    sizeRequests = [];
    originalSize = 1000;
    transcodedSize = 100;
  });

  tearDown(() async {
    await StoreService.I.delete(StoreKey.spatialLayoutOverrides);
    await StoreService.I.delete(StoreKey.forcedPanoramaAssets);
    await StoreService.I.delete(StoreKey.sphereCoverageOverrides);
    await StoreService.I.delete(StoreKey.advancedTroubleshooting);
    await context.dispose();
  });

  /// The immersive viewer closes on the media it opened last, with [coverage], a video at [positionMs]: it calls the
  /// Flutter API of the app window, with the opening id it was given, or [openingId]
  Future<void> closeImmersiveViewer(
    WidgetTester tester,
    ImmersiveSphereCoverage coverage, {
    int positionMs = 0,
    int? openingId,
  }) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'dev.flutter.pigeon.immich_mobile.ImmersiveEvents.closed',
      ImmersiveEvents.pigeonChannelCodec.encodeMessage(<Object?>[
        openingId ?? immersiveOpeningIds.last,
        immersiveUrls.last,
        ImmersiveStereoLayout.mono,
        coverage,
        positionMs,
      ]),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

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
            dualFisheyeCalibrationServiceProvider.overrideWithValue(calibrations),
            // The players of the phones and the headset play two streams; the test runs on neither. No other file of
            // a split pair on the device nor on the server.
            rawVideoPlaybackSupportProvider.overrideWithValue(const RawVideoPlaybackSupport(twoStreams: true)),
            rawAssetInputsProvider.overrideWith(
              (ref) => RawAssetInputs(
                local: () => noSiblingsOnDevice,
                remote: () => noSiblingsOnServer,
                storage: storage,
                probes: probes,
                calibrations: calibrations,
              ),
            ),
            videoPlayerProvider(asset.id).overrideWith((ref) => _RecordingVideoPlayer(calls, initial: playerState)),
            spatialVideoApiProvider.overrideWithValue(spatialVideoApi),
            videoDecoderApiProvider.overrideWithValue(decoderApi),
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
            videoSourceClientProvider.overrideWithValue(
              MockClient((request) async {
                sizeRequests.add(request);
                final size = request.url.path.endsWith('/original') ? originalSize : transcodedSize;
                return http.Response('', 200, headers: {'content-length': '$size'});
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
      verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
      verifyNever(() => immersiveApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
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
          any(),
          any(),
        ),
      ).captured;
      expect(captured, [
        '${PresentationContext.serverEndpoint}/assets/${asset.id}/video/playback',
        <String, String>{},
        asset.name,
        'Close',
        'Unable to play video',
        StereoLayout.mono,
        englishVideoPlayerLabels,
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
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
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
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
      ).captured.single;
      expect(url, '${PresentationContext.serverEndpoint}/assets/${asset.id}/video/playback');
    });

    testWidgets('gives the viewer its video back when the native 360° player cannot open', (tester) async {
      when(
        () => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
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
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
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
          () => sphericalVideoApi.open(
            any(),
            any(),
            any(),
            any(),
            any(),
            captureAny(),
            captureAny(),
            captureAny(),
            any(),
            any(),
          ),
        ).captured;
        expect(captured, [expected, englishVideoPlayerLabels, SphereCoverage.full], reason: '$width x $height');
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
        () =>
            sphericalVideoApi.open(any(), any(), any(), any(), any(), captureAny(), any(), captureAny(), any(), any()),
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
        () =>
            sphericalVideoApi.open(any(), any(), any(), any(), any(), captureAny(), any(), captureAny(), any(), any()),
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
        () =>
            sphericalVideoApi.open(any(), any(), any(), any(), any(), captureAny(), any(), captureAny(), any(), any()),
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
        verify(
          () => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), captureAny(), any(), any()),
        ).captured,
        [SphereCoverage.full, SphereCoverage.half],
        reason: 'opens with the coverage picked last time',
      );
      await closePlayer(SphereCoverage.full);

      expect(StoreService.I.tryGet(StoreKey.sphereCoverageOverrides), '{}');
    });
  });

  group('ViewerTopAppBar 360 button for the raw files of Insta360 cameras', () {
    const unsupportedMessage =
        'This recording is split in two files, one per lens, and VID_20240908_133036_00_002.insv was not found next '
        'to it. Keep both files together (same folder, or both on the server), or export the video from the camera '
        'app.';

    testWidgets('is shown for a .insp photo the server flags nothing for, and opens the panorama viewer', (
      tester,
    ) async {
      final asset = owned(name: 'IMG_20240908_133036_00_001.insp', width: 11968, height: 5984);
      final router = await pumpTopBar(tester, asset, projectionType: .none);

      expect(panoramaButton, findsOneWidget);
      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(router.current.name, PanoramaViewerRoute.name);
    });

    testWidgets('plays a side by side .insv in the native 360° player with its calibration, as one picture', (
      tester,
    ) async {
      final asset = owned(type: .video, name: 'VID_20240908_133036_00_002.insv', width: 5760, height: 2880);
      await pumpTopBar(tester, asset, projectionType: .none, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final captured = verify(
        () => sphericalVideoApi.open(
          any(),
          any(),
          any(),
          any(),
          any(),
          captureAny(),
          any(),
          captureAny(),
          any(),
          captureAny(),
        ),
      ).captured;
      expect(captured[0], StereoLayout.mono);
      expect(captured[1], SphereCoverage.full);
      final json = jsonDecode(captured[2] as String) as Map;
      expect(json['kind'], 'dualFisheye');
      expect((json['version'], json['layout']), (2, 'sideBySide'));
      expect((json['frameWidth'], json['frameHeight']), (5760, 2880));
      expect(calibrations.askedInputs, hasLength(1));
    });

    testWidgets('says which file of a split recording is missing, and opens nothing', (tester) async {
      final asset = owned(type: .video, name: 'VID_20240908_133036_10_002.insv', width: 2880, height: 2880);
      await pumpTopBar(tester, asset, projectionType: .none, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(find.text(unsupportedMessage), findsOneWidget);
      expect(calls, isEmpty, reason: 'the viewer keeps playing');
      verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
    });

    testWidgets('says so too when the file declares one lens though the server gave no size', (tester) async {
      probes.result = const SphericalProbe(
        codec: 'hvc1',
        codedWidth: 2880,
        codedHeight: 2880,
        tracks: [ProbedTrack(index: 0, handlerType: 'vide', codec: 'hvc1', codedWidth: 2880, codedHeight: 2880)],
      );
      final asset = owned(type: .video, name: 'VID_20240908_133036_10_002.insv');
      await pumpTopBar(tester, asset, projectionType: .none, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(find.text(unsupportedMessage), findsOneWidget);
      verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
    });

    testWidgets('opens a raw video in the immersive viewer of a Meta Quest with its calibration', (tester) async {
      final asset = owned(type: .video, name: 'VID_20240908_133036_00_002.insv', width: 5760, height: 2880);
      await pumpTopBar(tester, asset, projectionType: .none, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final captured = verify(
        () =>
            immersiveApi.open(any(), any(), true, any(), captureAny(), any(), any(), any(), any(), any(), captureAny()),
      ).captured;
      expect(captured[0], ImmersiveStereoLayout.mono);
      expect((jsonDecode(captured[1] as String) as Map)['frameWidth'], 5760);
    });

    testWidgets('says which file of a split recording is missing on a Meta Quest too', (tester) async {
      final asset = owned(type: .video, name: 'VID_20240908_133036_10_002.insv', width: 2880, height: 2880);
      await pumpTopBar(tester, asset, projectionType: .none, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(find.text(unsupportedMessage), findsOneWidget);
      verifyNever(() => immersiveApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
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
          any(),
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
          () => immersiveApi.open(
            any(),
            any(),
            any(),
            any(),
            captureAny(),
            captureAny(),
            captureAny(),
            any(),
            any(),
            any(),
            any(),
          ),
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
        () => immersiveApi.open(any(), any(), any(), any(), captureAny(), any(), any(), any(), any(), any(), any()),
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
        () => immersiveApi.open(any(), any(), any(), any(), captureAny(), any(), any(), any(), any(), any(), any()),
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
          () => immersiveApi.open(
            any(),
            any(),
            any(),
            any(),
            captureAny(),
            any(),
            captureAny(),
            any(),
            any(),
            any(),
            any(),
          ),
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
        () => immersiveApi.open(
          any(),
          any(),
          any(),
          any(),
          captureAny(),
          any(),
          captureAny(),
          any(),
          any(),
          any(),
          any(),
        ),
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
          () => immersiveApi.open(
            '$server/assets/${asset.id}/original',
            any(),
            true,
            asset.name,
            any(),
            any(),
            any(),
            any(),
            any(),
            any(),
            any(),
          ),
        ).called(1);
        verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
      }
    });

    testWidgets('plays the copy on the headset in the immersive viewer, like the viewer', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      final file = File('/storage/emulated/0/Oculus/VideoShots/VID_360.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(
        () => immersiveApi.open(
          file.uri.toString(),
          any(),
          true,
          asset.name,
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
        ),
      ).called(1);
    });

    testWidgets('opens the original when the copy on the headset cannot be read', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => null);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(
        () => immersiveApi.open(
          '$server/assets/${asset.id}/original',
          any(),
          true,
          asset.name,
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
        ),
      ).called(1);
    });

    testWidgets('carries a video on in the immersive viewer from where the viewer plays it, and takes it back where '
        'the immersive viewer stopped', (tester) async {
      for (final (status, expected) in [
        (VideoPlaybackStatus.playing, 12000),
        (VideoPlaybackStatus.paused, 12000),
        (VideoPlaybackStatus.completed, 0),
      ]) {
        calls.clear();
        clearInteractions(immersiveApi);
        final asset = owned(type: .video);
        await pumpTopBar(
          tester,
          asset,
          projectionType: .equirectangular,
          horizonOs: true,
          playerState: VideoPlayerState(
            position: const Duration(seconds: 12),
            duration: const Duration(minutes: 1),
            status: status,
          ),
        );

        // The video viewer keeps its player alive meanwhile
        final container = ProviderScope.containerOf(tester.element(find.byType(ViewerTopAppBar)));
        final subscription = container.listen(videoPlayerProvider(asset.id), (_, _) {});
        await tester.tap(panoramaButton);
        await tester.pumpAndSettle();

        final startPosition = verify(
          () =>
              immersiveApi.open(any(), any(), true, asset.name, any(), any(), any(), captureAny(), any(), any(), any()),
        ).captured.single;
        expect(startPosition, expected, reason: '$status');

        await closeImmersiveViewer(tester, ImmersiveSphereCoverage.full, positionMs: 30000);
        expect(calls, ['suspend', 'immersive', 'resume at 30000 paused'], reason: '$status');
        subscription.close();
      }
    });

    testWidgets('takes the video back only for the immersive viewer it opened last', (tester) async {
      final asset = owned(type: .video);
      await pumpTopBar(
        tester,
        asset,
        projectionType: .equirectangular,
        horizonOs: true,
        playerState: const VideoPlayerState(
          position: Duration(seconds: 12),
          duration: Duration(minutes: 1),
          status: VideoPlaybackStatus.paused,
        ),
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(ViewerTopAppBar)));
      final subscription = container.listen(videoPlayerProvider(asset.id), (_, _) {});
      addTearDown(subscription.close);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();
      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();
      final [first, second] = immersiveOpeningIds;
      expect(second, isNot(first), reason: 'each opening has its own id');

      // The first viewer closes long after the second one replaced it
      await closeImmersiveViewer(tester, ImmersiveSphereCoverage.half, positionMs: 5000, openingId: first);
      expect(calls, ['suspend', 'immersive', 'suspend', 'immersive']);
      expect(container.read(sphereCoverageOverridesProvider.notifier).get(asset), isNull);

      await closeImmersiveViewer(tester, ImmersiveSphereCoverage.full, positionMs: 30000);
      expect(calls, ['suspend', 'immersive', 'suspend', 'immersive', 'resume at 30000 paused']);
    });

    testWidgets('remembers the coverage the user picked in the immersive viewer', (tester) async {
      final asset = owned(width: 6080, height: 3040);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();
      await closeImmersiveViewer(tester, ImmersiveSphereCoverage.half);

      final container = ProviderScope.containerOf(tester.element(find.byType(ViewerTopAppBar)));
      expect(container.read(sphereCoverageOverridesProvider.notifier).get(asset), SphereCoverage.half);
      expect(calls, ['immersive'], reason: 'no video to give back');
    });

    testWidgets('gives the viewer its video back where and as it was when the immersive viewer cannot open', (
      tester,
    ) async {
      when(
        () => immersiveApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
      ).thenThrow(PlatformException(code: 'channel-error'));
      await pumpTopBar(
        tester,
        owned(type: .video),
        projectionType: .equirectangular,
        horizonOs: true,
        playerState: const VideoPlayerState(
          position: Duration(milliseconds: 83500),
          duration: Duration(minutes: 2),
          status: VideoPlaybackStatus.playing,
        ),
      );

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      // Stopped before the slow steps, the video does not start over
      expect(calls, ['suspend', 'resume at 83500 playing']);
      expect(find.text('Could not open the immersive viewer'), findsOneWidget);
    });
  });

  group('ViewerTopAppBar 360 button on a Meta Quest, for a media only on the headset', () {
    LocalAsset onHeadset({AssetType type = .image, int? width, int? height}) => LocalAsset(
      id: 'local-1',
      name: type == AssetType.video ? 'VID_360.mp4' : 'IMG_360.jpg',
      type: type,
      width: width,
      height: height,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      playbackStyle: type == AssetType.video ? .video : .image,
      isEdited: false,
    );

    testWidgets('is shown for a video too, without the native 360° player of phones', (tester) async {
      final asset = onHeadset(type: .video);
      await pumpTopBar(tester, asset, forcedPanoramas: {asset.id}, horizonOs: true);

      expect(panoramaButton, findsOneWidget);
    });

    testWidgets('opens a photo in the immersive viewer from its file', (tester) async {
      final asset = onHeadset();
      final file = File('/storage/emulated/0/Pictures/IMG 360 #1.jpg');
      when(() => storage.getFileForAsset(asset.id)).thenAnswer((_) async => file);
      final router = await pumpTopBar(tester, asset, forcedPanoramas: {asset.id}, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(
        () => immersiveApi.open(
          file.uri.toString(),
          any(),
          false,
          asset.name,
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
        ),
      ).called(1);
      expect(file.uri.toString(), startsWith('file:///'));
      expect(router.current.name, isNot(PanoramaViewerRoute.name), reason: 'the 2D panorama viewer is not used');
      expect(previewRequests, isEmpty, reason: 'nothing to ask the server');
    });

    testWidgets('stops a video, then plays it in the immersive viewer from its file, as the file declares', (
      tester,
    ) async {
      probes.result = const SphericalProbe(halfSphere: true, hasSphericalMetadata: true);
      final asset = onHeadset(type: .video, width: 4096, height: 2048);
      final file = File('/storage/emulated/0/Oculus/VideoShots/VID_360.mp4');
      when(() => storage.getFileForAsset(asset.id)).thenAnswer((_) async => file);
      await pumpTopBar(tester, asset, forcedPanoramas: {asset.id}, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'immersive']);
      final captured = verify(
        () => immersiveApi.open(
          file.uri.toString(),
          any(),
          true,
          asset.name,
          captureAny(),
          any(),
          captureAny(),
          any(),
          any(),
          any(),
          any(),
        ),
      ).captured;
      expect(captured, [ImmersiveStereoLayout.leftRight, ImmersiveSphereCoverage.half]);
      expect(probes.probed, [(asset, file)], reason: 'probed from the file it plays');
    });

    testWidgets('reads the GPano crop of a photo that looks 3D from its file, at its head or at its tail', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('immersive_viewer_test');
      addTearDown(() => directory.deleteSync(recursive: true));
      // A 4:1 band of the sphere, which its dimensions alone would take for a side by side 3D photo
      const band =
          '<rdf:Description GPano:FullPanoWidthPixels="8704" GPano:FullPanoHeightPixels="4352" '
          'GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="1088" '
          'GPano:CroppedAreaImageWidthPixels="8704" GPano:CroppedAreaImageHeightPixels="2176"/>';
      // The left eye of a Google VR180 photo, which its dimensions alone would take for a top and bottom 3D photo
      const halfSphere =
          '<rdf:Description GPano:FullPanoWidthPixels="8192" GPano:FullPanoHeightPixels="4096" '
          'GPano:CroppedAreaLeftPixels="2048" GPano:CroppedAreaTopPixels="0" '
          'GPano:CroppedAreaImageWidthPixels="4096" GPano:CroppedAreaImageHeightPixels="4096"/>';
      final padding = List.filled(300000, 0x20);
      for (final (width, height, content, coverage) in [
        // JPEG keeps its XMP at the head of the file
        (8704, 2176, [...band.codeUnits, ...padding], ImmersiveSphereCoverage.full),
        // Past the head window, at the tail
        (4096, 4096, [...padding, ...halfSphere.codeUnits], ImmersiveSphereCoverage.half),
      ]) {
        calls.clear();
        clearInteractions(immersiveApi);
        final asset = onHeadset(width: width, height: height);
        final file = File('${directory.path}/IMG_${width}x$height.jpg')..writeAsBytesSync(content);
        when(() => storage.getFileForAsset(asset.id)).thenAnswer((_) async => file);
        await pumpTopBar(tester, asset, forcedPanoramas: {asset.id}, horizonOs: true);

        // The file is read for real, away from the fake clock of the test, until the viewer opens
        await tester.runAsync(() async {
          await tester.tap(panoramaButton);
          for (var i = 0; i < 200 && calls.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();

        final captured = verify(
          () => immersiveApi.open(
            file.uri.toString(),
            any(),
            false,
            asset.name,
            captureAny(),
            any(),
            captureAny(),
            any(),
            any(),
            any(),
            any(),
          ),
        ).captured;
        expect(captured, [ImmersiveStereoLayout.mono, coverage], reason: '$width x $height');
      }
      expect(previewRequests, isEmpty);
    });

    testWidgets('opens a photo opened with "Open with" from its temporary copy', (tester) async {
      // Not in the library: a transient asset, with a temporary copy (see ViewIntentAssetResolver)
      const path = '/data/user/0/app.alextran.immich/cache/view_intent/IMG 360 #1.jpg';
      final transient = LocalAsset(
        id: '-1234567',
        name: 'IMG 360 #1.jpg',
        type: AssetType.image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: .image,
        isEdited: false,
      );
      when(() => timeline.origin).thenReturn(TimelineOrigin.deepLink);
      await pumpTopBar(tester, transient, forcedPanoramas: {transient.id}, horizonOs: true);
      ProviderScope.containerOf(
        tester.element(find.byType(ViewerTopAppBar)),
      ).read(viewIntentFilePathProvider.notifier).setPath(path);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(
        () => immersiveApi.open(
          File(path).uri.toString(),
          any(),
          false,
          transient.name,
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
        ),
      ).called(1);
      verifyNever(() => storage.getFileForAsset(any()));
    });

    testWidgets('stops the video before looking for its file, and starts the immersive viewer where it stopped', (
      tester,
    ) async {
      final asset = onHeadset(type: .video);
      final file = Completer<File?>();
      when(() => storage.getFileForAsset(asset.id)).thenAnswer((_) => file.future);
      await pumpTopBar(
        tester,
        asset,
        forcedPanoramas: {asset.id},
        horizonOs: true,
        playerState: const VideoPlayerState(
          position: Duration(seconds: 12),
          duration: Duration(minutes: 1),
          status: VideoPlaybackStatus.playing,
        ),
      );

      await tester.tap(panoramaButton);
      await tester.pump();
      expect(calls, ['suspend'], reason: 'the copy on the headset may take a while to find');

      file.complete(File('/storage/emulated/0/Oculus/VideoShots/VID_360.mp4'));
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'immersive']);
      final startPosition = verify(
        () => immersiveApi.open(any(), any(), true, asset.name, any(), any(), any(), captureAny(), any(), any(), any()),
      ).captured.single;
      expect(startPosition, 12000);
    });

    testWidgets('says so and gives the video back where and as it was when its file cannot be read', (tester) async {
      final asset = onHeadset(type: .video);
      when(() => storage.getFileForAsset(asset.id)).thenAnswer((_) async => null);
      await pumpTopBar(tester, asset, forcedPanoramas: {asset.id}, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      // Stopped before the file is looked for, so that the immersive viewer starts where the video was
      expect(calls, ['suspend', 'resume at 0 paused']);
      verifyNever(() => immersiveApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
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

      verify(
        () => immersiveApi.open(any(), any(), false, asset.name, any(), any(), any(), any(), any(), any(), any()),
      ).called(1);
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
        () => sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any(), any(), any()),
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
      verify(
        () => immersiveApi.open(any(), any(), false, asset.name, any(), any(), any(), any(), any(), any(), any()),
      ).called(1);
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
      ...englishAudioTrackLabels,
      ...englishBufferingLabels,
      ...englishSourceLabels,
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
      verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any(), any(), any(), any(), any(), any()));
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

  group('ViewerTopAppBar for a photo only on the device, in a session without a server', () {
    LocalAsset onDevice() => LocalAsset(
      id: 'local-1',
      name: 'IMG_0001.jpg',
      type: AssetType.image,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      playbackStyle: .image,
      isEdited: false,
    );

    setUp(() async {
      // Nobody is signed in, and the session is the one the login page starts without a server
      when(context.service.user.tryGetMyUser).thenReturn(null);
      await StoreService.I.put(StoreKey.localSession, true);
    });

    tearDown(() => StoreService.I.delete(StoreKey.localSession));

    testWidgets('shows no favorite and no upload, and keeps the menu, with nobody signed in', (tester) async {
      await pumpTopBar(tester, onDevice());

      expect(tester.takeException(), isNull);
      expect(favoriteButton, findsNothing);
      await tester.tap(kebabMenu);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Slideshow'), findsOneWidget);
      expect(find.text('View as 360°'), findsOneWidget);
      for (final label in ['Upload', 'Archive', 'Move to locked folder']) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('opens a photo chosen as 360° in the panorama viewer', (tester) async {
      final asset = onDevice();
      final router = await pumpTopBar(tester, asset, forcedPanoramas: {asset.id});

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(router.current.name, PanoramaViewerRoute.name);
      expect(router.current.argsAs<PanoramaViewerRouteArgs>().asset, asset);
    });
  });

  group('ViewerTopAppBar video source', () {
    const server = PresentationContext.serverEndpoint;
    // An 8K HEVC 360° video, beyond the decoders of a Meta Quest 3
    const probe8k = SphericalProbe(
      hasSphericalMetadata: true,
      codec: 'hvc1',
      codecs: 'hvc1.1.6.L183',
      codedWidth: 7680,
      codedHeight: 3840,
      frameRate: 30,
    );
    // The frame size without grouping separators, as the native players write it
    const switchedMessage =
        'Playing the transcoded stream: the original (HEVC 7680 x 3840) exceeds what this device decodes';
    const forcedMessage = 'Playing the original although it exceeds what this device decodes (HEVC 7680 x 3840)';
    final spatialButton = find.byTooltip('Spatial 2.5D');

    void cannotDecode() =>
        when(
          () =>
              decoderApi.canDecode(any(), any(), any(), any(), any(), any(), any(), instances: any(named: 'instances')),
        ).thenAnswer(
          (_) async => DecodeVerdict(supported: false, hardware: true, maxWidth: 4096, maxHeight: 4096, reason: 'test'),
        );

    /// The URL and the stream to fall back to that the immersive viewer was opened with
    (String, String?) immersiveOpened() {
      final captured = verify(
        () => immersiveApi.open(
          captureAny(),
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          captureAny(),
          any(),
        ),
      ).captured;
      return (captured[0] as String, captured[1] as String?);
    }

    /// The URL and the stream to fall back to that the native 360° player was opened with
    (String, String?) sphericalOpened() {
      final captured = verify(
        () =>
            sphericalVideoApi.open(captureAny(), any(), any(), any(), any(), any(), any(), any(), captureAny(), any()),
      ).captured;
      return (captured[0] as String, captured[1] as String?);
    }

    testWidgets('opens the original in the immersive viewer, with the transcoded stream to fall back to', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(immersiveOpened(), ('$server/assets/${asset.id}/original', '$server/assets/${asset.id}/video/playback'));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('leaves the switch to the immersive viewer when the headset cannot decode the original', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      cannotDecode();
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      // The viewer checks its decoders at the first frames and says so in the headset, where a message of the app
      // would stay hidden
      expect(immersiveOpened(), ('$server/assets/${asset.id}/original', '$server/assets/${asset.id}/video/playback'));
      verifyNever(
        () => decoderApi.canDecode(any(), any(), any(), any(), any(), any(), any(), instances: any(named: 'instances')),
      );
      expect(find.byType(SnackBar), findsNothing);
      // Only the sizes are asked, to hand out the transcoded stream when it is a file of its own
      expect(sizeRequests, isNotEmpty);
    });

    testWidgets('opens the original in the immersive viewer when the user asks for it, and says it may not play', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      cannotDecode();
      await pumpTopBar(
        tester,
        asset,
        projectionType: .equirectangular,
        horizonOs: true,
        appConfig: const AppConfig(viewer: ViewerConfig(videoSource: .alwaysOriginal)),
      );

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(immersiveOpened(), ('$server/assets/${asset.id}/original', null));
      expect(find.text(forcedMessage), findsOneWidget);
    });

    testWidgets('opens the transcoded stream in the immersive viewer when the user picks it, without any check', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      await pumpTopBar(
        tester,
        asset,
        projectionType: .equirectangular,
        horizonOs: true,
        appConfig: const AppConfig(viewer: ViewerConfig(videoSource: .alwaysTranscoded)),
      );

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(immersiveOpened(), ('$server/assets/${asset.id}/video/playback', null));
      verifyNever(
        () => decoderApi.canDecode(any(), any(), any(), any(), any(), any(), any(), instances: any(named: 'instances')),
      );
    });

    testWidgets('keeps the original in the immersive viewer when the decoder check fails', (tester) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      when(
        () => decoderApi.canDecode(any(), any(), any(), any(), any(), any(), any(), instances: any(named: 'instances')),
      ).thenThrow(PlatformException(code: 'channel-error'));
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(immersiveOpened(), ('$server/assets/${asset.id}/original', '$server/assets/${asset.id}/video/playback'));
    });

    testWidgets('gives the immersive viewer nothing to fall back to for the copy on the headset', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      final file = File('/storage/emulated/0/Oculus/VideoShots/VID_360.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      probes.result = probe8k;
      cannotDecode();
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(immersiveOpened(), (file.uri.toString(), null));
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('gives the native 360° player the transcoded stream to fall back to when the phone chooses', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      await pumpTopBar(
        tester,
        asset,
        projectionType: .equirectangular,
        panoramaVideoSupported: true,
        appConfig: const AppConfig(viewer: ViewerConfig(loadOriginalVideo: true)),
      );

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(sphericalOpened(), ('$server/assets/${asset.id}/original', '$server/assets/${asset.id}/video/playback'));
    });

    testWidgets('plays the transcoded stream in the native 360° player when the phone cannot decode the original', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      cannotDecode();
      await pumpTopBar(
        tester,
        asset,
        projectionType: .equirectangular,
        panoramaVideoSupported: true,
        appConfig: const AppConfig(viewer: ViewerConfig(videoSource: .preferOriginalWithinDecoder)),
      );

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(sphericalOpened(), ('$server/assets/${asset.id}/video/playback', null));
      expect(find.text(switchedMessage), findsOneWidget);
      expect(
        [for (final request in sizeRequests) (request.method, request.url.toString())],
        unorderedEquals([
          ('HEAD', '$server/assets/${asset.id}/original'),
          ('HEAD', '$server/assets/${asset.id}/video/playback'),
        ]),
        reason: 'the server may have transcoded nothing',
      );
    });

    testWidgets('keeps the original in the native 360° player when the server transcoded nothing, and says it may not '
        'play', (tester) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      cannotDecode();
      transcodedSize = originalSize;
      await pumpTopBar(
        tester,
        asset,
        projectionType: .equirectangular,
        panoramaVideoSupported: true,
        appConfig: const AppConfig(viewer: ViewerConfig(videoSource: .preferOriginalWithinDecoder)),
      );

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(sphericalOpened(), ('$server/assets/${asset.id}/original', null));
      expect(find.text(switchedMessage), findsNothing);
      expect(find.text(forcedMessage), findsOneWidget);
    });

    testWidgets('gives the native 360° player nothing to fall back to when it plays the transcoded stream', (
      tester,
    ) async {
      final asset = owned(type: .video);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(sphericalOpened(), ('$server/assets/${asset.id}/video/playback', null));
    });

    testWidgets('gives the Spatial player the transcoded stream to fall back to, after checking a flat video', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = const SphericalProbe(codec: 'avc1', codedWidth: 3840, codedHeight: 1080, frameRate: 30);
      await pumpTopBar(
        tester,
        asset,
        appConfig: const AppConfig(viewer: ViewerConfig(spatial25d: true, videoSource: .preferOriginalWithinDecoder)),
      );

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      final request = verify(() => spatialVideoApi.open(captureAny())).captured.single as SpatialOpenRequest;
      expect(request.url, '$server/assets/${asset.id}/original');
      expect(request.fallbackUrl, '$server/assets/${asset.id}/video/playback');
      expect(request.projection, SpatialProjection.flat, reason: 'what the file declares of a sphere is not read');
      expect(probes.probed.single.$1, asset);
      verify(() => decoderApi.canDecode('avc1', null, 3840, 1080, 30, 0, 0)).called(1);
    });

    testWidgets('plays the transcoded stream in the Spatial player when the phone cannot decode the original', (
      tester,
    ) async {
      final asset = owned(type: .video);
      probes.result = probe8k;
      cannotDecode();
      await pumpTopBar(
        tester,
        asset,
        appConfig: const AppConfig(viewer: ViewerConfig(spatial25d: true, loadOriginalVideo: true)),
      );

      await tester.tap(spatialButton);
      await tester.pumpAndSettle();

      final request = verify(() => spatialVideoApi.open(captureAny())).captured.single as SpatialOpenRequest;
      expect(request.url, '$server/assets/${asset.id}/video/playback');
      expect(request.fallbackUrl, isNull);
      expect(find.text(switchedMessage), findsOneWidget);
    });
  });
}
