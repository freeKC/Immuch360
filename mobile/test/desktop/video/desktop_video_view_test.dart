// The flat player at its two call sites (design 2.2): on a computer the viewer builds DesktopVideoView where the
// phones build NativeVideoPlayerView, and the view hands the pages a controller of the same type; without libmpv
// (Linux and macOS until phase 4) it shows the placeholder of phase 1, and the load is an error, not a crash.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../infrastructure/repository.mock.dart';
import '../../unit/factories/local_asset_factory.dart';
import '../../unit/presentation/presentation_context.dart';
import 'fake_playback_engine.dart';

class _NoProbes extends SphericalProbeService {
  _NoProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async => null;
}

class _Decoder extends VideoDecoderApi {
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
  }) async => DecodeVerdict(supported: true, hardware: true, maxWidth: 4096, maxHeight: 4096);
}

void main() {
  late PresentationContext context;
  late MockStorageRepository storage;
  final video = LocalAssetFactory.create(id: 'local-1').copyWith(type: .video, playbackStyle: .video);

  setUp(() async {
    context = await PresentationContext.create();
    storage = MockStorageRepository();
    when(() => context.service.asset.service.getAsset(video)).thenAnswer((_) async => video);
    when(() => storage.getFileForAsset(video.id)).thenAnswer((_) async => File('/videos/local-1.mp4'));
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  for (final platform in const [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('${platform.name}: the viewer builds the desktop player, never the native view', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpTestWidget(
        context,
        NativeVideoViewer(
          asset: video,
          isCurrent: true,
          image: const SizedBox(key: Key('poster')),
        ),
        overrides: [
          storageRepositoryProvider.overrideWithValue(storage),
          sphericalProbeServiceProvider.overrideWithValue(_NoProbes()),
          videoSourceServiceProvider.overrideWithValue(VideoSourceService(_Decoder())),
        ],
        expectSettle: false,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('poster')), findsOneWidget, reason: 'the poster stays until the video is ready');
      expect(find.byType(DesktopVideoView), findsOneWidget);
      expect(find.byType(NativeVideoPlayerView), findsNothing);
      // No libmpv under flutter test: the placeholder of phase 1, hidden behind the poster
      expect(find.byType(DesktopVideoPlaceholder), findsOneWidget);
      // The buffering timer of the notifier runs out before the tree goes
      await tester.pump(const Duration(seconds: 2));
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('the view hands its controller after its first frame, plays through the pool, gives it back', (
    tester,
  ) async {
    // Made outside the fake zone of the test, where its futures run while the test awaits them
    final players = (await tester.runAsync(
      () async => FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 5)),
    ))!;
    NativeVideoPlayerController? handed;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DesktopVideoView(
            pool: players.pool,
            resolve: (source) async => source.path,
            onViewReady: (controller) => handed = controller,
          ),
        ),
      ),
    );
    expect(handed, isA<MediaKitVideoPlayerController>());

    await tester.runAsync(() async {
      await handed!.loadVideoSource(await VideoSource.init(path: '/videos/a.mp4', type: VideoSourceType.file));
      await handed!.play();
    });
    expect(players.made.single.playing.value, isTrue);
    expect(find.byType(DesktopVideoPlaceholder), findsNothing);

    // The view goes; the pool, made outside the zone of the test, needs both kinds of turns to release the player
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(players.made.single.calls.last, 'stop');
    expect(players.pool.idleCount(PlayerKind.playback), 1);
  });

  testWidgets('the audio track menu shows for two tracks or more, with the labels of the phones', (tester) async {
    final (players, controller) = (await tester.runAsync(() async {
      final players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 5));
      final controller = MediaKitVideoPlayerController(pool: players.pool, resolve: (source) async => source.path);
      await controller.loadVideoSource(await VideoSource.init(path: '/videos/a.mkv', type: VideoSourceType.file));
      return (players, controller);
    }))!;
    final engine = players.made.single;
    await tester.pumpTestWidget(
      context,
      Scaffold(body: DesktopAudioTrackButton(controller: controller)),
      expectSettle: false,
    );
    expect(find.byKey(const Key('desktop_audio_track')), findsNothing, reason: 'no tracks yet');

    engine.audioTracks.value = const [
      DesktopAudioTrack(id: '1', language: 'eng', channels: 2, isDefault: true),
      DesktopAudioTrack(id: '2', title: 'Commentary', channels: 6),
      DesktopAudioTrack(id: '3', channels: 1),
    ];
    engine.audioTrack.value = '1';
    await tester.pump();
    await tester.tap(find.byKey(const Key('desktop_audio_track')));
    await tester.pumpAndSettle();
    expect(find.text('ENG · Stereo · Default'), findsOneWidget);
    expect(find.text('Commentary · 6 channels'), findsOneWidget);
    expect(find.text('Track 3 · Mono'), findsOneWidget, reason: 'neither title nor language: its number');

    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'Commentary · 6 channels'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(engine.calls.last, 'audio 2');
    await tester.runAsync(() async => controller.dispose());
  });

  testWidgets('the placeholder follows the text size of the system', (tester) async {
    await tester.pumpTestWidget(
      context,
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: SizedBox(width: 400, height: 300, child: DesktopVideoPlaceholder()),
      ),
    );
    final text = tester.widget<Text>(find.text('Video playback comes to Immuch360 Desktop in a later version'));
    expect(text.textScaler, isNull, reason: 'no fixed scale: the MediaQuery one applies');
    expect(tester.takeException(), isNull, reason: 'no overflow at twice the text size');
  });
}
