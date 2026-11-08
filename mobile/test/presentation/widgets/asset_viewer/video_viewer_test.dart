import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/original_download.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

/// What the file of every video declares: [result], nothing by default. Records the videos probed.
class _FakeSphericalProbes extends SphericalProbeService {
  _FakeSphericalProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  SphericalProbe? result;
  final probed = <BaseAsset>[];

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async {
    probed.add(asset);
    return result;
  }
}

/// Answers the decoder check with [supported], or as a Meta Quest 3 when [quest] (HEVC up to 8192 x 4320, H.264 up to
/// the 4096 x 2304 measured there)
class _FakeVideoDecoderApi extends VideoDecoderApi {
  bool supported = true;
  bool quest = false;

  @override
  Future<DecodeVerdict> canDecode(
    String codec,
    String? codecs,
    int width,
    int height,
    double frameRate,
    int bitDepth,
    int transferCharacteristics, {
    int instances = 1,
  }) async {
    if (!quest) {
      return DecodeVerdict(supported: supported, hardware: true, maxWidth: 4096, maxHeight: 4096);
    }
    final hevc = codec.startsWith('hvc') || codec.startsWith('hev');
    final maxWidth = hevc ? 8192 : 4096;
    final maxHeight = hevc ? 4320 : 2304;
    return DecodeVerdict(
      supported: width <= maxWidth && height <= maxHeight,
      hardware: true,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
  }
}

/// The native player of the viewer, which the tests have no platform view for: records what it loads
class _FakePlayerController extends Fake implements NativeVideoPlayerController {
  @override
  final onPlaybackReady = ChangeNotifier();
  @override
  final onPlaybackStatusChanged = ValueNotifier<PlaybackStatus>(PlaybackStatus.stopped);
  @override
  final onPlaybackPositionChanged = ValueNotifier<int>(0);
  @override
  final onPlaybackEnded = ChangeNotifier();
  @override
  final onError = ValueNotifier<String?>(null);
  @override
  final onTracksChanged = ChangeNotifier();
  @override
  final onLinkChanged = ValueNotifier<NativeVideoLink?>(null);

  final loaded = <VideoSource>[];

  /// Where each load of [loaded] started, null for the start
  final loadedAt = <Duration?>[];
  VideoSource? _source;

  @override
  VideoSource? get videoSource => _source;

  /// What the native player tells of the playback, null until the test sets it
  PlaybackInfo? info;
  VideoInfo? video;

  @override
  PlaybackInfo? get playbackInfo => info;

  @override
  VideoInfo? get videoInfo => video;

  /// The native player is ready, paused at [positionMs] of a video of [durationMs]
  void ready({int positionMs = 0, int durationMs = 600000}) {
    info = PlaybackInfo(
      status: PlaybackStatus.paused,
      position: positionMs,
      positionFraction: positionMs / durationMs,
      speed: 1,
      volume: 1,
      error: null,
    );
    video = VideoInfo.fromJson({'width': 1920, 'height': 1080, 'duration': durationMs});
    onPlaybackReady.notifyListeners();
  }

  @override
  Future<void> loadVideoSource(VideoSource videoSource, {Duration? startAt}) async {
    loaded.add(videoSource);
    loadedAt.add(startAt);
    _source = videoSource;
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> isPlaying() async => false;

  @override
  Future<void> setLoop(bool loop) async {}

  @override
  Future<void> setVolume(double volume) async {}
}

/// One download of [_FakeOriginalDownloads]: each [chunk] asks whether it is still wanted, as the real one does
class _DownloadRun {
  _DownloadRun(this.videoId, this.isWanted);

  final String videoId;
  final bool Function()? isWanted;
  final result = Completer<File?>();

  /// A chunk arrives: the download stops, with no file, when the video is no longer wanted
  void chunk() {
    if (!result.isCompleted && isWanted?.call() == false) {
      result.complete(null);
    }
  }

  void finish(File? file) => result.complete(file);
}

/// A server that cannot stream its originals ([streamsAnswer] false), whose downloads the tests drive
class _FakeOriginalDownloads extends OriginalDownloads {
  _FakeOriginalDownloads()
    : super(
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
        directory: () async => Directory.systemTemp,
      );

  bool streamsAnswer = false;
  final runs = <_DownloadRun>[];
  final held = <String>[];
  final released = <String>[];

  @override
  Future<bool> streams(String videoId) async => streamsAnswer;

  @override
  Future<File?> download(String videoId, {void Function(int percent)? onProgress, bool Function()? isWanted}) {
    final run = _DownloadRun(videoId, isWanted);
    runs.add(run);
    onProgress?.call(0);
    return run.result.future;
  }

  @override
  void hold(String videoId) => held.add(videoId);

  @override
  Future<void> release(String videoId) async => released.add(videoId);
}

void main() {
  late PresentationContext context;
  late MockStorageRepository storage;
  late _FakeSphericalProbes probes;
  late _FakeVideoDecoderApi decoderApi;

  final local = LocalAssetFactory.create(id: 'local-1').copyWith(type: .video, playbackStyle: .video);
  final remote = RemoteAssetFactory.create(type: .video, localId: local.id);

  setUp(() async {
    context = await PresentationContext.create();
    storage = MockStorageRepository();
    probes = _FakeSphericalProbes();
    decoderApi = _FakeVideoDecoderApi();
    final assets = context.service.asset.service;
    when(() => assets.getAsset(remote)).thenAnswer((_) async => remote);
    when(() => assets.getAsset(local)).thenAnswer((_) async => local);
    when(() => assets.getLocalAsset(local.id)).thenAnswer((_) async => local);
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<VideoSource?> pumpViewer(
    WidgetTester tester,
    BaseAsset asset, {
    AppConfig? appConfig,
    List<Override> overrides = const [],
    bool isCurrent = false,
  }) async {
    await tester.pumpTestWidget(
      context,
      NativeVideoViewer(asset: asset, image: const SizedBox(), isCurrent: isCurrent),
      overrides: [
        storageRepositoryProvider.overrideWithValue(storage),
        sphericalProbeServiceProvider.overrideWithValue(probes),
        // Overridden where the viewer reads it: its scope is below the one of the app
        videoSourceServiceProvider.overrideWithValue(VideoSourceService(decoderApi)),
        if (appConfig != null) appConfigProvider.overrideWithValue(appConfig),
        ...overrides,
      ],
      expectSettle: false,
    );
    return tester.state<NativeVideoViewerState>(find.byType(NativeVideoViewer)).videoSource;
  }

  testWidgets('plays the local file when it exists', (tester) async {
    final file = File('/videos/local-1.mp4');
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => file);

    final source = await pumpViewer(tester, remote);

    expect(source?.type, VideoSourceType.file);
    expect(source?.path, endsWith(file.path));
  });

  testWidgets('plays the server copy when the local file cannot be read', (tester) async {
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => null);

    final source = await pumpViewer(tester, remote);

    expect(source?.type, VideoSourceType.network);
    expect(source?.path, endsWith('/assets/${remote.id}/video/playback'));
    expect(probes.probed, isEmpty, reason: 'the transcoded stream plays whatever the file');
  });

  group('with the device choosing between the original and the transcoded stream', () {
    final serverOnly = RemoteAssetFactory.create(type: .video);
    const appConfig = AppConfig(viewer: ViewerConfig(videoSource: .preferOriginalWithinDecoder));
    const probe8k = SphericalProbe(codec: 'hvc1', codedWidth: 7680, codedHeight: 3840, frameRate: 30);

    setUp(() {
      when(() => context.service.asset.service.getAsset(serverOnly)).thenAnswer((_) async => serverOnly);
      probes.result = probe8k;
    });

    testWidgets('plays the original the device decodes', (tester) async {
      final source = await pumpViewer(tester, serverOnly, appConfig: appConfig);

      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
      expect(probes.probed, [serverOnly]);
    });

    testWidgets('plays the transcoded stream when the device cannot decode the original', (tester) async {
      decoderApi.supported = false;

      final source = await pumpViewer(tester, serverOnly, appConfig: appConfig);

      expect(source?.path, endsWith('/assets/${serverOnly.id}/video/playback'));
    });

    testWidgets('plays the original when nothing tells what the file is', (tester) async {
      probes.result = null;

      final source = await pumpViewer(tester, serverOnly, appConfig: appConfig);

      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
    });

    testWidgets('plays the original whatever the device when the user asks for it', (tester) async {
      decoderApi.supported = false;

      final source = await pumpViewer(
        tester,
        serverOnly,
        appConfig: const AppConfig(viewer: ViewerConfig(videoSource: .alwaysOriginal)),
      );

      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
    });

    testWidgets('plays the original the former switch asked for, within the decoders', (tester) async {
      decoderApi.supported = false;

      final source = await pumpViewer(
        tester,
        serverOnly,
        appConfig: const AppConfig(viewer: ViewerConfig(loadOriginalVideo: true)),
      );

      expect(source?.path, endsWith('/assets/${serverOnly.id}/video/playback'));
    });
  });

  group('the in-app player of 30 October on a Meta Quest 3', () {
    // The server transcodes to H.264 at the original 5760 x 2880, the original is HEVC, the setting is the default one
    // (the transcoded stream), and the player stalled 10 s on the copy before Media3 gave up
    final serverOnly = RemoteAssetFactory.create(type: .video);
    const hevcOriginal = SphericalProbe(codec: 'hvc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);
    const h264Copy = SphericalProbe(codec: 'avc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);

    setUp(() {
      when(() => context.service.asset.service.getAsset(serverOnly)).thenAnswer((_) async => serverOnly);
      decoderApi.quest = true;
    });

    Future<VideoSource?> pumpQuest(WidgetTester tester, {required SphericalProbe original, bool isCurrent = false}) {
      probes.result = original;
      return pumpViewer(
        tester,
        serverOnly,
        isCurrent: isCurrent,
        overrides: [
          videoSourceServiceProvider.overrideWithValue(
            VideoSourceService(decoderApi, probeTranscoded: (_) async => h264Copy),
          ),
          // The details the failure panel reads, overridden in the scope of the viewer
          videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
        ],
      );
    }

    testWidgets('plays the HEVC original rather than the copy it cannot decode, and keeps why for the details', (
      tester,
    ) async {
      final source = await pumpQuest(tester, original: hevcOriginal);

      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
      final chosen = ProviderScope.containerOf(
        tester.element(find.byType(NativeVideoViewer)),
      ).read(chosenVideoSourcesProvider)[serverOnly.id];
      expect(chosen?.notice, const VideoSourceNotice(.originalOverCopy, codec: 'H.264', width: 5760, height: 2880));
    });

    testWidgets('says at once what to change in Immich when neither file decodes', (tester) async {
      final source = await pumpQuest(
        tester,
        original: const SphericalProbe(codec: 'avc1', codedWidth: 7680, codedHeight: 3840, frameRate: 30),
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(NativeVideoViewer)));
      final refusal = container.read(chosenVideoSourcesProvider)[serverOnly.id]?.refusal;
      expect(refusal, isNotNull);

      // What the viewer does with it once its native player is there: no load, the panel at once
      container.read(videoPlayerProvider(serverOnly.id).notifier).refuse(source!, refusal!);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);
      expect(find.text('This video cannot be played'), findsOneWidget);
      expect(
        find.text(
          'This device cannot decode this video (H.264 5760 x 2880, above 4096 x 2304): in Immich, set the video '
          'transcoding to HEVC or lower the resolution',
        ),
        findsOneWidget,
      );
    });

    testWidgets('on screen, tells why it plays the original, then loads it', (tester) async {
      await pumpQuest(tester, original: hevcOriginal, isCurrent: true);
      final controller = _FakePlayerController();
      tester.state<NativeVideoViewerState>(find.byType(NativeVideoViewer)).attachController(controller);
      await tester.pump();
      await tester.pump();

      expect(
        find.text("Playing the original: the server's copy (H.264 5760 x 2880) is above this device's decoder"),
        findsOneWidget,
      );
      expect(controller.loaded.single.path, endsWith('/assets/${serverOnly.id}/original'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('on screen, fails at once without loading when neither file decodes', (tester) async {
      await pumpQuest(
        tester,
        original: const SphericalProbe(codec: 'avc1', codedWidth: 7680, codedHeight: 3840, frameRate: 30),
        isCurrent: true,
      );
      final controller = _FakePlayerController();
      tester.state<NativeVideoViewerState>(find.byType(NativeVideoViewer)).attachController(controller);
      await tester.pump();
      await tester.pump();

      expect(controller.loaded, isEmpty, reason: 'no 10 s of a decoder that cannot keep up');
      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);
      expect(
        find.text(
          'This device cannot decode this video (H.264 5760 x 2880, above 4096 x 2304): in Immich, set the video '
          'transcoding to HEVC or lower the resolution',
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('plays the copy the user forced in the details', (tester) async {
      probes.result = hevcOriginal;
      final source = await pumpViewer(
        tester,
        serverOnly,
        overrides: [
          videoSourceServiceProvider.overrideWithValue(
            VideoSourceService(decoderApi, probeTranscoded: (_) async => h264Copy),
          ),
          videoSourceOverridesProvider.overrideWith((ref) => VideoSourceOverrides()..force(serverOnly.id, .transcoded)),
        ],
      );

      expect(source?.path, endsWith('/assets/${serverOnly.id}/video/playback'));
    });
  });

  group('a video that does not play', () {
    final serverOnly = RemoteAssetFactory.create(type: .video);

    setUp(() {
      when(() => context.service.asset.service.getAsset(serverOnly)).thenAnswer((_) async => serverOnly);
    });

    VideoPlayerNotifier playerOf(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(NativeVideoViewer)),
    ).read(videoPlayerProvider(serverOnly.id).notifier);

    testWidgets('says why in place of the spinner, the decoders of the device when the file is beyond them', (
      tester,
    ) async {
      const probe = SphericalProbe(codec: 'avc1', codedWidth: 5760, codedHeight: 2880, frameRate: 30);
      final verdict = DecodeVerdict(supported: false, hardware: true, maxWidth: 4096, maxHeight: 2304);
      await pumpViewer(
        tester,
        serverOnly,
        overrides: [
          videoDecodeDetailsProvider.overrideWith(
            (ref, asset) async => (probe: probe, verdict: verdict, bitRate: null),
          ),
        ],
      );
      expect(find.byKey(const Key('video_failure_panel')), findsNothing);

      playerOf(tester).onNativeError('Decoder init failed');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);
      expect(find.text('This video cannot be played'), findsOneWidget);
      expect(find.textContaining('H.264 5760 x 2880 is beyond the video decoders of this device'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator).hitTestable(), findsNothing);
    });

    testWidgets('goes away when the video loads again', (tester) async {
      await pumpViewer(
        tester,
        serverOnly,
        overrides: [
          videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
        ],
      );
      final player = playerOf(tester);
      player.onNativeError('Source error');
      await tester.pump();
      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);

      await player.load(VideoSource(path: 'https://server/v', type: .network, headers: const {}));
      await tester.pump();

      expect(find.byKey(const Key('video_failure_panel')), findsNothing);
    });
  });

  group('the link of a server video (31 October 2026)', () {
    final serverOnly = RemoteAssetFactory.create(type: .video);

    setUp(() {
      when(() => context.service.asset.service.getAsset(serverOnly)).thenAnswer((_) async => serverOnly);
    });

    NativeVideoViewerState stateOf(WidgetTester tester) => tester.state(find.byType(NativeVideoViewer));

    VideoPlayerNotifier playerOf(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(NativeVideoViewer)),
    ).read(videoPlayerProvider(serverOnly.id).notifier);

    Future<_FakePlayerController> pumpLoaded(WidgetTester tester) async {
      await pumpViewer(
        tester,
        serverOnly,
        isCurrent: true,
        overrides: [
          videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
        ],
      );
      await stateOf(tester).videoSource;
      final controller = _FakePlayerController();
      stateOf(tester).attachController(controller);
      await tester.pump();
      await tester.pump();
      expect(controller.loaded, hasLength(1));
      // The spinner, a second after the load
      await tester.pump(const Duration(milliseconds: 1100));
      return controller;
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('the player view stays when the poster and the failure panel leave in the same frame', (tester) async {
      final controller = await pumpLoaded(tester);
      // R6 and R7 of 31 October: nothing arrived for 30 s before the first frame, the panel over the poster
      playerOf(tester).onNativeLinkChanged(const NativeVideoLink(waiting: true, sinceProgressMs: 30000, network: true));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);
      final view = tester.element(find.byType(NativeVideoPlayerView));

      // The bytes come back and the player gets ready: the poster and the panel go together
      playerOf(tester).onNativeLinkChanged(const NativeVideoLink(waiting: true, sinceProgressMs: 100, network: true));
      controller.ready();
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('video_failure_panel')), findsNothing);
      expect(identical(tester.element(find.byType(NativeVideoPlayerView)), view), isTrue, reason: 'not made again');
      expect(controller.loaded, hasLength(1), reason: 'the same native player, which has the video');
      await leave(tester);
    });

    testWidgets('a player view made again gets the video, where the one before was', (tester) async {
      final first = await pumpLoaded(tester);
      first.ready(positionMs: 61000);
      await tester.pump();
      await tester.pump();

      final second = _FakePlayerController();
      stateOf(tester).attachController(second);
      await tester.pump();
      await tester.pump();

      expect(second.loaded.single.path, endsWith('/assets/${serverOnly.id}/video/playback'));
      expect(second.loadedAt.single, const Duration(seconds: 61));
      // The first one is no longer heard
      first.onError.value = 'Source error';
      await tester.pump();
      expect(find.byKey(const Key('video_failure_panel')), findsNothing);
      await leave(tester);
    });

    testWidgets('while it waits, the spinner says what the link brings against what the video needs', (tester) async {
      await pumpLoaded(tester);

      // 2.4 of the 3 Mbit/s the video needs, the player waiting for 6 s of media with 3 s there
      playerOf(tester).onNativeLinkChanged(
        const NativeVideoLink(
          waiting: true,
          bytesPerSecond: 300000,
          neededBytesPerSecond: 375000,
          sinceProgressMs: 200,
          aheadMs: 3000,
          targetMs: 6000,
          loading: true,
          network: true,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('video_loading_line')), findsOneWidget);
      expect(find.text('Loading: 2.4 Mbit/s of the 3 Mbit/s this video needs\nStarts in about 4 s'), findsOneWidget);
      expect(find.byKey(const Key('video_failure_panel')), findsNothing, reason: 'a slow link is no failure');
      await leave(tester);
    });
  });

  group('a decoder that refuses at run time (a TV, 8 November 2026)', () {
    // The decoder check accepts the HEVC original, and the TV's decoder refuses it as it starts: the server's copy
    // plays once, with a word, rather than the failure panel
    final serverOnly = RemoteAssetFactory.create(type: .video);
    const appConfig = AppConfig(viewer: ViewerConfig(videoSource: .preferOriginalWithinDecoder));
    const hevcOriginal = SphericalProbe(codec: 'hvc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);
    const refusedHevc = 'immuch360-playback-error:decoder:video/hevc:5760:2880';
    const copyNotice =
        "Playing the server's copy: the original (HEVC 5760 x 2880) was refused by this device's decoder";
    late _FakeOriginalDownloads downloads;
    // The key of the viewer: a new one is a new viewer of the same video
    late ValueNotifier<int> viewer;
    late SphericalProbe? copyProbe;

    setUp(() {
      when(() => context.service.asset.service.getAsset(serverOnly)).thenAnswer((_) async => serverOnly);
      probes.result = hevcOriginal;
      downloads = _FakeOriginalDownloads()..streamsAnswer = true;
      viewer = ValueNotifier(0);
      copyProbe = null;
    });

    NativeVideoViewerState stateOf(WidgetTester tester) => tester.state(find.byType(NativeVideoViewer));

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(NativeVideoViewer)));

    // The native player of the viewer on screen, once its source is made
    Future<_FakePlayerController> attach(WidgetTester tester) async {
      await stateOf(tester).videoSource;
      final controller = _FakePlayerController();
      stateOf(tester).attachController(controller);
      await tester.pump();
      await tester.pump();
      return controller;
    }

    Future<_FakePlayerController> pumpOnScreen(WidgetTester tester, {List<Override> overrides = const []}) async {
      await tester.pumpTestWidget(
        context,
        ValueListenableBuilder<int>(
          valueListenable: viewer,
          builder: (_, key, _) =>
              NativeVideoViewer(key: ValueKey(key), asset: serverOnly, image: const SizedBox(), isCurrent: true),
        ),
        overrides: [
          storageRepositoryProvider.overrideWithValue(storage),
          sphericalProbeServiceProvider.overrideWithValue(probes),
          videoSourceServiceProvider.overrideWithValue(
            VideoSourceService(decoderApi, probeTranscoded: (_) async => copyProbe),
          ),
          appConfigProvider.overrideWithValue(appConfig),
          // Read from the config above: overridden with it, in the scope of the viewer
          loopVideoProvider.overrideWithValue(false),
          originalDownloadsProvider.overrideWithValue(downloads),
          videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
          ...overrides,
        ],
        expectSettle: false,
      );
      return attach(tester);
    }

    // The native player sends the token of an error, and the viewer decides
    Future<void> fail(WidgetTester tester, _FakePlayerController controller, String token) async {
      controller.onError.value = token;
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('plays the server copy in place of the refused original, says why, and shows no panel', (tester) async {
      final controller = await pumpOnScreen(tester);
      expect(controller.loaded.single.path, endsWith('/assets/${serverOnly.id}/original'));

      await fail(tester, controller, refusedHevc);

      expect(controller.loaded, hasLength(2));
      expect(controller.loaded.last.path, endsWith('/assets/${serverOnly.id}/video/playback'));
      expect(find.text(copyNotice), findsOneWidget);
      expect(find.byKey(const Key('video_failure_panel')), findsNothing);
      // The details of the video say which file plays, and offer the original again
      final chosen = containerOf(tester).read(chosenVideoSourcesProvider)[serverOnly.id];
      expect(chosen?.kind, VideoSourceKind.transcoded);
      expect(chosen?.notice, const VideoSourceNotice(.copyAfterRefusal, codec: 'HEVC', width: 5760, height: 2880));

      await leave(tester);
    });

    testWidgets('shows the panel when the copy fails in turn, without going back to the original', (tester) async {
      final controller = await pumpOnScreen(tester);
      await fail(tester, controller, refusedHevc);

      await fail(tester, controller, 'immuch360-playback-error:decoder:video/avc:1920:960');

      expect(controller.loaded, hasLength(2));
      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);
      expect(find.text('This device cannot decode this video (H.264 1920 x 960)'), findsOneWidget);

      await leave(tester);
    });

    testWidgets('a new viewer of the same video plays the copy at once, with why', (tester) async {
      final first = await pumpOnScreen(tester);
      await fail(tester, first, refusedHevc);
      ScaffoldMessenger.of(tester.element(find.byType(NativeVideoViewer))).removeCurrentSnackBar();

      viewer.value = 1;
      await tester.pump();
      final second = await attach(tester);

      expect(second.loaded.single.path, endsWith('/assets/${serverOnly.id}/video/playback'));
      expect(find.text(copyNotice), findsOneWidget);

      await leave(tester);
    });

    testWidgets('a copy beyond the decoders too: the panel names it, in place of the server advice', (tester) async {
      // A server that transcodes to H.264 at the original size, and decoders that stop H.264 at 4096 x 2304
      decoderApi.quest = true;
      copyProbe = const SphericalProbe(codec: 'avc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);
      final controller = await pumpOnScreen(tester);

      await fail(tester, controller, refusedHevc);

      expect(controller.loaded, hasLength(1), reason: 'no 10 s of a copy the decoders cannot take');
      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);
      expect(find.text('This device cannot decode this video (HEVC 5760 x 2880)'), findsOneWidget);
      expect(
        find.text(
          "The server's copy (H.264 5760 x 2880) is beyond the decoders of this device too: in Immich, lower the "
          'target resolution of the video transcoding, then run Transcode videos',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('set the transcode policy'), findsNothing);

      await leave(tester);
    });

    testWidgets('a copy forced in the details fails with the panel, as it would before', (tester) async {
      final controller = await pumpOnScreen(
        tester,
        overrides: [
          videoSourceOverridesProvider.overrideWith((ref) => VideoSourceOverrides()..force(serverOnly.id, .transcoded)),
        ],
      );
      expect(controller.loaded.single.path, endsWith('/assets/${serverOnly.id}/video/playback'));

      await fail(tester, controller, 'immuch360-playback-error:decoder:video/avc:1920:960');

      expect(controller.loaded, hasLength(1));
      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);

      await leave(tester);
    });

    testWidgets('a link that stopped is no refusal of the decoder: the panel, without a switch', (tester) async {
      final controller = await pumpOnScreen(tester);

      await fail(tester, controller, 'immuch360-playback-error:stalled::0:0');

      expect(controller.loaded, hasLength(1));
      expect(find.byKey(const Key('video_failure_panel')), findsOneWidget);
      expect(containerOf(tester).read(runtimeVideoRefusalsProvider.notifier).of(serverOnly.id), isEmpty);

      await leave(tester);
    });
  });

  group('an original that cannot stream, downloaded before it plays', () {
    // FreeKC's server: no Range on /original, the MP4 index at the end. The original plays (the device decodes it), so
    // the in-app player downloads it with its progress, for the video on screen only
    final serverOnly = RemoteAssetFactory.create(type: .video);
    const appConfig = AppConfig(viewer: ViewerConfig(videoSource: .preferOriginalWithinDecoder));
    final downloaded = File('/cache/video_original/original-${serverOnly.id}.mp4');
    late _FakeOriginalDownloads downloads;
    late _FakePlayerController controller;
    late ValueNotifier<bool> current;

    setUp(() {
      when(() => context.service.asset.service.getAsset(serverOnly)).thenAnswer((_) async => serverOnly);
      probes.result = const SphericalProbe(codec: 'hvc1', codedWidth: 5760, codedHeight: 2880, frameRate: 29.97);
      downloads = _FakeOriginalDownloads();
      controller = _FakePlayerController();
      current = ValueNotifier(true);
    });

    NativeVideoViewerState stateOf(WidgetTester tester) => tester.state(find.byType(NativeVideoViewer));

    VideoPlayerNotifier playerOf(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(NativeVideoViewer)),
    ).read(videoPlayerProvider(serverOnly.id).notifier);

    // The viewer on screen, its source made and its native player ready: the download starts
    Future<void> pumpOnScreen(WidgetTester tester) async {
      await tester.pumpTestWidget(
        context,
        ValueListenableBuilder<bool>(
          valueListenable: current,
          builder: (_, isCurrent, _) =>
              NativeVideoViewer(asset: serverOnly, image: const SizedBox(), isCurrent: isCurrent),
        ),
        overrides: [
          storageRepositoryProvider.overrideWithValue(storage),
          sphericalProbeServiceProvider.overrideWithValue(probes),
          videoSourceServiceProvider.overrideWithValue(VideoSourceService(decoderApi)),
          appConfigProvider.overrideWithValue(appConfig),
          // Read from the config above: overridden with it, in the scope of the viewer
          loopVideoProvider.overrideWithValue(false),
          originalDownloadsProvider.overrideWithValue(downloads),
          videoDecodeDetailsProvider.overrideWith((ref, asset) async => (probe: null, verdict: null, bitRate: null)),
        ],
        expectSettle: false,
      );
      final source = await stateOf(tester).videoSource;
      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
      stateOf(tester).attachController(controller);
      await tester.pump();
      await tester.pump();
    }

    // The viewer goes, and its player with it: no timer of the player is left
    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('loads the file once it is whole, with the progress on screen meanwhile', (tester) async {
      await pumpOnScreen(tester);

      expect(downloads.runs, hasLength(1));
      expect(find.byKey(const Key('video_original_download')), findsOneWidget);
      expect(controller.loaded, isEmpty, reason: 'nothing streams while the original downloads');

      downloads.runs.single.finish(downloaded);
      await tester.pump();
      await tester.pump();

      expect(controller.loaded.single.type, VideoSourceType.file);
      expect(controller.loaded.single.path, endsWith(downloaded.path));
      expect(downloads.held, [serverOnly.id]);
      expect(find.byKey(const Key('video_original_download')), findsNothing);

      await leave(tester);
    });

    testWidgets('stops behind the immersive viewer, and downloads again once the page is back', (tester) async {
      await pumpOnScreen(tester);

      // The immersive button: the viewer downloads the same original on its own
      await playerOf(tester).suspendForExternalPlayer();
      downloads.runs.single.chunk();
      await tester.pump();
      await tester.pump();

      expect(downloads.runs.single.result.isCompleted, isTrue, reason: 'one download at a time on the link');
      expect(controller.loaded, isEmpty);
      expect(find.byKey(const Key('video_original_download')), findsNothing);

      // The immersive viewer closes: the app resumes
      await stateOf(tester).didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(downloads.runs, hasLength(2));
      downloads.runs.last.finish(downloaded);
      await tester.pump();
      await tester.pump();

      expect(controller.loaded.single.path, endsWith(downloaded.path));

      await leave(tester);
    });

    testWidgets('a swipe stops the download and loads nothing on the page left, which downloads again on its return', (
      tester,
    ) async {
      await pumpOnScreen(tester);

      current.value = false;
      await tester.pump();
      downloads.runs.single.chunk();
      await tester.pump();
      await tester.pump();

      expect(controller.loaded, isEmpty, reason: 'the original never streams on a page that is not on screen');

      current.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(downloads.runs, hasLength(2));
      downloads.runs.last.finish(downloaded);
      await tester.pump();
      await tester.pump();

      expect(controller.loaded.single.path, endsWith(downloaded.path));

      await leave(tester);
    });

    testWidgets('a download that ends after the copy was forced does not load the original over it', (tester) async {
      await pumpOnScreen(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(NativeVideoViewer)));

      container.read(videoSourceOverridesProvider.notifier).force(serverOnly.id, .transcoded);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      downloads.runs.single.finish(downloaded);
      await tester.pump();
      await tester.pump();

      expect(controller.loaded.single.path, endsWith('/assets/${serverOnly.id}/video/playback'));

      await leave(tester);
    });

    testWidgets('streams the original when the download fails for the video on screen', (tester) async {
      await pumpOnScreen(tester);

      downloads.runs.single.finish(null);
      await tester.pump();
      await tester.pump();

      expect(controller.loaded.single.type, VideoSourceType.network);
      expect(controller.loaded.single.path, endsWith('/assets/${serverOnly.id}/original'));

      await leave(tester);
    });

    testWidgets('gives back its own file only when it goes', (tester) async {
      await pumpOnScreen(tester);
      downloads.runs.single.finish(downloaded);
      await tester.pump();
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(downloads.released, [serverOnly.id]);
    });

    testWidgets('streams an original that the server streams', (tester) async {
      downloads.streamsAnswer = true;
      await pumpOnScreen(tester);

      expect(downloads.runs, isEmpty);
      expect(controller.loaded.single.path, endsWith('/assets/${serverOnly.id}/original'));

      await leave(tester);
    });
  });

  testWidgets('draws no frame of its own while the video does not wait for its data', (tester) async {
    // The spinner of a buffering video stays in the tree, invisible, the rest of the time: its animation asked for a
    // frame at every refresh of the display, and on the computers every such frame draws the video's texture again
    // (2 November 2026: 60 to 113 frames a second for a 30 fps video, a full 3D engine on an Intel UHD)
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => File('/videos/local-1.mp4'));
    await pumpViewer(tester, remote);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final spinner = find.byType(CircularProgressIndicator);
    expect(spinner, findsOneWidget);
    expect(TickerMode.valuesOf(tester.element(spinner)).enabled, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);

    // While it waits, the spinner turns; once it plays again, nothing asks for frames after the fade
    final notifier = ProviderScope.containerOf(
      tester.element(find.byType(NativeVideoViewer)),
    ).read(videoPlayerProvider(remote.id).notifier);
    // ignore: invalid_use_of_protected_member
    notifier.state = notifier.state.copyWith(status: VideoPlaybackStatus.buffering);
    await tester.pump();
    expect(TickerMode.valuesOf(tester.element(spinner)).enabled, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
    // ignore: invalid_use_of_protected_member
    notifier.state = notifier.state.copyWith(status: VideoPlaybackStatus.playing);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(TickerMode.valuesOf(tester.element(spinner)).enabled, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('gives up when a local only asset has no file', (tester) async {
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => null);

    final source = await pumpViewer(tester, local);

    expect(source, isNull);
  });
}
