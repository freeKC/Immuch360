// The openers of the native viewers for a media that is no asset, a file of a network share played through the media
// bridge: openSphericalVideoUrl, openSpatialVideoUrl and openImmersiveUrl.

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/video_audio_track.dart';
import 'package:immich_mobile/domain/models/video_buffering.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/spatial_viewer.dart';
import 'package:immich_mobile/providers/asset_viewer/spatial_video.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../../widget_tester_extensions.dart';

class _SphericalVideoApi extends SphericalVideoApi {
  final List<Map<String, Object?>> opened = [];
  Exception? failure;

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    String title,
    String? closeLabel,
    String? errorMessage,
    StereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    SphereCoverage coverage,
  ) async {
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    opened.add({
      'url': url,
      'headers': headers,
      'title': title,
      'close': closeLabel,
      'layout': stereoLayout,
      'labels': stereoLabels,
      'coverage': coverage,
    });
  }
}

class _SpatialVideoApi extends SpatialVideoApi {
  final List<SpatialOpenRequest> opened = [];
  Exception? failure;

  @override
  Future<SpatialCapabilities> capabilities() async =>
      SpatialCapabilities(supported: true, frontCamera: true, cameraPermissionGranted: true);

  @override
  Future<void> open(SpatialOpenRequest request) async {
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    opened.add(request);
  }
}

class _ImmersiveApi extends ImmersiveApi {
  final List<Map<String, Object?>> opened = [];

  /// Where each media opened was asked to start, in milliseconds
  final List<int> startPositions = [];

  /// The opening ids the viewer was given, failed openings included
  final List<int> openingIds = [];
  Exception? failure;

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
  ) async {
    openingIds.add(openingId);
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    opened.add({'url': url, 'isVideo': isVideo, 'title': title, 'layout': stereoLayout, 'coverage': coverage});
    startPositions.add(startPositionMs);
  }
}

class _RecordingVideoPlayer extends VideoPlayerNotifier {
  final calls = <String>[];

  @override
  Future<void> suspendForExternalPlayer() async => calls.add('suspend');

  @override
  Future<void> resumeAfterExternalPlayer() async => calls.add('resume');

  @override
  Future<void> resumeAfterExternalPlayerAt(Duration position, {required bool play}) async =>
      calls.add('resume at ${position.inMilliseconds} ${play ? 'playing' : 'paused'}');
}

const _url = 'http://127.0.0.1:41234/token/nas/clips/trip.mp4';

void main() {
  late Drift db;
  late StoreService store;
  late _SphericalVideoApi sphericalApi;
  late _SpatialVideoApi spatialApi;
  late _ImmersiveApi immersiveApi;
  late _RecordingVideoPlayer player;
  late WidgetRef ref;
  late BuildContext context;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    sphericalApi = _SphericalVideoApi();
    spatialApi = _SpatialVideoApi();
    immersiveApi = _ImmersiveApi();
    player = _RecordingVideoPlayer();
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Consumer(
          builder: (buildContext, widgetRef, _) {
            ref = widgetRef;
            context = buildContext;
            return const SizedBox();
          },
        ),
      ),
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        sphericalVideoApiProvider.overrideWithValue(sphericalApi),
        spatialVideoApiProvider.overrideWithValue(spatialApi),
        immersiveApiProvider.overrideWithValue(immersiveApi),
      ],
    );
  }

  Future<void> closeSpatialPlayer(WidgetTester tester, int positionMs, {required bool playing}) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed',
      SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[
        positionMs,
        playing,
        SpatialStereoLayout.auto,
        SpatialProjection.flat,
      ]),
      (_) {},
    );
    await tester.pump();
  }

  group('openSphericalVideoUrl', () {
    testWidgets('opens the URL in the native 360° player with the layout and the coverage given', (tester) async {
      await pump(tester);

      final opened = await openSphericalVideoUrl(
        context,
        ref,
        url: _url,
        headers: const {'x-test': '1'},
        title: 'trip.mp4',
        layout: StereoLayout.leftRight,
        coverage: SphereCoverage.half,
        player: player,
      );

      expect(opened, isTrue);
      expect(sphericalApi.opened.single, {
        'url': _url,
        'headers': {'x-test': '1'},
        'title': 'trip.mp4',
        'close': 'Close',
        'layout': StereoLayout.leftRight,
        // The labels of the audio track control and of the buffering indicator too, with the language of the app to
        // name the track languages in
        'labels': {
          ...sphereViewerLabels(context.t),
          ...audioTrackLabels(context.t, const Locale('en')),
          ...videoBufferingLabels(context.t),
        },
        'coverage': SphereCoverage.half,
      });
      expect(player.calls, ['suspend'], reason: 'the page lifts this when the app resumes');
    });

    testWidgets('gives the player back when the 360° player does not open', (tester) async {
      await pump(tester);
      sphericalApi.failure = PlatformException(code: 'error');

      final opened = await openSphericalVideoUrl(
        context,
        ref,
        url: _url,
        title: 'trip.mp4',
        layout: StereoLayout.mono,
        coverage: SphereCoverage.full,
        player: player,
      );

      expect(opened, isFalse);
      expect(player.calls, ['suspend', 'resume']);
    });
  });

  group('openSpatialVideoUrl', () {
    testWidgets('opens the URL where the page was, with a layout guessed from the frame and the name', (tester) async {
      await pump(tester);

      final opened = await openSpatialVideoUrl(
        context,
        ref,
        url: _url,
        title: 'trip.mp4',
        width: 3840,
        height: 1080,
        startPosition: const Duration(seconds: 12),
        autoplay: true,
        player: player,
      );

      expect(opened, isTrue);
      final request = spatialApi.opened.single;
      expect(request.url, _url);
      expect(request.title, 'trip.mp4');
      expect(request.layout, SpatialStereoLayout.sideBySide);
      expect(request.projection, SpatialProjection.flat);
      expect(request.startPositionMs, 12000);
      expect(request.autoplay, isTrue);
      // The labels of the audio track control and of the buffering indicator too, with the language of the app to
      // name the track languages in
      expect(request.labels, {
        ...spatialLabels(context.t),
        ...audioTrackLabels(context.t, const Locale('en')),
        ...videoBufferingLabels(context.t),
      });
      expect(request.labels['buffering'], 'Buffering {percent}%', reason: 'the player fills in the percentage');
      expect(request.labels['audioTrackNumber'], 'Track {track}', reason: 'the player fills in the number');
      expect(request.labels['audioTrackChannels'], '{channels} channels', reason: 'the player fills in the count');
      expect(player.calls, ['suspend']);
    });

    testWidgets('opens a 360° video through a viewport over the coverage given, with the layout it declares', (
      tester,
    ) async {
      await pump(tester);

      await openSpatialVideoUrl(
        context,
        ref,
        url: _url,
        title: 'trip_sbs.mp4',
        coverage: SphereCoverage.half,
        declaredStereo: true,
        player: player,
      );

      final request = spatialApi.opened.single;
      expect(request.projection, SpatialProjection.equirectangular180);
      expect(request.layout, SpatialStereoLayout.auto, reason: 'the player reads what the file declares');
    });

    testWidgets('takes the video back where the Spatial player closed, then hands its events back to the session', (
      tester,
    ) async {
      await pump(tester);
      await openSpatialVideoUrl(context, ref, url: _url, title: 'trip.mp4', player: player);

      await closeSpatialPlayer(tester, 42000, playing: true);
      expect(player.calls, ['suspend', 'resume at 42000 playing']);

      // The next closing is for the session of the asset viewer, not for this page
      final session = ref.read(spatialVideoSessionProvider);
      expect(session.isOpen, isFalse);
      await closeSpatialPlayer(tester, 1000, playing: false);
      expect(player.calls, ['suspend', 'resume at 42000 playing']);
    });

    testWidgets('gives the player back where and as it was when the Spatial player does not open', (tester) async {
      await pump(tester);
      spatialApi.failure = PlatformException(code: 'error');

      final opened = await openSpatialVideoUrl(
        context,
        ref,
        url: _url,
        title: 'trip.mp4',
        startPosition: const Duration(seconds: 5),
        autoplay: true,
        player: player,
      );
      await tester.pump();

      expect(opened, isFalse);
      expect(player.calls, ['suspend', 'resume at 5000 playing']);
      expect(find.text('Could not open the Spatial 2.5D player'), findsOneWidget);

      // The events went back to the session
      await closeSpatialPlayer(tester, 1000, playing: false);
      expect(player.calls, ['suspend', 'resume at 5000 playing']);
    });
  });

  group('openImmersiveUrl', () {
    testWidgets('opens the URL in the immersive viewer, the page player stopped meanwhile', (tester) async {
      await pump(tester);

      await openImmersiveUrl(
        ref,
        request: const ImmersiveRequest(
          url: _url,
          isVideo: true,
          title: 'trip.mp4',
          view: (layout: StereoLayout.topBottom, coverage: SphereCoverage.half, coverageGuess: SphereCoverage.full),
        ),
        stereoLabels: const {},
        player: player,
      );

      expect(immersiveApi.opened.single, {
        'url': _url,
        'isVideo': true,
        'title': 'trip.mp4',
        'layout': ImmersiveStereoLayout.topBottom,
        'coverage': ImmersiveSphereCoverage.half,
      });
      expect(player.calls, ['suspend']);
      // The session follows this opening: the viewer sends its id back with its events
      expect(ref.read(immersiveSessionProvider).isCurrent(immersiveApi.openingIds.single), isTrue);
    });

    testWidgets('opens each time as a new opening, the session following the last one only', (tester) async {
      await pump(tester);
      const request = ImmersiveRequest(
        url: _url,
        isVideo: false,
        title: 'trip.jpg',
        view: (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full),
      );

      await openImmersiveUrl(ref, request: request, stereoLabels: const {});
      await openImmersiveUrl(ref, request: request, stereoLabels: const {});

      final [first, second] = immersiveApi.openingIds;
      expect(second, isNot(first));
      final session = ref.read(immersiveSessionProvider);
      expect(session.isCurrent(first), isFalse);
      expect(session.isCurrent(second), isTrue);
    });

    testWidgets('gives the player back and tells when the immersive viewer does not open', (tester) async {
      await pump(tester);
      immersiveApi.failure = PlatformException(code: 'error');

      await expectLater(
        openImmersiveUrl(
          ref,
          request: const ImmersiveRequest(
            url: _url,
            isVideo: true,
            title: 'trip.mp4',
            view: (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full),
          ),
          stereoLabels: const {},
          player: player,
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(player.calls, ['suspend', 'resume']);
      // Nothing will close: the session no longer follows that opening
      final session = ref.read(immersiveSessionProvider);
      expect(session.isCurrent(immersiveApi.openingIds.single), isFalse);
      expect(session.isOpen, isFalse);
    });
  });
}
