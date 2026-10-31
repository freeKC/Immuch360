import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/watch_progress/resume_notice.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/watch_progress.fake.dart';
import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

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

class _Decodes extends VideoDecoderApi {
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
  }) async => DecodeVerdict(supported: true, hardware: true, maxWidth: 8192, maxHeight: 8192);
}

void main() {
  late PresentationContext context;
  late ValueNotifier<bool> current;
  late FakeNativePlayer native;
  late MemoryWatchRows database;
  const minute = 60000;
  const film = Duration(minutes: 100);
  final video = RemoteAssetFactory.create(type: .video).copyWith(durationMs: film.inMilliseconds);
  final key = WatchKey.ofAsset(video);
  final now = DateTime.utc(2026, 10, 31, 9);

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.getAsset(video)).thenAnswer((_) async => video);
    current = ValueNotifier(true);
    native = FakeNativePlayer(durationMs: film.inMilliseconds);
  });

  tearDown(() async {
    await context.dispose();
  });

  WatchProgress row(int minutes) => WatchProgress(
    key: key.key,
    position: Duration(minutes: minutes),
    duration: film,
    watched: false,
    updatedAt: now,
  );

  /// The viewer of [video], with the notice of the asset viewer next to it, and its native player attached
  Future<void> pumpViewer(WidgetTester tester, {List<WatchProgress> rows = const [], bool watchProgress = true}) async {
    database = MemoryWatchRows(rows);
    await tester.pumpTestWidget(
      context,
      Stack(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: current,
            builder: (_, isCurrent, _) => NativeVideoViewer(
              asset: video,
              image: const SizedBox(),
              isCurrent: isCurrent,
              watchProgress: watchProgress,
            ),
          ),
          Consumer(builder: (_, ref, _) => ResumeNotice(notice: ref.watch(resumeNoticeProvider))),
        ],
      ),
      overrides: [
        storageRepositoryProvider.overrideWithValue(MockStorageRepository()),
        sphericalProbeServiceProvider.overrideWithValue(_NoProbes()),
        videoSourceServiceProvider.overrideWithValue(VideoSourceService(_Decodes())),
        watchProgressRepositoryProvider.overrideWithValue(database),
        loopVideoProvider.overrideWithValue(true),
        tvModeProvider.overrideWithValue(false),
      ],
      expectSettle: false,
    );
    await tester.state<NativeVideoViewerState>(find.byType(NativeVideoViewer)).videoSource;
    tester.state<NativeVideoViewerState>(find.byType(NativeVideoViewer)).attachController(native);
    await tester.pump();
    await tester.pump();
  }

  /// The viewer goes, and its player with it: no timer is left
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('a film resumes where it was left once ready, then plays, with a notice and no button', (tester) async {
    await pumpViewer(tester, rows: [row(42)]);
    expect(native.calls, ['load', 'loop false'], reason: 'a film plays once whatever Looping says');

    native.ready();
    await tester.pump();
    await tester.pump();

    expect(native.calls.sublist(2), ['seek ${42 * minute}', 'play']);

    native.moveTo(42 * minute + 500);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Resumed at 42:00'), findsOneWidget);
    expect(find.byType(ButtonStyleButton), findsNothing);
    expect(find.byType(Dialog), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Resumed at 42:00'), findsNothing, reason: 'it fades');

    await leave(tester);
  });

  testWidgets('a swipe pauses the page, which saves where the film is', (tester) async {
    await pumpViewer(tester, rows: [row(42)]);
    native.ready();
    await tester.pump();
    await tester.pump();
    native.moveTo(50 * minute);
    await tester.pump();

    current.value = false;
    await tester.pump();
    await tester.pump();

    expect(native.calls.last, 'pause');
    expect(database.saved[key.key]?.position, const Duration(minutes: 50));

    await leave(tester);
  });

  testWidgets('the viewer going saves where the film is', (tester) async {
    await pumpViewer(tester);
    native.ready();
    await tester.pump();
    await tester.pump();
    native.moveTo(20 * minute);
    await tester.pump();

    await leave(tester);

    expect(database.saved[key.key]?.position, const Duration(minutes: 20));
  });

  group('a film an external player hands back (the immersive viewer of the Quest, Spatial 2.5D)', () {
    VideoPlayerNotifier playerOf(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(NativeVideoViewer)),
    ).read(videoPlayerProvider(video.id).notifier);

    /// The film plays here to 45:00, then an external player takes it and hands it back at 50:00: the in-app player
    /// loads it again, at its start until it is ready
    Future<void> handBack(WidgetTester tester) async {
      await pumpViewer(tester, rows: [row(42)]);
      native.ready();
      await tester.pump();
      await tester.pump();
      native.moveTo(45 * minute);
      await tester.pump();

      final player = playerOf(tester);
      await player.suspendForExternalPlayer();
      await tester.pump();
      await player.resumeAfterExternalPlayerAt(const Duration(minutes: 50), play: false);
      await tester.pump();
      expect(native.calls.where((call) => call == 'load'), hasLength(2), reason: 'loaded again');
      expect(player.state.position, Duration.zero, reason: 'at its start until it is ready, as Media3 reports it');
      expect(database.saved[key.key]?.position, const Duration(minutes: 50));
    }

    testWidgets('Back before the player is ready again keeps where the external player left it', (tester) async {
      await handBack(tester);

      await leave(tester);

      expect(database.saved[key.key]?.position, const Duration(minutes: 50));
    });

    testWidgets('a swipe before the player is ready again keeps it too', (tester) async {
      await handBack(tester);

      current.value = false;
      await tester.pump();
      await tester.pump();

      expect(database.saved[key.key]?.position, const Duration(minutes: 50));
      await leave(tester);
      expect(database.saved[key.key]?.position, const Duration(minutes: 50));
    });

    testWidgets('once ready, the film is where it was handed back, and saves from there', (tester) async {
      await handBack(tester);

      native.ready();
      await tester.pump();
      await tester.pump();
      expect(native.calls.last, 'seek ${50 * minute}');
      native.moveTo(51 * minute);
      await tester.pump();

      await leave(tester);

      expect(database.saved[key.key]?.position, const Duration(minutes: 51));
    });

    testWidgets('the viewer going while the external player has the film saves nothing over it', (tester) async {
      await pumpViewer(tester, rows: [row(42)]);
      native.ready();
      await tester.pump();
      await tester.pump();
      native.moveTo(45 * minute);
      await tester.pump();
      await playerOf(tester).suspendForExternalPlayer();
      await tester.pump();
      expect(database.saved[key.key]?.position, const Duration(minutes: 45));
      // The immersive viewer reports where the film is on its own (see ImmersiveWatch)
      final store = ProviderScope.containerOf(
        tester.element(find.byType(NativeVideoViewer)),
      ).read(watchProgressProvider.notifier);
      store.record(key, position: const Duration(minutes: 60), duration: film);

      await leave(tester);

      expect(database.saved[key.key]?.position, const Duration(minutes: 60));
    });
  });

  testWidgets('a page next to the one on screen loads nothing and keeps the position as it was', (tester) async {
    current.value = false;
    await pumpViewer(tester, rows: [row(42)]);

    expect(native.calls, isEmpty);
    await leave(tester);

    expect(database.writes, 0);
    expect(database.saved[key.key]?.position, const Duration(minutes: 42));
  });

  testWidgets('the slideshow and the memories play from the start as before, and loop as set', (tester) async {
    await pumpViewer(tester, rows: [row(42)], watchProgress: false);
    native.ready();
    await tester.pump();
    await tester.pump();

    expect(native.calls, ['load', 'loop true', 'play']);

    await leave(tester);
  });
}
