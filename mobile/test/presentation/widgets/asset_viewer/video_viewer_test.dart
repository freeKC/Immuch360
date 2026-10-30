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
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
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
  }) async {
    await tester.pumpTestWidget(
      context,
      NativeVideoViewer(asset: asset, image: const SizedBox()),
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

    Future<VideoSource?> pumpQuest(WidgetTester tester, {required SphericalProbe original}) {
      probes.result = original;
      return pumpViewer(
        tester,
        serverOnly,
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

  testWidgets('gives up when a local only asset has no file', (tester) async {
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => null);

    final source = await pumpViewer(tester, local);

    expect(source, isNull);
  });
}
