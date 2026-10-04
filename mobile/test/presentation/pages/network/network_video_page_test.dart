// The video page against a tiny HTTP server standing in for the media bridge: what the video declares comes from it,
// with real range requests. The native players are fakes that record what they are asked to open.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_video.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_controls.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../../domain/services/spherical_probe_fixtures.dart';
import '../../../fixtures/raw/insta360.stub.dart';
import 'network_viewer_fakes.dart';

class _RecordingSphericalVideoApi extends SphericalVideoApi {
  final List<Map<String, Object?>> opened = [];

  /// The calibration each video was opened with, null for an equirectangular one
  final List<String?> rawProjections = [];

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
    String? fallbackUrl,
    String? rawProjection,
  ) async {
    opened.add({'url': url, 'title': title, 'layout': stereoLayout, 'coverage': coverage});
    rawProjections.add(rawProjection);
  }
}

class _RecordingSpatialVideoApi extends SpatialVideoApi {
  _RecordingSpatialVideoApi({this.supported = true});

  final bool supported;
  final List<SpatialOpenRequest> opened = [];

  @override
  Future<SpatialCapabilities> capabilities() async =>
      SpatialCapabilities(supported: supported, frontCamera: supported, cameraPermissionGranted: supported);

  @override
  Future<void> open(SpatialOpenRequest request) async => opened.add(request);
}

class _RecordingImmersiveApi extends ImmersiveApi {
  final List<Map<String, Object?>> opened = [];

  /// Where each media opened was asked to start, in milliseconds
  final List<int> startPositions = [];

  /// The opening ids the viewer was given, which it sends back with its events
  final List<int> openingIds = [];

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
  ) async {
    opened.add({'url': url, 'isVideo': isVideo, 'title': title, 'layout': stereoLayout, 'coverage': coverage});
    startPositions.add(startPositionMs);
    openingIds.add(openingId);
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
  ) async {
    shown.add({'url': url, 'isVideo': isVideo, 'title': title, 'layout': stereoLayout, 'coverage': coverage});
    return true;
  }
}

/// Records what the page asks of its player, which has no native player behind it here
class _RecordingVideoPlayer extends VideoPlayerNotifier {
  _RecordingVideoPlayer(this.calls, {VideoPlayerState? initial}) {
    if (initial != null) {
      state = initial;
    }
  }

  final List<String> calls;

  @override
  Future<void> suspendForExternalPlayer() async => calls.add('suspend');

  @override
  Future<void> resumeAfterExternalPlayer() async => calls.add('resume');

  @override
  Future<void> resumeAfterExternalPlayerAt(Duration position, {required bool play}) async =>
      calls.add('resume at ${position.inMilliseconds} ${play ? 'playing' : 'paused'}');
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late TestMediaServer server;
  late _RecordingSphericalVideoApi sphericalApi;
  late _RecordingSpatialVideoApi spatialApi;
  late _RecordingImmersiveApi immersiveApi;
  late List<String> playerCalls;
  HttpOverrides? previousOverrides;

  final mono360 = mp4File(
    mp4Moov([
      mp4VideoTrack([mp4Sv3dEquirectangular()]),
      mp4AudioTrack(),
    ]),
    moovAtEnd: true,
  );
  final stereo360 = mp4File(
    mp4Moov([
      mp4VideoTrack([mp4St3d(1), mp4Sv3dEquirectangular()]),
    ]),
  );
  final flat = mp4File(mp4Moov([mp4VideoTrack(const []), mp4AudioTrack()]));
  // Raw X3 videos: both lenses side by side, with the trailer of the camera; one lens, a file of a split recording
  final rawSideBySide = insta360File([
    insta360Record(1, x3Metadata(), format: 1),
  ], body: mp4File(mp4Moov([mp4VideoTrack(const [], width: 5760, height: 2880)])));
  final rawOneLens = mp4File(mp4Moov([mp4VideoTrack(const [], width: 2880, height: 2880)]));

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
    share = MemoryShare(
      _source,
      files: {
        '/trip360.mp4': mono360,
        '/stereo360.mp4': stereo360,
        '/movie_sbs.mp4': flat,
        '/holiday.mp4': flat,
        '/VID_20240908_00_002.insv': rawSideBySide,
        '/VID_20240908_10_003.insv': rawOneLens,
      },
    );
    server.share = share;
    server.requests.clear();
    // The native video view: created, with nothing behind it
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      return switch (call.method) {
        'create' => 0,
        'resize' => {'width': (call.arguments as Map)['width'], 'height': (call.arguments as Map)['height']},
        _ => null,
      };
    });
    // The page player keeps the screen on while it plays, and lets it go when it is disposed
    messenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
    sphericalApi = _RecordingSphericalVideoApi();
    spatialApi = _RecordingSpatialVideoApi();
    immersiveApi = _RecordingImmersiveApi();
    playerCalls = [];
  });

  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMessageHandler('dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle', null);
    await store.dispose();
    await db.close();
  });

  Future<void> pumpVideoPage(
    WidgetTester tester,
    String path, {
    bool isHorizonOs = false,
    bool spatial25d = true,
    _RecordingSpatialVideoApi? spatial,
    NetworkFolderMedia? folder,
    VideoPlayerState? playerState,
  }) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkVideoPage(sourceId: _source.id, path: path, folder: folder),
      settle: false,
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share, baseUrl: server.baseUrl)),
        appConfigProvider.overrideWithValue(AppConfig(viewer: ViewerConfig(spatial25d: spatial25d))),
        isHorizonOsProvider.overrideWith((ref) async => isHorizonOs),
        panorama360VideoSupportedProvider.overrideWithValue(true),
        sphericalVideoApiProvider.overrideWithValue(sphericalApi),
        spatialVideoApiProvider.overrideWithValue(spatial ?? spatialApi),
        immersiveApiProvider.overrideWithValue(immersiveApi),
        videoPlayerProvider(
          'network:nas:$path',
        ).overrideWith((ref) => _RecordingVideoPlayer(playerCalls, initial: playerState)),
        // A fresh cache per test
        networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
      ],
    );
  }

  /// Waits until what the video declares was read through the server
  Future<void> pumpUntilDetected(WidgetTester tester) async {
    await pumpRealIo(tester, () => server.requests.any((request) => request.range != null));
    // The probe reads a few ranges, then the page follows
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  /// The loading spinner turns as long as no native player is ready, which never comes here: no pumpAndSettle
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openMenuItem(WidgetTester tester, String label) async {
    await openMenu(tester);
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('plays the video from the media bridge, with play and seek controls', (tester) async {
    await pumpVideoPage(tester, '/holiday.mp4');
    await pumpUntilDetected(tester);

    final page = tester.state<NetworkVideoPageState>(find.byType(NetworkVideoPage));
    final source = await page.videoSource;
    expect(source?.type, VideoSourceType.network);
    expect(source?.path, server.urlOf('/holiday.mp4').toString());
    expect(find.text('holiday.mp4'), findsOneWidget);
    expect(find.byType(NetworkVideoControls), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Buffering…'), findsOneWidget, reason: 'no native player gets ready here');

    await endRealIo(tester);
  });

  testWidgets('opens a video that declares 360° in the native 360° player, from the media bridge', (tester) async {
    await pumpVideoPage(tester, '/trip360.mp4');
    await pumpUntilDetected(tester);

    expect(find.byTooltip('360°'), findsOneWidget);
    expect(find.byTooltip('Spatial 2.5D'), findsNothing, reason: 'a mono 360° video');

    await tester.tap(find.byTooltip('360°'));
    await tester.pump();
    await tester.pump();

    expect(sphericalApi.opened, [
      {
        'url': server.urlOf('/trip360.mp4').toString(),
        'title': 'trip360.mp4',
        'layout': StereoLayout.mono,
        'coverage': SphereCoverage.full,
      },
    ]);
    expect(playerCalls, ['suspend'], reason: 'the page player stops meanwhile');

    await endRealIo(tester);
  });

  testWidgets('opens a raw Insta360 video in the native 360° player with the calibration of its trailer', (
    tester,
  ) async {
    await pumpVideoPage(tester, '/VID_20240908_00_002.insv');
    await pumpUntilDetected(tester);

    expect(find.byTooltip('Spatial 2.5D'), findsNothing, reason: 'two lenses side by side are no 3D layout');
    await tester.tap(find.byTooltip('360°'));
    for (var i = 0; i < 10 && sphericalApi.opened.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    expect(sphericalApi.opened.single['layout'], StereoLayout.mono);
    expect(sphericalApi.opened.single['coverage'], SphereCoverage.full);
    final json = jsonDecode(sphericalApi.rawProjections.single!) as Map;
    expect((json['frameWidth'], json['frameHeight']), (5760, 2880));
    expect(((json['lenses'] as List).first as Map)['fx'], closeTo(4627.54, 1e-6), reason: 'read from the share');

    await endRealIo(tester);
  });

  testWidgets('says that a raw video of one lens per file does not open', (tester) async {
    await pumpVideoPage(tester, '/VID_20240908_10_003.insv');
    await pumpUntilDetected(tester);

    await tester.tap(find.byTooltip('360°'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'This raw video is split in two files or two tracks (one per lens): not supported yet. Export it from the '
        'camera app, or play a single file recording.',
      ),
      findsOneWidget,
    );
    expect(sphericalApi.opened, isEmpty);
    expect(playerCalls, isEmpty);

    await endRealIo(tester);
  });

  testWidgets('opens a stereoscopic 360° video with its layout, in 360° or in the Spatial 2.5D player', (tester) async {
    await pumpVideoPage(tester, '/stereo360.mp4');
    await pumpUntilDetected(tester);

    await tester.tap(find.byTooltip('360°'));
    await tester.pump();
    await tester.pump();
    expect(sphericalApi.opened.single['layout'], StereoLayout.topBottom);

    await tester.tap(find.byTooltip('Spatial 2.5D'));
    await tester.pump();
    await tester.pump();

    final request = spatialApi.opened.single;
    expect(request.url, server.urlOf('/stereo360.mp4').toString());
    expect(request.title, 'stereo360.mp4');
    expect(request.projection, SpatialProjection.equirectangular);
    expect(request.layout, SpatialStereoLayout.auto, reason: 'the file declares its layout, which the player reads');
    expect(request.startPositionMs, 0);
    expect(request.autoplay, isFalse);

    await endRealIo(tester);
  });

  testWidgets('a flat video named side by side opens in the Spatial 2.5D player, and takes the video back after', (
    tester,
  ) async {
    await pumpVideoPage(tester, '/movie_sbs.mp4');
    await pumpUntilDetected(tester);

    expect(find.byTooltip('360°'), findsNothing);
    await tester.tap(find.byTooltip('Spatial 2.5D'));
    await tester.pump();
    await tester.pump();

    final request = spatialApi.opened.single;
    expect(request.projection, SpatialProjection.flat);
    expect(request.layout, SpatialStereoLayout.sideBySide);
    expect(playerCalls, ['suspend']);

    // The native player closes: it calls the Flutter API it was given
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'dev.flutter.pigeon.immich_mobile.SpatialVideoEvents.closed',
      SpatialVideoEvents.pigeonChannelCodec.encodeMessage(<Object?>[
        42000,
        true,
        SpatialStereoLayout.sideBySide,
        SpatialProjection.flat,
      ]),
      (_) {},
    );
    await tester.pump();

    expect(playerCalls, ['suspend', 'resume at 42000 playing']);

    await endRealIo(tester);
  });

  testWidgets('offers any video as 360° and in the Spatial 2.5D player from the menu', (tester) async {
    await pumpVideoPage(tester, '/holiday.mp4');
    await pumpUntilDetected(tester);

    expect(find.byTooltip('360°'), findsNothing);
    expect(find.byTooltip('Spatial 2.5D'), findsNothing);

    await openMenuItem(tester, 'View as 360°');
    expect(sphericalApi.opened.single['coverage'], SphereCoverage.full);

    await openMenuItem(tester, 'Spatial 2.5D');
    expect(spatialApi.opened.single.layout, SpatialStereoLayout.auto);

    await endRealIo(tester);
  });

  testWidgets('without the Spatial 2.5D setting, offers no Spatial player', (tester) async {
    await pumpVideoPage(tester, '/movie_sbs.mp4', spatial25d: false);
    await pumpUntilDetected(tester);

    expect(find.byTooltip('Spatial 2.5D'), findsNothing);
    await openMenu(tester);
    expect(find.text('Spatial 2.5D'), findsNothing);
    expect(find.text('View as 360°'), findsOneWidget);

    await endRealIo(tester);
  });

  testWidgets('tells when the Spatial 2.5D player does not run here, and keeps playing', (tester) async {
    await pumpVideoPage(tester, '/movie_sbs.mp4', spatial: _RecordingSpatialVideoApi(supported: false));
    await pumpUntilDetected(tester);

    await tester.tap(find.byTooltip('Spatial 2.5D'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Spatial 2.5D is not available on this device'), findsOneWidget);
    expect(playerCalls, isEmpty);

    await endRealIo(tester);
  });

  testWidgets('on a Meta Quest, opens a 360° video in the immersive viewer, and offers no Spatial player', (
    tester,
  ) async {
    await pumpVideoPage(tester, '/stereo360.mp4', isHorizonOs: true);
    await pumpUntilDetected(tester);

    expect(find.byTooltip('Spatial 2.5D'), findsNothing);
    await tester.tap(find.byTooltip('360°'));
    await tester.pump();
    await tester.pump();

    expect(sphericalApi.opened, isEmpty);
    expect(immersiveApi.opened, [
      {
        'url': server.urlOf('/stereo360.mp4').toString(),
        'isVideo': true,
        'title': 'stereo360.mp4',
        'layout': ImmersiveStereoLayout.topBottom,
        'coverage': ImmersiveSphereCoverage.full,
      },
    ]);
    expect(playerCalls, ['suspend']);

    await endRealIo(tester);
  });

  testWidgets('on a Meta Quest, the immersive viewer carries on from the page player, goes through the 360° videos of '
      'the folder, and gives the video back where it stopped', (tester) async {
    final entries = [
      for (final path in ['/holiday.mp4', '/trip360.mp4', '/movie_sbs.mp4', '/stereo360.mp4']) share.file(path),
    ];
    final folder = NetworkFolderMedia(
      entries: entries,
      urls: {for (final entry in entries) entry.path: server.urlOf(entry.path)},
      index: 1,
    );
    await pumpVideoPage(
      tester,
      '/trip360.mp4',
      isHorizonOs: true,
      folder: folder,
      playerState: const VideoPlayerState(
        position: Duration(seconds: 12),
        duration: Duration(minutes: 1),
        status: VideoPlaybackStatus.playing,
      ),
    );
    await pumpUntilDetected(tester);
    await tester.tap(find.byTooltip('360°'));
    await tester.pump();
    await tester.pump();

    expect(immersiveApi.opened.single['url'], server.urlOf('/trip360.mp4').toString());
    expect(immersiveApi.startPositions, [12000]);

    // The headset asks for the next media, then the previous one
    final session = ProviderScope.containerOf(
      tester.element(find.byType(NetworkVideoPage)),
    ).read(immersiveSessionProvider);
    final openingId = immersiveApi.openingIds.single;
    var requestId = 0;
    Future<bool?> request(int step) async {
      bool? shown;
      unawaited(
        session
            .requestAdjacent(openingId, ++requestId, step, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full)
            .then((result) => shown = result),
      );
      await pumpRealIo(tester, () => shown != null);
      return shown;
    }

    expect(await request(1), isTrue);
    expect(immersiveApi.shown.last['url'], server.urlOf('/stereo360.mp4').toString(), reason: 'a flat video between');
    expect(immersiveApi.shown.last['layout'], ImmersiveStereoLayout.topBottom);
    expect(await request(1), isFalse);
    expect(await request(-1), isTrue);
    expect(immersiveApi.shown.last['url'], server.urlOf('/trip360.mp4').toString());
    expect(immersiveApi.opened, hasLength(1), reason: 'navigation never starts the viewer');

    // A closing of another opening, a viewer gone long ago, leaves the page player alone
    session.closed(
      openingId - 1,
      server.urlOf('/trip360.mp4').toString(),
      ImmersiveStereoLayout.mono,
      ImmersiveSphereCoverage.full,
      5000,
    );
    expect(playerCalls, ['suspend']);

    session.closed(
      openingId,
      server.urlOf('/trip360.mp4').toString(),
      ImmersiveStereoLayout.mono,
      ImmersiveSphereCoverage.full,
      30000,
    );
    expect(playerCalls, ['suspend', 'resume at 30000 paused']);

    await endRealIo(tester);
  });

  testWidgets('tells why the video could not be opened, and tries again', (tester) async {
    share.error = const NetworkFileSystemException('nas does not answer');
    await pumpVideoPage(tester, '/holiday.mp4');
    await pumpRealIo(tester, () => find.textContaining('Could not open this file').evaluate().isNotEmpty);

    expect(find.text('Could not open this file: nas does not answer'), findsOneWidget);
    final page = tester.state<NetworkVideoPageState>(find.byType(NetworkVideoPage));
    expect(await page.videoSource, isNull);

    share.error = null;
    await tester.tap(find.text('Retry'));
    await pumpUntilDetected(tester);

    expect(find.textContaining('Could not open this file'), findsNothing);
    expect((await page.videoSource)?.path, server.urlOf('/holiday.mp4').toString());

    await endRealIo(tester);
  });
}
