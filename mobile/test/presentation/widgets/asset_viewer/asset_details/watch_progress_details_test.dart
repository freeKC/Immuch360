// The details of a film say how much of it was watched, with Play from the start and Mark as not watched: on a TV,
// where the ⋮ of the viewer is hidden, they are the only menu, reached with the remote.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/watch_progress_details.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

import '../../../../fixtures/watch_progress.fake.dart';
import '../../../../unit/factories/remote_asset_factory.dart';
import '../../../../unit/presentation/presentation_context.dart';

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
  final restart = find.byKey(const Key('watch_progress_restart'));
  final unwatch = find.byKey(const Key('watch_progress_unwatch'));

  setUp(() async {
    context = await PresentationContext.create();
    player = _Player();
  });

  tearDown(() async {
    await context.dispose();
  });

  WatchProgress row({int minutes = 42, int seconds = 10, bool watched = false, Duration duration = film}) =>
      WatchProgress(
        key: key.key,
        position: Duration(minutes: minutes, seconds: seconds),
        duration: duration,
        watched: watched,
        updatedAt: DateTime.utc(2026, 10, 31, 9),
      );

  Future<void> pumpDetails(WidgetTester tester, List<WatchProgress> rows) async {
    database = MemoryWatchRows(rows);
    await tester.pumpTestWidget(
      context,
      Column(
        children: [
          WatchProgressDetails(asset: video),
          // The viewer's player of the video, alive while the details show
          Consumer(
            builder: (_, ref, _) {
              ref.watch(videoPlayerProvider(video.id));
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      overrides: [
        watchProgressRepositoryProvider.overrideWithValue(database),
        videoPlayerProvider(video.id).overrideWith((ref) => player),
      ],
    );
  }

  testWidgets('a film in progress: how much was watched, and where it stopped', (tester) async {
    await pumpDetails(tester, [row()]);

    expect(find.text('Watched 42 %'), findsOneWidget);
    expect(find.text('Stopped at 42:10 of 01:40:00'), findsOneWidget);
    expect(restart, findsOneWidget);
    expect(unwatch, findsNothing);
  });

  testWidgets('a watched film: watched, and the entry to forget it', (tester) async {
    await pumpDetails(tester, [row(minutes: 0, seconds: 0, watched: true)]);

    expect(find.text('Watched'), findsOneWidget);
    expect(find.textContaining('Stopped at'), findsNothing);
    expect(restart, findsNothing);
    expect(unwatch, findsOneWidget);

    await tester.tap(unwatch);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('watch_progress_details')), findsNothing);
    expect(database.saved, isEmpty);
  });

  testWidgets('Play from the start forgets the position and plays the film from 0', (tester) async {
    await pumpDetails(tester, [row()]);

    await tester.tap(restart);
    await tester.pumpAndSettle();

    expect(player.restarts, 1);
    expect(database.saved, isEmpty);
  });

  testWidgets('the remote of a TV reaches the entries and presses them', (tester) async {
    await pumpDetails(tester, [row(watched: true)]);

    final restartFocus = Focus.of(tester.element(find.descendant(of: restart, matching: find.byType(Text))));
    restartFocus.requestFocus();
    await tester.pump();
    expect(restartFocus.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(player.restarts, 1);
  });

  testWidgets('nothing for a video without a row, nor for one that is no film', (tester) async {
    await pumpDetails(tester, []);
    expect(find.byKey(const Key('watch_progress_details')), findsNothing);

    await pumpDetails(tester, [row(minutes: 3, duration: const Duration(minutes: 8))]);
    expect(find.byKey(const Key('watch_progress_details')), findsNothing);
  });
}
