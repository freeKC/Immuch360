import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
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
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

class _MockTimelineService extends Mock implements TimelineService {}

class _MockSphericalVideoApi extends Mock implements SphericalVideoApi {}

/// Records the viewer's player calls in the same list as the native player calls, to check their order
class _RecordingVideoPlayer extends VideoPlayerNotifier {
  _RecordingVideoPlayer(this._calls);

  final List<String> _calls;

  @override
  Future<void> pause() async => _calls.add('pause');

  @override
  Future<void> suspendForExternalPlayer() async => _calls.add('suspend');

  @override
  Future<void> resumeAfterExternalPlayer() async => _calls.add('resume');
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

void main() {
  late PresentationContext context;
  late _MockTimelineService timeline;
  late _MockSphericalVideoApi sphericalVideoApi;
  late MockStorageRepository storage;
  late List<String> calls;

  setUpAll(() => registerFallbackValue(<String, String>{}));
  late _MockImmersiveApi immersiveApi;

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  setUp(() async {
    context = await PresentationContext.create();
    timeline = _MockTimelineService();
    when(() => timeline.origin).thenReturn(TimelineOrigin.main);
    calls = [];
    sphericalVideoApi = _MockSphericalVideoApi();
    when(() => sphericalVideoApi.open(any(), any(), any(), any(), any())).thenAnswer((_) async => calls.add('open'));
    storage = MockStorageRepository();
    immersiveApi = _MockImmersiveApi();
    when(() => immersiveApi.open(any(), any(), any(), any())).thenAnswer((_) async => calls.add('immersive'));
  });

  tearDown(() async {
    await context.dispose();
  });

  final panoramaButton = find.byTooltip('360°');
  final kebabMenu = find.byIcon(Icons.more_vert_rounded);
  final favoriteButton = find.byType(ImmichIconButton);

  RemoteAsset owned({AssetType type = .image, String? localId}) =>
      RemoteAssetFactory.create(ownerId: context.currentUser.id, type: type, localId: localId);

  /// Pumps the top bar under a real router whose panorama route renders a stub page, so a push can be observed.
  /// [panoramaVideoSupported] tells whether the platform has the native 360° video player.
  Future<RootStackRouter> pumpTopBar(
    WidgetTester tester,
    RemoteAsset asset, {
    ProjectionType? projectionType,
    bool readonly = false,
    bool locked = false,
    bool showingDetails = false,
    bool panoramaVideoSupported = false,
    AppConfig? appConfig,
    bool horizonOs = false,
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
            videoPlayerProvider(asset.id).overrideWith((ref) => _RecordingVideoPlayer(calls)),
            if (appConfig != null) appConfigProvider.overrideWithValue(appConfig),
            isHorizonOsProvider.overrideWith((ref) => horizonOs),
            immersiveApiProvider.overrideWithValue(immersiveApi),
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
      verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any()));
      verifyNever(() => immersiveApi.open(any(), any(), any(), any()));
    });

    testWidgets('stops a video, then plays its transcoded stream in the native 360° player', (tester) async {
      final asset = owned(type: .video);
      final router = await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'open'], reason: 'the viewer must not play nor buffer behind the 360° player');
      final captured = verify(
        () => sphericalVideoApi.open(captureAny(), captureAny(), captureAny(), captureAny(), captureAny()),
      ).captured;
      expect(captured, [
        '${PresentationContext.serverEndpoint}/assets/${asset.id}/video/playback',
        <String, String>{},
        asset.name,
        'Close',
        'Unable to play video',
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

      final url = verify(() => sphericalVideoApi.open(captureAny(), any(), any(), any(), any())).captured.single;
      expect(url, file.uri.toString());
      expect(url, startsWith('file:///'));
    });

    testWidgets('streams from the server when the copy on the phone cannot be read', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => null);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, panoramaVideoSupported: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      final url = verify(() => sphericalVideoApi.open(captureAny(), any(), any(), any(), any())).captured.single;
      expect(url, '${PresentationContext.serverEndpoint}/assets/${asset.id}/video/playback');
    });

    testWidgets('gives the viewer its video back when the native 360° player cannot open', (tester) async {
      when(
        () => sphericalVideoApi.open(any(), any(), any(), any(), any()),
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

      final url = verify(() => sphericalVideoApi.open(captureAny(), any(), any(), any(), any())).captured.single;
      expect(url, '${PresentationContext.serverEndpoint}/assets/${asset.id}/original');
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
        () => immersiveApi.open('$server/assets/${asset.id}/original?edited=true', any(), false, asset.name),
      ).called(1);
      expect(router.current.name, isNot(PanoramaViewerRoute.name), reason: 'the 2D panorama viewer is not used');
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
        verify(() => immersiveApi.open('$server/assets/${asset.id}/original', any(), true, asset.name)).called(1);
        verifyNever(() => sphericalVideoApi.open(any(), any(), any(), any(), any()));
      }
    });

    testWidgets('plays the copy on the headset in the immersive viewer, like the viewer', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      final file = File('/storage/emulated/0/Oculus/VideoShots/VID_360.mp4');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(() => immersiveApi.open(file.uri.toString(), any(), true, asset.name)).called(1);
    });

    testWidgets('opens the original when the copy on the headset cannot be read', (tester) async {
      final asset = owned(type: .video, localId: 'local-1');
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => null);
      await pumpTopBar(tester, asset, projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      verify(() => immersiveApi.open('$server/assets/${asset.id}/original', any(), true, asset.name)).called(1);
    });

    testWidgets('gives the viewer its video back when the immersive viewer cannot open', (tester) async {
      when(() => immersiveApi.open(any(), any(), any(), any())).thenThrow(PlatformException(code: 'channel-error'));
      await pumpTopBar(tester, owned(type: .video), projectionType: .equirectangular, horizonOs: true);

      await tester.tap(panoramaButton);
      await tester.pumpAndSettle();

      expect(calls, ['suspend', 'resume']);
      expect(find.text('Could not open the immersive viewer'), findsOneWidget);
    });
  });
}
