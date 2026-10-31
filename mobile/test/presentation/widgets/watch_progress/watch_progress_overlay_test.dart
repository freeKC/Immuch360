import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/watch_progress/watch_progress_overlay.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

/// The rows given, as the database of the watch progress would hold them
class _Rows implements WatchProgressRepository {
  _Rows(this.rows);

  final List<WatchProgress> rows;

  @override
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async => rows;

  @override
  Future<void> upsert(WatchProgress row) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> close() async {}
}

class _IdleUpload extends NetworkUploadNotifier {
  @override
  NetworkUploadState build() => const NetworkUploadState();
}

class _NoRecords extends NetworkUploadRecordsNotifier {
  @override
  Map<String, UploadRecord> build() => const {};
}

void main() {
  late PresentationContext context;
  const film = Duration(minutes: 100);
  final now = DateTime.utc(2026, 10, 31, 9);
  final bar = find.byKey(const Key('watch_progress_bar'));
  final fill = find.byKey(const Key('watch_progress_fill'));
  final check = find.byKey(const Key('watch_progress_check'));
  final tile = find.byKey(const Key('tile'));

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  WatchProgress row(String key, {int minutes = 25, bool watched = false, Duration duration = film}) => WatchProgress(
    key: key,
    position: Duration(minutes: minutes),
    duration: duration,
    watched: watched,
    updatedAt: now,
  );

  List<Override> overridesFor(
    List<WatchProgress> rows, {
    bool tv = false,
    ViewerConfig viewer = const ViewerConfig(),
  }) => [
    watchProgressRepositoryProvider.overrideWithValue(_Rows(rows)),
    appConfigProvider.overrideWithValue(AppConfig(viewer: viewer)),
    tvModeProvider.overrideWithValue(tv),
  ];

  Future<void> pumpOverlay(
    WidgetTester tester,
    List<WatchProgress> rows, {
    bool tv = false,
    ViewerConfig viewer = const ViewerConfig(),
  }) async {
    await tester.pumpTestWidget(
      context,
      const Center(
        child: SizedBox(
          key: Key('tile'),
          width: 200,
          height: 200,
          child: Stack(children: [WatchProgressOverlay(watchKey: WatchKey('asset:a'))]),
        ),
      ),
      overrides: overridesFor(rows, tv: tv, viewer: viewer),
    );
  }

  testWidgets('a film in progress gets a thin bar along the bottom edge, filled as far as it was watched', (
    tester,
  ) async {
    await pumpOverlay(tester, [row('asset:a')]);

    expect(bar, findsOneWidget);
    expect(tester.getSize(bar), const Size(200, 3));
    expect(tester.getBottomLeft(bar), tester.getBottomLeft(tile));
    expect(tester.getSize(fill).width, closeTo(50, 0.01));
    expect(check, findsNothing);
  });

  testWidgets('a watched film gets a check at the bottom centre, and no bar', (tester) async {
    await pumpOverlay(tester, [row('asset:a', minutes: 0, watched: true)]);

    expect(check, findsOneWidget);
    expect(tester.getSize(check), const Size(16, 16));
    expect(tester.getCenter(check).dx, closeTo(tester.getCenter(tile).dx, 0.01));
    expect(bar, findsNothing);
  });

  testWidgets('a watched film seen again has both', (tester) async {
    await pumpOverlay(tester, [row('asset:a', minutes: 50, watched: true)]);

    expect(check, findsOneWidget);
    expect(tester.getSize(fill).width, closeTo(100, 0.01));
  });

  testWidgets('larger on a TV, readable from the couch', (tester) async {
    await pumpOverlay(tester, [row('asset:a', minutes: 50, watched: true)], tv: true);

    expect(tester.getSize(bar).height, 6);
    expect(tester.getSize(check), const Size(28, 28));
  });

  testWidgets('nothing without a row', (tester) async {
    await pumpOverlay(tester, [row('asset:b')]);

    expect(bar, findsNothing);
    expect(check, findsNothing);
  });

  testWidgets('nothing with the setting off: the rows come back when it is on again', (tester) async {
    await pumpOverlay(tester, [row('asset:a', watched: true)], viewer: const ViewerConfig(resumeVideos: false));

    expect(bar, findsNothing);
    expect(check, findsNothing);
  });

  testWidgets('nothing for a video under the threshold', (tester) async {
    final clip = row('asset:a', minutes: 3, duration: const Duration(minutes: 8));
    await pumpOverlay(tester, [clip]);

    expect(bar, findsNothing);

    await pumpOverlay(tester, [clip], viewer: const ViewerConfig(resumeMinMinutes: 5));
    expect(bar, findsOneWidget);
  });

  testWidgets('a save shows on the tile at once', (tester) async {
    await pumpOverlay(tester, []);
    expect(bar, findsNothing);

    final store = ProviderScope.containerOf(
      tester.element(find.byType(WatchProgressOverlay)),
      listen: false,
    ).read(watchProgressProvider.notifier);
    store.record(const WatchKey('asset:a'), position: const Duration(minutes: 75), duration: film);
    await tester.pump();

    expect(tester.getSize(fill).width, closeTo(150, 0.01));
  });

  group('the tiles', () {
    testWidgets('the tile of a video of the timeline shows its progress', (tester) async {
      final video = RemoteAssetFactory.create(type: .video);
      await tester.pumpTestWidget(
        context,
        SizedBox(width: 120, height: 120, child: ThumbnailTile(video)),
        overrides: overridesFor([row('asset:${video.id}')]),
      );

      expect(bar, findsOneWidget);
      expect(tester.getSize(bar).width, 120);
    });

    testWidgets('the tile of a photo never does', (tester) async {
      final photo = RemoteAssetFactory.create();
      await tester.pumpTestWidget(
        context,
        SizedBox(width: 120, height: 120, child: ThumbnailTile(photo)),
        overrides: overridesFor([row('asset:${photo.id}')]),
      );

      expect(find.byType(WatchProgressOverlay), findsNothing);
    });

    testWidgets('the tile of a video of a share shows that it was watched', (tester) async {
      final entry = NetworkEntry(
        sourceId: 'nas',
        path: '/Films/Film.mkv',
        isDirectory: false,
        size: 1000,
        modified: DateTime.utc(2026, 10, 1),
      );
      await tester.pumpTestWidget(
        context,
        SizedBox(
          width: 120,
          height: 120,
          child: NetworkMediaTile(entry: entry, url: null, onTap: () {}),
        ),
        overrides: [
          ...overridesFor([row(WatchKey.ofEntry(entry).key, minutes: 0, watched: true)]),
          networkMediaInfoProvider(networkMediaKey(entry)).overrideWith((ref) async => null),
          networkUploadRecordsProvider.overrideWith(_NoRecords.new),
          networkUploadProvider.overrideWith(_IdleUpload.new),
          isHorizonOsProvider.overrideWith((ref) async => false),
        ],
      );

      expect(check, findsOneWidget);
    });
  });
}
