import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/watch_progress.action.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:immich_mobile/utils/action_button.utils.dart';
import 'package:immich_ui/immich_ui.dart';

import '../../../fixtures/watch_progress.fake.dart';
import '../../factories/remote_asset_factory.dart';
import '../presentation_context.dart';

/// The page's player of the video, which records a restart
class _Player extends VideoPlayerNotifier {
  var restarts = 0;

  @override
  Future<void> restart() async => restarts++;
}

void main() {
  late PresentationContext context;
  late MemoryWatchRows database;
  late _Player player;
  const film = Duration(minutes: 100);
  final video = RemoteAssetFactory.create(type: .video).copyWith(durationMs: film.inMilliseconds);
  final key = WatchKey.ofAsset(video);

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  WatchProgress row({int minutes = 42, bool watched = false, Duration duration = film}) => WatchProgress(
    key: key.key,
    position: Duration(minutes: minutes),
    duration: duration,
    watched: watched,
    updatedAt: DateTime.utc(2026, 10, 31, 9),
  );

  List<Override> overridesFor(List<WatchProgress> rows, {BaseAsset? asset}) {
    database = MemoryWatchRows(rows);
    // A player of its own per scope: a scope that goes disposes it
    final fresh = _Player();
    player = fresh;
    return [
      ...context.selected({asset ?? video}),
      watchProgressRepositoryProvider.overrideWithValue(database),
      videoPlayerProvider(video.id).overrideWith((ref) => fresh),
    ];
  }

  /// The action, next to the viewer's player of the video, kept alive as the viewer keeps it
  Future<void> pumpAction(WidgetTester tester, ActionBuilder action, List<Override> overrides) async {
    await tester.pumpTestWidget(
      context,
      Column(
        children: [
          ActionIconButton(action: action),
          Consumer(
            builder: (_, ref, _) {
              ref.watch(videoPlayerProvider(video.id));
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      overrides: overrides,
    );
  }

  group('Play from the start', () {
    testWidgets('forgets where a film was and plays it from 0', (tester) async {
      await pumpAction(tester, const PlayFromStartAction(source: .timeline), overridesFor([row()]));

      await tester.tap(find.byType(ImmichIconButton));
      await tester.pumpAndSettle();

      expect(database.saved, isEmpty);
      expect(player.restarts, 1);
    });

    testWidgets('keeps the check of a watched film seen again', (tester) async {
      await pumpAction(tester, const PlayFromStartAction(source: .timeline), overridesFor([row(watched: true)]));

      await tester.tap(find.byType(ImmichIconButton));
      await tester.pumpAndSettle();

      expect(database.saved[key.key]?.watched, isTrue);
      expect(database.saved[key.key]?.position, Duration.zero);
    });

    testWidgets('is not offered without a position, nor for a video that is no film, nor for a photo', (tester) async {
      for (final overrides in [
        overridesFor([]),
        overridesFor([row(minutes: 0, watched: true)]),
        overridesFor([row(minutes: 3, duration: const Duration(minutes: 8))]),
        overridesFor([row()], asset: RemoteAssetFactory.create()),
      ]) {
        await pumpAction(tester, const PlayFromStartAction(source: .timeline), overrides);

        expect(find.byType(ImmichIconButton), findsNothing);
        // A fresh scope for the next overrides
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  group('Mark as not watched', () {
    testWidgets('forgets the check and the position of a watched film', (tester) async {
      await pumpAction(tester, const MarkUnwatchedAction(source: .timeline), overridesFor([row(watched: true)]));

      await tester.tap(find.byType(ImmichIconButton));
      await tester.pumpAndSettle();

      expect(database.saved, isEmpty);
      expect(player.restarts, 0, reason: 'the film plays on');
    });

    testWidgets('is not offered for a film not watched yet', (tester) async {
      await pumpAction(tester, const MarkUnwatchedAction(source: .timeline), overridesFor([row()]));

      expect(find.byType(ImmichIconButton), findsNothing);
    });
  });

  test('the entries show in the ⋮ of a video only', () {
    ActionButtonContext contextFor(BaseAsset asset) => ActionButtonContext(
      asset: asset,
      isOwner: true,
      isArchived: false,
      isStacked: false,
      isInLockedView: true,
      currentAlbum: null,
      advancedTroubleshooting: false,
      source: ActionSource.viewer,
    );

    expect(ActionButtonType.watchProgress.shouldShow(contextFor(video)), isTrue);
    expect(ActionButtonType.watchProgress.shouldShow(contextFor(RemoteAssetFactory.create())), isFalse);
    expect(ActionButtonType.watchProgress.buildButton(contextFor(video)), isA<WatchProgressMenuItems>());
  });

  test('watchActionsFor', () {
    const rule = WatchRule();

    expect(watchActionsFor(null, rule), (restart: false, unwatch: false));
    expect(watchActionsFor(row(), rule), (restart: true, unwatch: false));
    expect(watchActionsFor(row(minutes: 0, watched: true), rule), (restart: false, unwatch: true));
    expect(watchActionsFor(row(watched: true), rule), (restart: true, unwatch: true));
    expect(watchActionsFor(row(), const WatchRule(enabled: false)), (restart: false, unwatch: false));
  });
}
