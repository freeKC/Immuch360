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
